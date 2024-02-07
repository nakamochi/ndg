//! operating system related helper functions.

const builtin = @import("builtin");
const std = @import("std");

const types = @import("types.zig");
const sysimpl = @import("sys/sysimpl.zig");

pub const Service = @import("sys/Service.zig");

pub usingnamespace if (builtin.is_test) struct {
    // stubs, mocks and overrides for testing.

    pub fn hostname(allocator: std.mem.Allocator) ![]const u8 {
        return allocator.dupe(u8, "testhost");
    }

    pub fn setHostname(allocator: std.mem.Allocator, name: []const u8) !void {
        _ = allocator;
        _ = name;
    }
} else sysimpl; // real implementation for production code.

test {
    _ = @import("sys/Service.zig");
    _ = @import("sys/sysimpl.zig");
    std.testing.refAllDecls(@This());
}
