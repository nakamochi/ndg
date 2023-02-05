const std = @import("std");

export fn wifi_ssid_add_network(name: [*:0]const u8) void {
    _ = name;
}

export fn lv_timer_del(timer: *opaque {}) void {
    _ = timer;
}

test {
    _ = @import("comm.zig");
    _ = @import("ngui.zig");

    std.testing.refAllDecls(@This());
}
