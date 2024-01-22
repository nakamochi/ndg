const builtin = @import("builtin");
const std = @import("std");
const nif = @import("nif");

const tt = @import("test.zig");

pub usingnamespace if (builtin.is_test) struct {
    // stubs, mocks, overrides for testing.
    pub const Timer = tt.TestTimer;
    pub const ChildProcess = tt.TestChildProcess;
    pub const WpaControl = tt.TestWpaControl;

    /// always returns caller's (current process) user/group IDs.
    /// atm works only on linux via getuid syscalls.
    pub fn getUserInfo(name: []const u8) !std.process.UserInfo {
        _ = name;
        return .{
            .uid = std.os.linux.getuid(),
            .gid = std.os.linux.getgid(),
        };
    }
} else struct {
    // regular types for production code.
    pub const Timer = std.time.Timer;
    pub const ChildProcess = std.ChildProcess;
    pub const WpaControl = nif.wpa.Control;

    pub fn getUserInfo(name: []const u8) !std.process.UserInfo {
        return std.process.getUserInfo(name);
    }
};

/// prefer this type over the std.ArrayList(u8) just to ensure consistency
/// and potential regressions. For example, comm module uses it for read/write.
pub const ByteArrayList = std.ArrayList(u8);

/// an OS-based I/O pipe; see man(2) pipe.
pub const IoPipe = struct {
    r: std.fs.File,
    w: std.fs.File,

    /// a pipe must be close'ed when done.
    pub fn create() std.os.PipeError!IoPipe {
        const fds = try std.os.pipe();
        return .{
            .r = std.fs.File{ .handle = fds[0] },
            .w = std.fs.File{ .handle = fds[1] },
        };
    }

    pub fn close(self: IoPipe) void {
        self.w.close();
        self.r.close();
    }

    pub fn reader(self: IoPipe) std.fs.File.Reader {
        return self.r.reader();
    }

    pub fn writer(self: IoPipe) std.fs.File.Writer {
        return self.w.writer();
    }
};

pub const StringList = struct {
    l: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .l = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    /// duplicates unowned items into the returned list.
    pub fn fromUnowned(allocator: std.mem.Allocator, unowned: []const []const u8) !Self {
        var list = Self.init(allocator);
        errdefer list.deinit();
        for (unowned) |item| {
            try list.append(item);
        }
        return list;
    }

    pub fn deinit(self: Self) void {
        for (self.l.items) |a| {
            self.allocator.free(a);
        }
        self.l.deinit();
    }

    pub fn append(self: *Self, s: []const u8) !void {
        const item = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(item);
        try self.l.append(item);
    }

    pub fn items(self: Self) []const []const u8 {
        return self.l.items;
    }
};

pub fn Deinitable(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            var res = Self{
                .arena = try allocator.create(std.heap.ArenaAllocator),
                .value = undefined,
            };
            res.arena.* = std.heap.ArenaAllocator.init(allocator);
            return res;
        }

        pub fn deinit(self: Self) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}
