const std = @import("std");

const lvgl = @import("lvgl.zig");
const drv = @import("drv.zig");
const symbol = @import("symbol.zig");
const widget = @import("widget.zig");

const logger = std.log.scoped(.ui);

extern "c" fn nm_ui_init(disp: *lvgl.LvDisp) c_int;
extern fn nm_sys_shutdown() void;

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

/// called when "power off" button is pressed.
export fn nm_poweroff_btn_callback(e: *lvgl.LvEvent) void {
    _ = e;
    const proceed: [*:0]const u8 = "PROCEED";
    const abort: [*:0]const u8 = "CANCEL";
    const title = " " ++ symbol.Power ++ " SHUTDOWN";
    const text =
        \\ARE YOU SURE?
        \\
        \\once shut down,
        \\payments cannot go through via bitcoin or lightning networks
        \\until the node is powered back on.
    ;
    widget.modal(title, text, &.{ proceed, abort }, poweroffModalCallback) catch |err| {
        logger.err("shutdown btn: modal: {any}", .{err});
    };
}

fn poweroffModalCallback(btn_idx: usize) void {
    // proceed = 0, cancel = 1
    if (btn_idx != 0) {
        return;
    }
    // proceed with shutdown
    nm_sys_shutdown();
}
