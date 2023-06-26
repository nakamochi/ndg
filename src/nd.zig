const buildopts = @import("build_options");
const std = @import("std");
const os = std.os;
const sys = os.system;
const time = std.time;
const Address = std.net.Address;

const nif = @import("nif");

const comm = @import("comm.zig");
const Daemon = @import("nd/Daemon.zig");
const screen = @import("ui/screen.zig");

const logger = std.log.scoped(.nd);
const stderr = std.io.getStdErr().writer();

/// prints usage help text to stderr.
fn usage(prog: []const u8) !void {
    try stderr.print(
        \\usage: {s} -gui path/to/ngui -gui-user username -wpa path
        \\
        \\nd is a short for nakamochi daemon.
        \\the daemon executes ngui as a child process and runs until
        \\TERM or INT signal is received.
        \\
        \\nd logs messages to stderr.
        \\
    , .{prog});
}

/// prints messages in the same way std.fmt.format does and exits the process
/// with a non-zero code.
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    if (fmt[fmt.len - 1] != '\n') {
        stderr.writeByte('\n') catch {};
    }
    std.process.exit(1);
}

/// nd program args. see usage.
const NdArgs = struct {
    gui: ?[:0]const u8 = null, // = "ngui",
    gui_user: ?[:0]const u8 = null, // u8 = "uiuser",
    wpa: ?[:0]const u8 = null, // = "/var/run/wpa_supplicant/wlan0",

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.gui) |p| allocator.free(p);
        if (self.gui_user) |p| allocator.free(p);
        if (self.wpa) |p| allocator.free(p);
    }
};

/// parses and validates program args.
fn parseArgs(gpa: std.mem.Allocator) !NdArgs {
    var flags: NdArgs = .{};

    var args = try std.process.ArgIterator.initWithAllocator(gpa);
    defer args.deinit();
    const prog = args.next() orelse return error.NoProgName;

    var lastarg: enum {
        none,
        gui,
        gui_user,
        wpa,
    } = .none;
    while (args.next()) |a| {
        switch (lastarg) {
            .gui => {
                flags.gui = try gpa.dupeZ(u8, a);
                lastarg = .none;
                continue;
            },
            .gui_user => {
                flags.gui_user = try gpa.dupeZ(u8, a);
                lastarg = .none;
                continue;
            },
            .wpa => {
                flags.wpa = try gpa.dupeZ(u8, a);
                lastarg = .none;
                continue;
            },
            .none => {},
        }
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "-help") or std.mem.eql(u8, a, "--help")) {
            usage(prog) catch {};
            std.process.exit(1);
        } else if (std.mem.eql(u8, a, "-v")) {
            try stderr.print("{any}\n", .{buildopts.semver});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "-gui")) {
            lastarg = .gui;
        } else if (std.mem.eql(u8, a, "-gui-user")) {
            lastarg = .gui_user;
        } else if (std.mem.eql(u8, a, "-wpa")) {
            lastarg = .wpa;
        } else {
            fatal("unknown arg name {s}", .{a});
        }
    }

    if (lastarg != .none) {
        fatal("invalid arg: {s} requires a value", .{@tagName(lastarg)});
    }
    if (flags.gui == null) fatal("missing -gui arg", .{});
    if (flags.gui_user == null) fatal("missing -gui-user arg", .{});
    if (flags.wpa == null) fatal("missing -wpa arg", .{});

    return flags;
}

/// quit signals nd to exit.
/// TODO: thread-safety?
var quit = false;

fn sighandler(sig: c_int) callconv(.C) void {
    logger.info("got signal {}; exiting...\n", .{sig});
    quit = true;
}

