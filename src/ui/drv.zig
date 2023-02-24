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

/// deactivate and remove all input devices.
pub fn deinitInput() void {
    var indev = lvgl.lv_indev_get_next(null);
    var count: usize = 0;
    while (indev) |d| {
        lvgl.lv_indev_delete(d);
        count += 1;
        indev = lvgl.lv_indev_get_next(null);
    }
    logger.debug("deinited {d} indev(s)", .{count});
}

pub usingnamespace switch (buildopts.driver) {
    .sdl2 => struct {
        pub fn InputWatcher() !type {
            return error.InputWatcherUnavailable;
        }
    },
    .fbev => struct {
        extern "c" fn nm_open_evdev_nonblock() std.os.fd_t;
        extern "c" fn nm_close_evdev(fd: std.os.fd_t) void;
        extern "c" fn nm_consume_input_events(fd: std.os.fd_t) bool;

        pub fn InputWatcher() !EvdevWatcher {
            const fd = nm_open_evdev_nonblock();
            if (fd == -1) {
                return error.InputWatcherUnavailable;
            }
            return .{ .evdev_fd = fd };
        }

        pub const EvdevWatcher = struct {
            evdev_fd: std.os.fd_t,

            pub fn consume(self: @This()) bool {
                return nm_consume_input_events(self.evdev_fd);
            }

            pub fn close(self: @This()) void {
                nm_close_evdev(self.evdev_fd);
            }
        };
    },
};
