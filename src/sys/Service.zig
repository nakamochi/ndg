///! an interface to programmatically manage a system service.
///! safe for concurrent use.
const std = @import("std");
const types = @import("../types.zig");

// known service names
pub const LND = "lnd";
pub const BITCOIND = "bitcoind";

const Error = error{
    SysServiceStopInProgress,
    SysServiceBadStartCode,
    SysServiceBadStartTerm,
    SysServiceBadStopCode,
    SysServiceBadStopTerm,
};

allocator: std.mem.Allocator,
name: []const u8,
stop_wait_sec: ?u32 = null,

/// mutex guards all fields below.
mu: std.Thread.Mutex = .{},
stat: State,
stop_proc: types.ChildProcess = undefined,
stop_err: ?anyerror = null,

/// service current state.
/// the .initial value is a temporary solution until service watcher and start
/// are implemnted: at the moment, SysService can only stop services, nothing else.
pub const Status = enum(u8) {
    initial, // TODO: get rid of "initial" and infer the actual state
    started,
    stopping,
    stopped,
};

const State = union(Status) {
    initial: void,
    started: std.ChildProcess.Term,
    stopping: void,
    stopped: std.ChildProcess.Term,
};

const SysService = @This();

pub const InitOpts = struct {
    /// how long to wait for the service to stop before SIGKILL.
    /// if unspecified, default for sv is 7.
    stop_wait_sec: ?u32 = null,
};

/// must deinit when done.
pub fn init(a: std.mem.Allocator, name: []const u8, opts: InitOpts) SysService {
    return .{
        .allocator = a,
        .name = name,
        .stop_wait_sec = opts.stop_wait_sec,
        .stat = .initial,
    };
}

pub fn deinit(_: *SysService) void {}

/// reports current state of the service.
/// note that it may incorrectly reflect the actual running service state
/// since SysService has no process watcher implementation yet.
pub fn status(self: *SysService) Status {
    self.mu.lock();
    defer self.mu.unlock();
    return self.stat;
}

/// returns an error during last stop call, if any.
pub fn lastStopError(self: *SysService) ?anyerror {
    self.mu.lock();
    defer self.mu.unlock();
    return self.stop_err;
}

/// launches a service start procedure and returns as soon as the startup script
/// terminates: whether the service actually started successefully is not necessarily
/// indicated by the function return.
pub fn start(self: *SysService) !void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.stat) {
        .stopping => return Error.SysServiceStopInProgress,
        .initial, .started, .stopped => {}, // proceed
    }

    var proc = types.ChildProcess.init(&.{ "sv", "start", self.name }, self.allocator);
    const term = try proc.spawnAndWait();
    self.stat = .{ .started = term };
    switch (term) {
        .Exited => |code| if (code != 0) return Error.SysServiceBadStartCode,
        else => return Error.SysServiceBadStartTerm,
    }
}

/// launches a service stop procedure and returns immediately.
/// callers must invoke stopWait to release all resources used by the stop.
pub fn stop(self: *SysService) !void {
    self.mu.lock();
    defer self.mu.unlock();

    self.stop_err = null;
    self.spawnStopUnguarded() catch |err| {
        self.stop_err = err;
        return err;
    };
}

/// blocks until the service stopping procedure terminates.
/// an error is returned also in the case where stopping a service failed.
pub fn stopWait(self: *SysService) !void {
    self.mu.lock();
    defer self.mu.unlock();

    self.stop_err = null;
    self.spawnStopUnguarded() catch |err| {
        self.stop_err = err;
        return err;
    };

    const term = self.stop_proc.wait() catch |err| {
        self.stop_err = err;
        return err;
    };
    self.stat = .{ .stopped = term };
    switch (term) {
        .Exited => |code| if (code != 0) {
            self.stop_err = Error.SysServiceBadStopCode;
        },
        else => {
            self.stop_err = Error.SysServiceBadStopTerm;
        },
    }
    if (self.stop_err) |err| {
        return err;
    }
}

/// actual internal body of SysService.stop: stopWait also uses this.
/// callers must hold self.mu.
fn spawnStopUnguarded(self: *SysService) !void {
    switch (self.stat) {
        .stopping => return, // already in progress
        // intentionally let .stopped state pass through: can't see any downsides.
        .initial, .started, .stopped => {},
    }

    // use arena to simplify stop proc args construction.
    var arena_alloc = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var argv = std.ArrayList([]const u8).init(arena);
    try argv.append("sv");
    if (self.stop_wait_sec) |sec| {
        const s = try std.fmt.allocPrint(arena, "{d}", .{sec});
        try argv.appendSlice(&.{ "-w", s });
    }
    try argv.appendSlice(&.{ "stop", self.name });
    // can't use arena alloc since it's deinited upon return but proc needs alloc until wait'ed.
    // child process dup's argv when spawned and auto-frees all resources when done (wait'ed).
    self.stop_proc = types.ChildProcess.init(argv.items, self.allocator);
    try self.stop_proc.spawn();
    self.stat = .stopping;
}

test "stop then stopWait" {
    const t = std.testing;

    var sv = SysService.init(t.allocator, "testsv1", .{ .stop_wait_sec = 13 });
    try t.expectEqual(Status.initial, sv.status());

    try sv.stop();
    try t.expectEqual(Status.stopping, sv.status());
    defer sv.stop_proc.deinit(); // TestChildProcess

    try t.expect(sv.stop_proc.spawned);
    try t.expect(!sv.stop_proc.waited);
    try t.expect(!sv.stop_proc.killed);
    const cmd = try std.mem.join(t.allocator, " ", sv.stop_proc.argv);
    defer t.allocator.free(cmd);
    try t.expectEqualStrings("sv -w 13 stop testsv1", cmd);

    try sv.stopWait();
    try t.expect(sv.stop_proc.waited);
    try t.expect(!sv.stop_proc.killed);
}

test "stopWait" {
    const t = std.testing;

    var sv = SysService.init(t.allocator, "testsv2", .{ .stop_wait_sec = 14 });
    try sv.stopWait();
    defer sv.stop_proc.deinit(); // TestChildProcess

    try t.expect(sv.stop_proc.spawned);
    try t.expect(sv.stop_proc.waited);
    try t.expect(!sv.stop_proc.killed);
    const cmd = try std.mem.join(t.allocator, " ", sv.stop_proc.argv);
    defer t.allocator.free(cmd);
    try t.expectEqualStrings("sv -w 14 stop testsv2", cmd);
}

test "stop with default wait" {
    const t = std.testing;

    var sv = SysService.init(t.allocator, "testsv3", .{});
    try sv.stopWait();
    defer sv.stop_proc.deinit(); // TestChildProcess

    const cmd = try std.mem.join(t.allocator, " ", sv.stop_proc.argv);
    defer t.allocator.free(cmd);
    try t.expectEqualStrings("sv stop testsv3", cmd);
}