pub fn main() !void {
    // main heap allocator used throughout the lifetime of nd
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit()) {
        logger.err("memory leaks detected", .{});
    };
    const gpa = gpa_state.allocator();
    // parse program args first thing and fail fast if invalid
    const args = try parseArgs(gpa);
    defer args.deinit(gpa);
    logger.info("ndg version {any}", .{buildopts.semver});

    // reset the screen backlight to normal power regardless
    // of its previous state.
    screen.backlight(.on) catch |err| {
        logger.err("backlight: {any}", .{err});
    };

    // start ngui, unless -nogui mode
    var ngui = std.ChildProcess.init(&.{args.gui.?}, gpa);
    ngui.stdin_behavior = .Pipe;
    ngui.stdout_behavior = .Pipe;
    ngui.stderr_behavior = .Inherit;
    // fix zig std: child_process.zig:125:33: error: container 'std.os' has no member called 'getUserInfo'
    //ngui.setUserName(args.gui_user) catch |err| {
    //    fatal("unable to set gui username to {s}: {s}", .{args.gui_user.?, err});
    //};
    // TODO: the following fails with "cannot open framebuffer device: Permission denied"
    // but works with "doas -u uiuser ngui"
    // ftr, zig uses setreuid and setregid
    //const uiuser = std.process.getUserInfo(args.gui_user.?) catch |err| {
    //    fatal("unable to set gui username to {s}: {any}", .{ args.gui_user.?, err });
    //};
    //ngui.uid = uiuser.uid;
    //ngui.gid = uiuser.gid;
    // ngui.env_map = ...
    ngui.spawn() catch |err| {
        fatal("unable to start ngui: {any}", .{err});
    };
    // TODO: thread-safety, esp. uiwriter
    const uireader = ngui.stdout.?.reader();
    const uiwriter = ngui.stdin.?.writer();
    // send UI a ping as the first thing to make sure pipes are working.
    // https://git.qcode.ch/nakamochi/ndg/issues/16
    comm.write(gpa, uiwriter, .ping) catch |err| {
        logger.err("comm.write ping: {any}", .{err});
    };

    // graceful shutdown; see sigaction(2)
    const sa = os.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    try os.sigaction(os.SIG.INT, &sa, null);
    //TODO: try os.sigaction(os.SIG.TERM, &sa, null);

    // start network monitor
    var ctrl = try nif.wpa.Control.open(args.wpa.?);
    defer ctrl.close() catch {};
    var nd: Daemon = .{
        .allocator = gpa,
        .uiwriter = uiwriter,
        .wpa_ctrl = ctrl,
    };
    try nd.start();
    // send the UI network report right away, without scanning wifi
    nd.reportNetworkStatus(.{ .scan = false });

    // comm with ui loop; run until exit is requested
    var poweroff = false;
    while (!quit) {
        time.sleep(100 * time.ns_per_ms);
        // note: uireader.read is blocking
        // TODO: handle error.EndOfStream - ngui exited
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
                logger.info("poweroff requested; terminating", .{});
                quit = true;
                poweroff = true;
            },
            .get_network_report => |req| {
                nd.reportNetworkStatus(.{ .scan = req.scan });
            },
            .wifi_connect => |req| {
                nd.startConnectWifi(req.ssid, req.password) catch |err| {
                    logger.err("startConnectWifi: {any}", .{err});
                };
            },
            .standby => {
                logger.info("entering standby mode", .{});
                nd.standby() catch |err| {
                    logger.err("nd.standby: {any}", .{err});
                };
            },
            .wakeup => {
                logger.info("wakeup from standby", .{});
                nd.wakeup() catch |err| {
                    logger.err("nd.wakeup: {any}", .{err});
                };
            },
            else => logger.warn("unhandled msg tag {s}", .{@tagName(msg)}),
        }
        comm.free(gpa, msg);
    }

    // shutdown
    _ = ngui.kill() catch |err| logger.err("ngui.kill: {any}", .{err});
    nd.stop();
    if (poweroff) {
        svShutdown(gpa);
        var off = std.ChildProcess.init(&.{"poweroff"}, gpa);
        _ = try off.spawnAndWait();
    }
}

/// shut down important services manually.
/// TODO: make this OS-agnostic
fn svShutdown(allocator: std.mem.Allocator) void {
    // sv waits 7sec by default but bitcoind and lnd need more
    // http://smarden.org/runit/
    const Argv = []const []const u8;
    const cmds: []const Argv = &.{
        &.{ "sv", "-w", "600", "stop", "lnd" },
        &.{ "sv", "-w", "600", "stop", "bitcoind" },
    };
    var procs: [cmds.len]?std.ChildProcess = undefined;
    for (cmds) |argv, i| {
        var p = std.ChildProcess.init(argv, allocator);
        if (p.spawn()) {
            procs[i] = p;
        } else |err| {
            logger.err("{s}: {any}", .{ argv, err });
        }
    }
    for (procs) |_, i| {
        var p = procs[i];
        if (p != null) {
            _ = p.?.wait() catch |err| logger.err("{any}", .{err});
        }
    }
}
