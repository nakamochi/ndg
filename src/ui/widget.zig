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
    // see https://ziglang.org/documentation/master/#Static-Local-Variables
    const S = struct {
        var lv_obj: ?*lvgl.LvObj = null;
    };
    switch (onoff) {
        .show => {
            if (S.lv_obj != null) {
                return;
            }

            const o = lvgl.createTopObject() catch |err| {
                logger.err("topdrop: lvgl.createTopObject: {any}", .{err});
                return;
            };
            o.setFlag(.on, .ignore_layout);
            o.resizeToMax();
            o.setBackgroundColor(lvgl.Black, .{});

            S.lv_obj = o;
            lvgl.displayRedraw();
        },
        .remove => {
            if (S.lv_obj) |o| {
                o.destroy();
                S.lv_obj = null;
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
    const win = try lvgl.createWindow(null, 60, title);
    errdefer win.winobj.destroy(); // also deletes all children created below
    win.winobj.setUserdata(cb);

    const wincont = win.content();
    wincont.flexFlow(.column);
    wincont.flexAlign(.start, .center, .center);
    const msg = try lvgl.createLabel(wincont, text, .{ .pos = .center });
    msg.setWidth(lvgl.displayHoriz() - 100);
    msg.flexGrow(1);

    const btncont = try lvgl.createFlexObject(wincont, .row);
    btncont.removeBackgroundStyle();
    btncont.padColumnDefault();
    btncont.flexAlign(.center, .center, .center);
    btncont.setWidth(lvgl.displayHoriz() - 40);
    btncont.setHeightToContent();

    // leave 5% as an extra spacing.
    const btnwidth = lvgl.sizePercent(try std.math.divFloor(i16, 95, @truncate(u8, btns.len)));
    for (btns) |btext, i| {
        const btn = try lvgl.createButton(btncont, btext);
        btn.setWidth(btnwidth);
        btn.setFlag(.on, .event_bubble);
        btn.setFlag(.on, .user1); // .user1 indicates actionable button in callback
        if (i == 0) {
            btn.addStyle(lvgl.nm_style_btn_red(), .{});
        }
        btn.setUserdata(@intToPtr(?*anyopaque, i)); // button index in callback
    }
    _ = btncont.on(.click, nm_modal_callback, win.winobj);
}

export fn nm_modal_callback(e: *lvgl.LvEvent) void {
    if (e.userdata()) |event_data| {
        const target = e.target();
        if (!target.hasFlag(.user1)) { // .user1 is set by modal fn
            return;
        }

        const btn_index = @ptrToInt(target.userdata());
        const winobj = @ptrCast(*lvgl.LvObj, event_data);
        // guaranteed to be aligned due to cb arg in modal fn.
        const cb = @ptrCast(ModalButtonCallbackFn, @alignCast(@alignOf(ModalButtonCallbackFn), winobj.userdata()));
        winobj.destroy();
        cb(btn_index);
    }
}
