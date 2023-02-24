///! LVGL types in zig
const std = @import("std");

/// initalize LVGL internals.
/// must be called before any other UI functions.
pub fn init() void {
    init_once.call();
}

var init_once = std.once(lvglInit);

fn lvglInit() void {
    lv_log_register_print_cb(nm_lvgl_log);
    lv_init();
}

// logs LV_LOG_xxx messages from LVGL lib
const lvgl_logger = std.log.scoped(.lvgl);

export fn nm_lvgl_log(msg: [*:0]const u8) void {
    const s = std.mem.span(msg);
    // info level log messages are by default printed only in Debug and ReleaseSafe build modes.
    lvgl_logger.debug("{s}", .{std.mem.trimRight(u8, s, "\n")});
}

extern "c" fn lv_init() void;
extern "c" fn lv_log_register_print_cb(*const fn (msg: [*:0]const u8) callconv(.C) void) void;

/// represents lv_timer_t in C.
pub const LvTimer = opaque {};
pub const LvTimerCallback = *const fn (timer: *LvTimer) callconv(.C) void;
/// the timer handler is the LVGL busy-wait loop iteration.
pub extern "c" fn lv_timer_handler() u32;
pub extern "c" fn lv_timer_create(callback: LvTimerCallback, period_ms: u32, userdata: ?*anyopaque) ?*LvTimer;
pub extern "c" fn lv_timer_del(timer: *LvTimer) void;
pub extern "c" fn lv_timer_set_repeat_count(timer: *LvTimer, n: i32) void;

/// represents lv_obj_t type in C.
pub const LvObj = opaque {};
/// delete and deallocate an object and all its children from UI tree.
pub extern "c" fn lv_obj_del(obj: *LvObj) void;

/// represents lv_indev_t in C, an input device such as touchscreen or a keyboard.
pub const LvIndev = opaque {};
/// deallocate and delete an input device from LVGL registry.
pub extern "c" fn lv_indev_delete(indev: *LvIndev) void;
/// return next device in the list or head if indev is null.
pub extern "c" fn lv_indev_get_next(indev: ?*LvIndev) ?*LvIndev;

/// represents lv_disp_t in C.
pub const LvDisp = opaque {};
/// return elapsed time since last user activity on a specific display
/// or any if disp is null.
pub extern "c" fn lv_disp_get_inactive_time(disp: ?*LvDisp) u32;
/// make it so as if a user activity happened.
/// this resets an internal counter in lv_disp_get_inactive_time.
pub extern "c" fn lv_disp_trig_activity(disp: ?*LvDisp) void;
/// force redraw dirty areas.
pub extern "c" fn lv_refr_now(disp: ?*LvDisp) void;
