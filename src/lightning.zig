pub const LndConf = @import("lightning/LndConf.zig");
pub const lndhttp = @import("lightning/lndhttp.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
