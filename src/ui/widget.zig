const std = @import("std");
const lvgl = @import("lvgl.zig");

const logger = std.log.scoped(.ui);

// NOTE: ui.init() must set this (e.g. widget.allocator = opt.allocator).
pub var allocator: std.mem.Allocator = undefined;

// defined in ui.c
extern fn nm_keyboard_popon(input: *lvgl.LvObj) void;
extern fn nm_keyboard_popoff() void;

/// show keyboard on the default display and attach it to a UI input widget.
/// the widget is any `lvgl.BaseObjMethods`.
/// TODO: at the moment, the parent layer is always assumed to be the tabview,
/// and it is resized to fit the keyboard. this won't work for a pop up screen like the `modal`.
pub fn keyboardOn(input: anytype) void {
    nm_keyboard_popon(input.lvobj);
}

/// hides the keyboard and restores the tabview dimensions.
pub fn keyboardOff() void {
    nm_keyboard_popoff();
}

/// creates an opposite of a backdrop: a plain black square on the top layer
/// covering the whole screen. useful for standby/sleep mode on systems where
/// cutting screen power is unsupported.
///
/// unsafe for concurrent use.
pub fn topdrop(onoff: enum { show, remove }) void {
    // a static construct: there can be only one global topdrop.
    // https://ziglang.org/documentation/master/#Static-Local-Variables
    const S = struct {
        var top: ?lvgl.Container = null;
    };
    switch (onoff) {
        .show => {
            if (S.top != null) {
                return;
            }

            const top = lvgl.Container.newTop() catch |err| {
                logger.err("topdrop: lvgl.Container.newTop: {any}", .{err});
                return;
            };
            top.setFlag(.ignore_layout);
            top.resizeToMax();
            top.setBackgroundColor(lvgl.Black, .{});
            S.top = top;
            lvgl.redraw();
        },
        .remove => {
            if (S.top) |top| {
                top.destroy();
                S.top = null;
            }
        },
    }
}

/// modal callback func type. it receives 0-based index of a button item
/// provided as btns arg to modal.
pub const ModalButtonCallbackFn = *const fn (index: usize) void;

/// Context stored in the modal window's user data.
/// We intentionally store a *data pointer* in LVGL user_data (void*), never a function
/// pointer, because data-pointer <-> function-pointer casts are not portable and can
/// break across Zig versions / ABIs.
///
/// We also store the allocator used to allocate this context so the delete handler
/// can always free with the same allocator.
const ModalCtx = struct {
    alloc: std.mem.Allocator,
    cb: ModalButtonCallbackFn,
};

/// shows a non-dismissible window using the whole screen real estate;
/// for use in place of lv_msgbox_create.
///
/// while all heap-alloc'ed resources are free'd automatically right before cb is called,
/// the value of title, text and btns args must live at least as long as cb; they are
/// memory-managed by the callers.
pub fn modal(title: [*:0]const u8, text: [*:0]const u8, btns: []const [*:0]const u8, cb: ModalButtonCallbackFn) !void {
    const win = try lvgl.Window.newTop(60, title);
    errdefer win.destroy(); // also deletes all children created below

    const ctx = try allocator.create(ModalCtx);
    ctx.* = .{ .alloc = allocator, .cb = cb };
    win.setUserdata(ctx);

    // Free context when the window is deleted, regardless of deletion path.
    _ = win.on(.delete, nm_modal_delete_callback, null);

    const wincont = win.content().flex(.column, .{ .cross = .center, .track = .center });
    const msg = try lvgl.Label.new(wincont, text, .{ .pos = .center });
    msg.setWidth(lvgl.LvDisp.horiz() - 100);
    msg.flexGrow(1);

    // buttons container
    const btncont = try lvgl.FlexLayout.new(wincont, .row, .{ .all = .center });
    btncont.setWidth(lvgl.LvDisp.horiz() - 40);
    btncont.setHeightToContent();

    // leave 5% as an extra spacing.
    const btnwidth = lvgl.sizePercent(try std.math.divFloor(i16, 95, @as(u8, @truncate(btns.len))));
    for (btns, 0..) |btext, i| {
        const btn = try lvgl.TextButton.new(btncont, btext);
        btn.setFlag(.event_bubble);
        btn.setFlag(.user1); // .user1 indicates actionable button in callback

        // Store (i+1) so userdata is never null (0). In callback: idx = intFromPtr - 1.
        btn.setUserdata(@ptrFromInt(i + 1));

        btn.setWidth(btnwidth);
        if (i == 0) {
            btn.addStyle(lvgl.nm_style_btn_red(), .{});
        }
    }
    _ = btncont.on(.click, nm_modal_callback, win.lvobj);
}

/// Frees modal context when the window is deleted. This runs for all deletion paths
/// (button click, screen unload, parent cleanup, etc.) and avoids leaks/double-frees.
export fn nm_modal_delete_callback(e: *lvgl.LvEvent) callconv(.C) void {
    const win = lvgl.Window{ .lvobj = e.target() };

    const ctx_any = win.userdata() orelse return;
    const ctx: *ModalCtx = @ptrCast(@alignCast(ctx_any));

    // Clear userdata so any accidental future access becomes a null-check failure.
    win.setUserdata(null);

    ctx.alloc.destroy(ctx);
}

export fn nm_modal_callback(e: *lvgl.LvEvent) callconv(.C) void {
    const edata = e.userdata() orelse return;

    const target = lvgl.Container{ .lvobj = e.target() }; // type doesn't really matter
    if (!target.hasFlag(.user1)) { // .user1 is set in modal setup
        return;
    }

    const idx_any = target.userdata() orelse return;
    const btn_index: usize = @intFromPtr(idx_any) - 1;

    const win = lvgl.Window{ .lvobj = @ptrCast(edata) };
    const ctx_any = win.userdata() orelse return;
    const ctx: *ModalCtx = @ptrCast(@alignCast(ctx_any));
    const cb = ctx.cb;

    // Destroying the window triggers LV_EVENT_DELETE, which frees ctx.
    win.destroy();

    cb(btn_index);
}
