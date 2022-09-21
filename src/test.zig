const std = @import("std");

export fn wifi_ssid_add_network(name: [*:0]const u8) void {
    _ = name;
}

export fn lv_timer_del(timer: *opaque{}) void {
    _ = timer;
}

test {
    std.testing.refAllDecls(@This());

    _ = @import("comm.zig");
    _ = @import("ngui.zig");
}
