const std = @import("std");

const lvgl = @import("lvgl.zig");
const drv = @import("drv.zig");

const logger = std.log.scoped(.ui);

extern "c" fn nm_ui_init(disp: *lvgl.LvDisp) c_int;

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
