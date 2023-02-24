const std = @import("std");

export fn wifi_ssid_add_network(name: [*:0]const u8) void {
    _ = name;
}

export fn lv_timer_del(timer: *opaque {}) void {
    _ = timer;
}

export fn lv_disp_get_inactive_time(disp: *opaque {}) u32 {
    _ = disp;
    return 0;
}

test {
    _ = @import("comm.zig");
    _ = @import("ngui.zig");

    std.testing.refAllDecls(@This());
}
