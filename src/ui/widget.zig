const std = @import("std");
const lvgl = @import("lvgl.zig");

const logger = std.log.scoped(.ui);

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

/// shows a non-dismissible window using the whole screen real estate;
/// for use in place of lv_msgbox_create.
///
/// while all heap-alloc'ed resources are free'd automatically right before cb is called,
/// the value of title, text and btns args must live at least as long as cb; they are
/// memory-managed by the callers.
///
/// note: the cb callback must have @alignOf(ModalbuttonCallbackFn) alignment.
pub fn modal(title: [*:0]const u8, text: [*:0]const u8, btns: []const [*:0]const u8, cb: ModalButtonCallbackFn) !void {
    const win = try lvgl.Window.newTop(60, title);
    errdefer win.destroy(); // also deletes all children created below
    win.setUserdata(cb);

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
        btn.setUserdata(@ptrFromInt(i)); // button index in callback
        btn.setWidth(btnwidth);
        if (i == 0) {
            btn.addStyle(lvgl.nm_style_btn_red(), .{});
        }
    }
    _ = btncont.on(.click, nm_modal_callback, win.lvobj);
}

export fn nm_modal_callback(e: *lvgl.LvEvent) void {
    if (e.userdata()) |edata| {
        const target = lvgl.Container{ .lvobj = e.target() }; // type doesn't really matter
        if (!target.hasFlag(.user1)) { // .user1 is set in modal setup
            return;
        }

        const btn_index = @intFromPtr(target.userdata());
        const win = lvgl.Window{ .lvobj = @ptrCast(edata) };
        const cb: ModalButtonCallbackFn = @alignCast(@ptrCast(win.userdata()));
        win.destroy();
        cb(btn_index);
    }
}
