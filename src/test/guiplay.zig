const std = @import("std");
const time = std.time;
const os = std.os;

const comm = @import("comm");

const logger = std.log.scoped(.play);
const stderr = std.io.getStdErr().writer();

var ngui_proc: std.ChildProcess = undefined;
var sigquit = false;

fn sighandler(sig: c_int) callconv(.C) void {
    logger.info("received signal {} (TERM={} INT={})", .{ sig, os.SIG.TERM, os.SIG.INT });
    switch (sig) {
        os.SIG.INT, os.SIG.TERM => sigquit = true,
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

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit()) {
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

    const sa = os.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    try os.sigaction(os.SIG.INT, &sa, null);
    try os.sigaction(os.SIG.TERM, &sa, null);

    const uireader = ngui_proc.stdout.?.reader();
    const uiwriter = ngui_proc.stdin.?.writer();
    comm.write(gpa, uiwriter, .ping) catch |err| {
        logger.err("comm.write ping: {any}", .{err});
    };

    var poweroff = false;
    while (!sigquit) {
        std.atomic.spinLoopHint();
        time.sleep(100 * time.ns_per_ms);
        if (poweroff) {
            // GUI is not expected to send anything back at this point,
            // so just loop until we're terminated by a SIGTERM (sigquit).
            continue;
        }

        const msg = comm.read(gpa, uireader) catch |err| {
            logger.err("comm.read: {any}", .{err});
            continue;
        };
        logger.debug("got ui msg tagged {s}", .{@tagName(msg)});
        switch (msg) {
            .pong => {
                logger.info("received pong from ngui", .{});
            },
            .poweroff => {
                poweroff = true;

                logger.info("sending poweroff status1", .{});
                var s1: comm.Message.PoweroffProgress = .{ .services = &.{
                    .{ .name = "lnd", .stopped = false, .err = null },
                    .{ .name = "bitcoind", .stopped = false, .err = null },
                } };
                comm.write(gpa, uiwriter, .{ .poweroff_progress = s1 }) catch |err| logger.err("comm.write: {any}", .{err});

                time.sleep(2 * time.ns_per_s);
                logger.info("sending poweroff status2", .{});
                var s2: comm.Message.PoweroffProgress = .{ .services = &.{
                    .{ .name = "lnd", .stopped = true, .err = null },
                    .{ .name = "bitcoind", .stopped = false, .err = null },
                } };
                comm.write(gpa, uiwriter, .{ .poweroff_progress = s2 }) catch |err| logger.err("comm.write: {any}", .{err});

                time.sleep(3 * time.ns_per_s);
                logger.info("sending poweroff status3", .{});
                var s3: comm.Message.PoweroffProgress = .{ .services = &.{
                    .{ .name = "lnd", .stopped = true, .err = null },
                    .{ .name = "bitcoind", .stopped = true, .err = null },
                } };
                comm.write(gpa, uiwriter, .{ .poweroff_progress = s3 }) catch |err| logger.err("comm.write: {any}", .{err});
            },
            else => {},
        }
    }

    logger.info("killing ngui", .{});
    const term = ngui_proc.kill();
    logger.info("ngui_proc.kill term: {any}", .{term});
}
