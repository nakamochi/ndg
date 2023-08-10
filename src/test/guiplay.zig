const std = @import("std");
const time = std.time;
const os = std.os;

const comm = @import("comm");

const logger = std.log.scoped(.play);
const stderr = std.io.getStdErr().writer();

var ngui_proc: std.ChildProcess = undefined;
var sigquit: std.Thread.ResetEvent = .{};

fn sighandler(sig: c_int) callconv(.C) void {
    logger.info("received signal {} (TERM={} INT={})", .{ sig, os.SIG.TERM, os.SIG.INT });
    switch (sig) {
        os.SIG.INT, os.SIG.TERM => sigquit.set(),
        else => {},
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    if (fmt[fmt.len - 1] != '\n') {
        stderr.writeByte('\n') catch {};
    }
    std.process.exit(1);
}

const Flags = struct {
    ngui_path: ?[:0]const u8 = null,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.ngui_path) |p| allocator.free(p);
    }
};

fn parseArgs(gpa: std.mem.Allocator) !Flags {
    var flags: Flags = .{};

    var args = try std.process.ArgIterator.initWithAllocator(gpa);
    defer args.deinit();
    const prog = args.next() orelse return error.NoProgName;

    var lastarg: enum {
        none,
        ngui_path,
    } = .none;
    while (args.next()) |a| {
        switch (lastarg) {
            .none => {},
            .ngui_path => {
                flags.ngui_path = try gpa.dupeZ(u8, a);
                lastarg = .none;
                continue;
            },
        }
        if (std.mem.eql(u8, a, "-ngui")) {
            lastarg = .ngui_path;
        } else {
            fatal("unknown arg name {s}", .{a});
        }
    }
    if (lastarg != .none) {
        fatal("invalid arg: {s} requires a value", .{@tagName(lastarg)});
    }

    if (flags.ngui_path == null) {
        const dir = std.fs.path.dirname(prog) orelse "/";
        flags.ngui_path = try std.fs.path.joinZ(gpa, &.{ dir, "ngui" });
    }

    return flags;
}

fn commReadThread(gpa: std.mem.Allocator, r: anytype, w: anytype) void {
    comm.write(gpa, w, .ping) catch |err| logger.err("comm.write ping: {any}", .{err});

    while (true) {
        std.atomic.spinLoopHint();
        time.sleep(100 * time.ns_per_ms);

        const msg = comm.read(gpa, r) catch |err| {
            if (err == error.EndOfStream) {
                sigquit.set();
                break;
            }
            logger.err("comm.read: {any}", .{err});
            continue;
        };
        defer msg.deinit();

        logger.debug("got msg: {s}", .{@tagName(msg.value)});
        switch (msg.value) {
            .pong => {
                logger.info("received pong from ngui", .{});
            },
            .poweroff => {
                logger.info("sending poweroff status1", .{});
                var s1: comm.Message.PoweroffProgress = .{ .services = &.{
                    .{ .name = "lnd", .stopped = false, .err = null },
                    .{ .name = "bitcoind", .stopped = false, .err = null },
                } };
                comm.write(gpa, w, .{ .poweroff_progress = s1 }) catch |err| logger.err("comm.write: {any}", .{err});

                time.sleep(2 * time.ns_per_s);
                logger.info("sending poweroff status2", .{});
                var s2: comm.Message.PoweroffProgress = .{ .services = &.{
                    .{ .name = "lnd", .stopped = true, .err = null },
                    .{ .name = "bitcoind", .stopped = false, .err = null },
                } };
                comm.write(gpa, w, .{ .poweroff_progress = s2 }) catch |err| logger.err("comm.write: {any}", .{err});

                time.sleep(3 * time.ns_per_s);
                logger.info("sending poweroff status3", .{});
                var s3: comm.Message.PoweroffProgress = .{ .services = &.{
                    .{ .name = "lnd", .stopped = true, .err = null },
                    .{ .name = "bitcoind", .stopped = true, .err = null },
                } };
                comm.write(gpa, w, .{ .poweroff_progress = s3 }) catch |err| logger.err("comm.write: {any}", .{err});
            },
            else => {},
        }
    }

    logger.info("exiting comm thread loop", .{});
    sigquit.set();
}

fn commWriteThread(gpa: std.mem.Allocator, w: anytype) !void {
    var sectimer = try time.Timer.start();
    var block_count: u64 = 801365;

    while (true) {
        time.sleep(time.ns_per_s);
        if (sectimer.read() < 3 * time.ns_per_s) {
            continue;
        }
        sectimer.reset();

        block_count += 1;
        const now = time.timestamp();

        const btcrep: comm.Message.BitcoindReport = .{
            .blocks = block_count,
            .headers = block_count,
            .timestamp = @intCast(now),
            .hash = "00000000000000000002bf8029f6be4e40b4a3e0e161b6a1044ddaf9eb126504",
            .ibd = false,
            .verifyprogress = 100,
            .diskusage = 567119364054,
            .version = "/Satoshi:24.0.1/",
            .conn_in = 8,
            .conn_out = 10,
            .warnings = "",
            .localaddr = &.{},
            .mempool = .{
                .loaded = true,
                .txcount = 100000 + block_count,
                .usage = @min(200123456 + block_count * 10, 300000000),
                .max = 300000000,
                .totalfee = 2.23049932,
                .minfee = 0.00004155,
                .fullrbf = false,
            },
        };
        comm.write(gpa, w, .{ .bitcoind_report = btcrep }) catch |err| logger.err("comm.write: {any}", .{err});
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit() == .leak) {
        logger.err("memory leaks detected", .{});
    };
    const gpa = gpa_state.allocator();
    const flags = try parseArgs(gpa);
    defer flags.deinit(gpa);

    ngui_proc = std.ChildProcess.init(&.{flags.ngui_path.?}, gpa);
    ngui_proc.stdin_behavior = .Pipe;
    ngui_proc.stdout_behavior = .Pipe;
    ngui_proc.stderr_behavior = .Inherit;
    ngui_proc.spawn() catch |err| {
        fatal("unable to start ngui: {any}", .{err});
    };

    // ngui proc stdio is auto-closed as soon as its main process terminates.
    const uireader = ngui_proc.stdout.?.reader();
    const uiwriter = ngui_proc.stdin.?.writer();
    const th1 = try std.Thread.spawn(.{}, commReadThread, .{ gpa, uireader, uiwriter });
    th1.detach();
    const th2 = try std.Thread.spawn(.{}, commWriteThread, .{ gpa, uiwriter });
    th2.detach();

    const sa = os.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    try os.sigaction(os.SIG.INT, &sa, null);
    try os.sigaction(os.SIG.TERM, &sa, null);
    sigquit.wait();

    logger.info("killing ngui", .{});
    const term = ngui_proc.kill();
    logger.info("ngui_proc.kill term: {any}", .{term});
}
