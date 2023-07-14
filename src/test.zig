const std = @import("std");
const builtin = @import("builtin");
const nif = @import("nif");

comptime {
    if (!builtin.is_test) @compileError("test-only module");
}

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

/// TestTimer always reports the same fixed value.
pub const TestTimer = struct {
    value: u64,
    started: bool = false, // true if called start
    resetted: bool = false, // true if called reset

    pub fn start() std.time.Timer.Error!TestTimer {
        return .{ .value = 42 };
    }

    pub fn reset(self: *TestTimer) void {
        self.resetted = true;
    }

    pub fn read(self: *TestTimer) u64 {
        return self.value;
    }
};

/// args in init are dup'ed using an allocator.
/// the caller must deinit in the end.
pub const TestChildProcess = struct {
    // test hooks
    spawn_callback: ?*const fn (*TestChildProcess) std.ChildProcess.SpawnError!void = null,
    wait_callback: ?*const fn (*TestChildProcess) anyerror!std.ChildProcess.Term = null,
    kill_callback: ?*const fn (*TestChildProcess) anyerror!std.ChildProcess.Term = null,
    spawned: bool = false,
    waited: bool = false,
    killed: bool = false,

    // original std ChildProcess init args
    allocator: std.mem.Allocator,
    argv: []const []const u8,

    pub fn init(argv: []const []const u8, allocator: std.mem.Allocator) TestChildProcess {
        var adup = allocator.alloc([]u8, argv.len) catch unreachable;
        for (argv) |v, i| {
            adup[i] = allocator.dupe(u8, v) catch unreachable;
        }
        return .{
            .allocator = allocator,
            .argv = adup,
        };
    }

    pub fn deinit(self: *TestChildProcess) void {
        for (self.argv) |v| self.allocator.free(v);
        self.allocator.free(self.argv);
    }

    pub fn spawn(self: *TestChildProcess) std.ChildProcess.SpawnError!void {
        defer self.spawned = true;
        if (self.spawn_callback) |cb| {
            return cb(self);
        }
    }

    pub fn wait(self: *TestChildProcess) anyerror!std.ChildProcess.Term {
        defer self.waited = true;
        if (self.wait_callback) |cb| {
            return cb(self);
        }
        return .{ .Exited = 0 };
    }

    pub fn spawnAndWait(self: *TestChildProcess) !std.ChildProcess.Term {
        try self.spawn();
        return self.wait();
    }

    pub fn kill(self: *TestChildProcess) !std.ChildProcess.Term {
        defer self.killed = true;
        if (self.kill_callback) |cb| {
            return cb(self);
        }
        return .{ .Exited = 0 };
    }
};

/// a nif.wpa.Control stub for tests.
pub const TestWpaControl = struct {
    ctrl_path: []const u8,
    opened: bool,
    attached: bool = false,
    scanned: bool = false,
    saved: bool = false,

    const Self = @This();

    pub fn open(path: [:0]const u8) !Self {
        return .{ .ctrl_path = path, .opened = true };
    }

    pub fn close(self: *Self) !void {
        self.opened = false;
    }

    pub fn attach(self: *Self) !void {
        self.attached = true;
    }

    pub fn detach(self: *Self) !void {
        self.attached = false;
    }

    pub fn pending(_: Self) !bool {
        return false;
    }

    pub fn receive(_: Self, _: [:0]u8) ![]const u8 {
        return &.{};
    }

    pub fn scan(self: *Self) !void {
        self.scanned = true;
    }

    pub fn saveConfig(self: *Self) !void {
        self.saved = true;
    }

    pub fn request(_: Self, _: [:0]const u8, _: [:0]u8, _: ?nif.wpa.ReqCallback) ![]const u8 {
        return &.{};
    }
};

/// similar to std.testing.expectEqual but compares slices with expectEqualSlices
/// or expectEqualStrings where slice element is a u8.
pub fn expectDeepEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    const t = std.testing;
    switch (@typeInfo(@TypeOf(actual))) {
        .Pointer => |p| {
            switch (p.size) {
                .One => try expectDeepEqual(expected.*, actual.*),
                .Slice => {
                    switch (@typeInfo(p.child)) {
                        .Pointer, .Struct, .Optional, .Union => {
                            var err: ?anyerror = blk: {
                                if (expected.len != actual.len) {
                                    std.debug.print("expected.len = {d}, actual.len = {d}\n", .{ expected.len, actual.len });
                                    break :blk error.ExpectDeepEqual;
                                }
                                break :blk null;
                            };
                            const n = std.math.min(expected.len, actual.len);
                            var i: usize = 0;
                            while (i < n) : (i += 1) {
                                expectDeepEqual(expected[i], actual[i]) catch |e| {
                                    std.debug.print("unequal slice elements at index {d}\n", .{i});
                                    return e;
                                };
                            }
                            if (err) |e| {
                                return e;
                            }
                        },
                        else => {
                            if (p.child == u8) {
                                try t.expectEqualStrings(expected, actual);
                            } else {
                                try t.expectEqualSlices(p.child, expected, actual);
                            }
                        },
                    }
                },
                else => try t.expectEqual(expected, actual),
            }
        },
        .Struct => |st| {
            inline for (st.fields) |f| {
                expectDeepEqual(@field(expected, f.name), @field(actual, f.name)) catch |err| {
                    std.debug.print("unequal field '{s}' of struct {any}\n", .{ f.name, @TypeOf(actual) });
                    return err;
                };
            }
        },
        .Optional => {
            if (expected) |x| {
                if (actual) |v| {
                    try expectDeepEqual(x, v);
                } else {
                    std.debug.print("expected {any}, found null\n", .{x});
                    return error.TestExpectDeepEqual;
                }
            } else {
                if (actual) |v| {
                    std.debug.print("expected null, found {any}\n", .{v});
                    return error.TestExpectDeepEqual;
                }
            }
        },
        .Union => |u| {
            if (u.tag_type == null) {
                @compileError("unable to compare untagged union values");
            }
            const Tag = std.meta.Tag(@TypeOf(expected));
            const atag = @as(Tag, actual);
            try t.expectEqual(@as(Tag, expected), atag);
            inline for (u.fields) |f| {
                if (std.mem.eql(u8, f.name, @tagName(atag))) {
                    try expectDeepEqual(@field(expected, f.name), @field(actual, f.name));
                    return;
                }
            }
            unreachable;
        },
        else => {
            try t.expectEqual(expected, actual);
        },
    }
}

test {
    _ = @import("nd.zig");
    _ = @import("nd/Daemon.zig");
    _ = @import("nd/SysService.zig");
    _ = @import("ngui.zig");

    std.testing.refAllDecls(@This());
}
