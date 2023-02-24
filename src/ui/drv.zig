///! input and display drivers support in zig.
const std = @import("std");
const buildopts = @import("build_options");

const lvgl = @import("lvgl.zig");

const logger = std.log.scoped(.drv);

extern "c" fn nm_disp_init() ?*lvgl.LvDisp;
extern "c" fn nm_indev_init() c_int;

/// initalize a display and make it active for the UI to use.
/// requires lvgl.init() to have been already called.
// TODO: rewrite lv_drivers/display/fbdev.c to make fbdev_init return an error
pub fn initDisplay() !*lvgl.LvDisp {
    if (nm_disp_init()) |disp| {
        return disp;
    }
    return error.DisplayInitFailed;
}

/// initialize input devices: touch screen and possibly keyboard if using SDL.
pub fn initInput() !void {
    const res = nm_indev_init();
    if (res != 0) {
        return error.InputInitFailed;
    }
}
