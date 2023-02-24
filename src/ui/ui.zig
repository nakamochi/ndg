const std = @import("std");

const lvgl = @import("lvgl.zig");
const drv = @import("drv.zig");

const logger = std.log.scoped(.ui);

extern "c" fn nm_ui_init(disp: *lvgl.LvDisp) c_int;
extern "c" fn nm_make_topdrop() ?*lvgl.LvObj;
extern "c" fn nm_remove_topdrop() void;

pub fn init() !void {
    lvgl.init();
    const disp = try drv.initDisplay();
    drv.initInput() catch |err| {
        // TODO: or continue without the touchpad?
        // at the very least must disable screen blanking timeout in case of a failure.
        // otherwise, impossible to wake up the screen. */
        return err;
    };
    if (nm_ui_init(disp) != 0) {
        return error.UiInitFailure;
    }
}

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
            S.lv_obj = nm_make_topdrop();
            lvgl.lv_refr_now(null);
        },
        .remove => {
            if (S.lv_obj) |v| {
                lvgl.lv_obj_del(v);
                S.lv_obj = null;
            }
        },
    }
}
