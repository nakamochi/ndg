//! ndg persistent configuration, loaded from and stored to disk in JSON format.
//! the structure is defined in `Data`.

const std = @import("std");

const logger = std.log.scoped(.config);

// default values
const SYSUPDATES_CRON_SCRIPT_PATH = "/etc/cron.hourly/sysupdate";
const SYSUPDATES_RUN_SCRIPT_NAME = "update.sh";
const SYSUPDATES_RUN_SCRIPT_PATH = "/ssd/sysupdates/" ++ SYSUPDATES_RUN_SCRIPT_NAME;

arena: *std.heap.ArenaAllocator, // data is allocated here
confpath: []const u8, // fs path to where data is persisted

mu: std.Thread.RwLock = .{},
data: Data,

/// top struct stored on disk.
/// access with `safeReadOnly` or lock/unlock `mu`.
pub const Data = struct {
    syschannel: SysupdatesChannel,
    syscronscript: []const u8,
    sysrunscript: []const u8,
};

/// enums must match git branches in https://git.qcode.ch/nakamochi/sysupdates.
pub const SysupdatesChannel = enum {
    master, // stable
    dev, // edge
};

const Config = @This();

/// confpath must outlive returned Config instance.
pub fn init(allocator: std.mem.Allocator, confpath: []const u8) !Config {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    return .{
        .arena = arena,
        .data = try initData(arena.allocator(), confpath),
        .confpath = confpath,
    };
}

pub fn deinit(self: Config) void {
    const allocator = self.arena.child_allocator;
    self.arena.deinit();
    allocator.destroy(self.arena);
}

fn initData(allocator: std.mem.Allocator, filepath: []const u8) !Data {
    const maxsize: usize = 1 << 20; // 1Mb JSON conf file size should be more than enough
    const bytes = std.fs.cwd().readFileAlloc(allocator, filepath, maxsize) catch |err| switch (err) {
        error.FileNotFound => return inferData(),
        else => return err,
    };
    defer allocator.free(bytes);
    const jopt = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    return std.json.parseFromSliceLeaky(Data, allocator, bytes, jopt) catch |err| {
        logger.err("initData: {any}", .{err});
        return error.BadConfigSyntax;
    };
}

fn inferData() Data {
    return .{
        .syschannel = inferSysupdatesChannel(SYSUPDATES_CRON_SCRIPT_PATH),
        .syscronscript = SYSUPDATES_CRON_SCRIPT_PATH,
        .sysrunscript = SYSUPDATES_RUN_SCRIPT_PATH,
    };
}

fn inferSysupdatesChannel(cron_script_path: []const u8) SysupdatesChannel {
    var buf: [1024]u8 = undefined;
    const bytes = std.fs.cwd().readFile(cron_script_path, &buf) catch return .master;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    // looking for "/ssd/sysupdates/update.sh <channel>?" where <channel> may be in quotes
    const needle = SYSUPDATES_RUN_SCRIPT_NAME;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle)) |i| {
            var s = line[i + needle.len ..];
            s = std.mem.trim(u8, s, " \n'\"");
            return std.meta.stringToEnum(SysupdatesChannel, s) orelse .master;
        }
    }
    return .master;
}

/// calls F while holding a readonly lock and passes on F's result as is.
pub fn safeReadOnly(self: *Config, comptime F: anytype) @typeInfo(@TypeOf(F)).Fn.return_type.? {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return F(self.data);
}

/// stores current `Config.data` to disk, into `Config.confpath`.
pub fn dump(self: *Config) !void {
    self.mu.lock();
    defer self.mu.unlock();
    return self.dumpUnguarded();
}

fn dumpUnguarded(self: Config) !void {
    const allocator = self.arena.child_allocator;
    const opt = .{ .mode = 0o600 };
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), self.confpath, opt);
    defer file.destroy();
    try std.json.stringify(self.data, .{ .whitespace = .indent_2 }, file.writer());
    try file.finish();
}

/// when run is set, executes the update after changing the channel.
/// executing an update may terminate and start a new nd+ngui instance.
pub fn switchSysupdates(self: *Config, chan: SysupdatesChannel, opt: struct { run: bool }) !void {
    self.mu.lock();
    defer self.mu.unlock();

    self.data.syschannel = chan;
    try self.dumpUnguarded();

    try self.genSysupdatesCronScript();
    if (opt.run) {
        try runSysupdates(self.arena.child_allocator, self.data.syscronscript);
    }
}

/// caller must hold self.mu.
fn genSysupdatesCronScript(self: Config) !void {
    if (self.data.sysrunscript.len == 0) {
        return error.NoSysRunScriptPath;
    }
    const allocator = self.arena.child_allocator;
    const opt = .{ .mode = 0o755 };
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), self.data.syscronscript, opt);
    defer file.destroy();

    const script =
        \\#!/bin/sh
        \\exec {[path]s} "{[chan]s}"
    ;
    try std.fmt.format(file.writer(), script, .{
        .path = self.data.sysrunscript,
        .chan = @tagName(self.data.syschannel),
    });
    try file.finish();
}

