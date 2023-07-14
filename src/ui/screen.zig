///! display and touch screen helper functions.
const builtin = @import("builtin");
const std = @import("std");
const Thread = std.Thread;

const lvgl = @import("lvgl.zig");
const drv = @import("drv.zig");
const widget = @import("widget.zig");

const logger = std.log.scoped(.screen);

/// cover the whole screen in black (top layer) and block until either
/// a touch screen activity or wake event is triggered.
/// sleep removes all input devices at enter and reinstates them at exit so that
/// a touch event triggers no accidental action.
pub fn sleep(wake: *const Thread.ResetEvent) void {
    drv.deinitInput();
    widget.topdrop(.show);
    defer {
        drv.initInput() catch |err| logger.err("drv.initInput: {any}", .{err});
        widget.topdrop(.remove);
    }

    const watcher = drv.InputWatcher() catch |err| {
        logger.err("drv.InputWatcher: {any}", .{err});
        return;
    };
    defer watcher.close();
    while (!wake.isSet()) {
        if (watcher.consume()) {
            return;
        }
        std.atomic.spinLoopHint();
        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

/// turn on or off display backlight.
pub fn backlight(onoff: enum { on, off }) !void {
    const blpath = if (builtin.is_test) "/dev/null" else "/sys/class/backlight/rpi_backlight/bl_power";
    const f = try std.fs.openFileAbsolute(blpath, .{ .mode = .write_only });
    defer f.close();
    const v = if (onoff == .on) "0" else "1";
    _ = try f.write(v);
}
