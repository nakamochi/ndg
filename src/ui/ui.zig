const buildopts = @import("build_options");
const std = @import("std");

const comm = @import("../comm.zig");
const lvgl = @import("lvgl.zig");
const drv = @import("drv.zig");
const symbol = @import("symbol.zig");
const widget = @import("widget.zig");
pub const poweroff = @import("poweroff.zig");

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

export fn nm_create_info_panel(parent: *lvgl.LvObj) c_int {
    createInfoPanel(parent) catch |err| {
        logger.err("createInfoPanel: {any}", .{err});
        return -1;
    };
    return 0;
}

fn createInfoPanel(parent: *lvgl.LvObj) !void {
    parent.flexFlow(.column);
    parent.flexAlign(.start, .start, .start);

    var buf: [100]u8 = undefined;
    const sver = try std.fmt.bufPrintZ(&buf, "GUI version: {any}", .{buildopts.semver});
    _ = try lvgl.createLabel(parent, sver, .{});
}