/// the scriptpath is typically the cronjob script, not a SYSUPDATES_RUN_SCRIPT
/// because the latter requires command args which is what cron script does.
fn runSysupdates(allocator: std.mem.Allocator, scriptpath: []const u8) !void {
    const res = try std.ChildProcess.exec(.{ .allocator = allocator, .argv = &.{scriptpath} });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    switch (res.term) {
        .Exited => |code| if (code != 0) {
            logger.err("runSysupdates: {s} exit code = {d}; stderr: {s}", .{ scriptpath, code, res.stderr });
            return error.RunSysupdatesBadExit;
        },
        else => {
            logger.err("runSysupdates: {s} term = {any}", .{ scriptpath, res.term });
            return error.RunSysupdatesBadTerm;
        },
    }
}

test "init existing" {
    const t = std.testing;
    const tt = @import("../test.zig");

    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();
    try tmp.dir.writeFile("conf.json",
        \\{
        \\"syschannel": "dev",
        \\"syscronscript": "/cron/sysupdates.sh",
        \\"sysrunscript": "/sysupdates/run.sh"
        \\}
    );
    const conf = try init(t.allocator, try tmp.join(&.{"conf.json"}));
    defer conf.deinit();
    try t.expectEqual(SysupdatesChannel.dev, conf.data.syschannel);
    try t.expectEqualStrings("/cron/sysupdates.sh", conf.data.syscronscript);
    try t.expectEqualStrings("/sysupdates/run.sh", conf.data.sysrunscript);
}

test "init null" {
    const t = std.testing;

    const conf = try init(t.allocator, "/non/existent/config/file");
    defer conf.deinit();
    try t.expectEqual(SysupdatesChannel.master, conf.data.syschannel);
    try t.expectEqualStrings(SYSUPDATES_CRON_SCRIPT_PATH, conf.data.syscronscript);
    try t.expectEqualStrings(SYSUPDATES_RUN_SCRIPT_PATH, conf.data.sysrunscript);
}

test "dump" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // the arena used only for the config instance.
    // purposefully skip arena deinit - expecting no mem leaks in conf usage here.
    var conf_arena = std.heap.ArenaAllocator.init(t.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    const confpath = try tmp.join(&.{"conf.json"});
    var conf = Config{
        .arena = &conf_arena,
        .confpath = confpath,
        .data = .{
            .syschannel = .master,
            .syscronscript = "cronscript.sh",
            .sysrunscript = "runscript.sh",
        },
    };
    // purposefully skip conf.deinit() - expecting no leaking allocations in conf.dump.
    try conf.dump();

    const parsed = try testLoadConfigData(confpath);
    defer parsed.deinit();
    try t.expectEqual(SysupdatesChannel.master, parsed.value.syschannel);
    try t.expectEqualStrings("cronscript.sh", parsed.value.syscronscript);
    try t.expectEqualStrings("runscript.sh", parsed.value.sysrunscript);
}

test "switch sysupdates and infer" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // the arena used only for the config instance.
    // purposefully skip arena deinit - expecting no mem leaks in conf usage here.
    var conf_arena = std.heap.ArenaAllocator.init(t.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    try tmp.dir.writeFile("conf.json", "");
    const confpath = try tmp.join(&.{"conf.json"});
    const cronscript = try tmp.join(&.{"cronscript.sh"});
    var conf = Config{
        .arena = &conf_arena,
        .confpath = confpath,
        .data = .{
            .syschannel = .master,
            .syscronscript = cronscript,
            .sysrunscript = SYSUPDATES_RUN_SCRIPT_PATH,
        },
    };
    // purposefully skip conf.deinit() - expecting no leaking allocations.

    try conf.switchSysupdates(.dev, .{ .run = false });
    const parsed = try testLoadConfigData(confpath);
    defer parsed.deinit();
    try t.expectEqual(SysupdatesChannel.dev, parsed.value.syschannel);
    try t.expectEqual(SysupdatesChannel.dev, inferSysupdatesChannel(cronscript));
}

test "switch sysupdates with .run=true" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // no arena deinit: expecting Config to
    var conf_arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    conf_arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    const runscript = "runscript.sh";
    try tmp.dir.writeFile(runscript,
        \\#!/bin/sh
        \\printf "$1" > "$(dirname "$0")/success"
    );
    {
        const file = try tmp.dir.openFile(runscript, .{});
        defer file.close();
        try file.chmod(0o755);
    }
    var conf = Config{
        .arena = conf_arena,
        .confpath = try tmp.join(&.{"conf.json"}),
        .data = .{
            .syschannel = .master,
            .syscronscript = try tmp.join(&.{"cronscript.sh"}),
            .sysrunscript = try tmp.join(&.{runscript}),
        },
    };
    defer conf.deinit();

    try conf.switchSysupdates(.dev, .{ .run = true });
    var buf: [10]u8 = undefined;
    try t.expectEqualStrings("dev", try tmp.dir.readFile("success", &buf));
}

fn testLoadConfigData(path: []const u8) !std.json.Parsed(Data) {
    const allocator = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(bytes);
    const jopt = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    return try std.json.parseFromSlice(Data, allocator, bytes, jopt);
}
