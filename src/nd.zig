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
        \\usage: {[prog]s} -gui path/to/ngui -gui-user username -wpa path [-conf {[confpath]s}]
        \\
        \\nd is a short for nakamochi daemon.
        \\the daemon executes ngui as a child process and runs until
        \\TERM or INT signal is received.
        \\
        \\nd logs messages to stderr.
        \\
    , .{ .prog = prog, .confpath = NdArgs.defaultConf });
}

/// nd program flags. see usage.
const NdArgs = struct {
    conf: ?[:0]const u8 = null,
    gui: ?[:0]const u8 = null,
    gui_user: ?[:0]const u8 = null,
    wpa: ?[:0]const u8 = null,

    /// default path for nd config file, read or created during startup.
    const defaultConf = "/home/uiuser/conf.json";

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.conf) |p| allocator.free(p);
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
        conf,
        gui,
        gui_user,
        wpa,
    } = .none;
    while (args.next()) |a| {
        switch (lastarg) {
            .conf => {
                flags.conf = try gpa.dupeZ(u8, a);
                lastarg = .none;
                continue;
            },
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
        } else if (std.mem.eql(u8, a, "-conf")) {
            lastarg = .conf;
        } else if (std.mem.eql(u8, a, "-gui")) {
            lastarg = .gui;
        } else if (std.mem.eql(u8, a, "-gui-user")) {
            lastarg = .gui_user;
        } else if (std.mem.eql(u8, a, "-wpa")) {
            lastarg = .wpa;
        } else {
            logger.err("unknown arg name {s}", .{a});
            return error.UnknownArgName;
        }
    }
    if (lastarg != .none) {
        logger.err("invalid arg: {s} requires a value", .{@tagName(lastarg)});
        return error.MissinArgValue;
    }

    if (flags.conf == null) {
        flags.conf = NdArgs.defaultConf;
    }
    if (flags.gui == null) {
        logger.err("missing -gui arg", .{});
        return error.MissingGuiFlag;
    }
    if (flags.gui_user == null) {
        logger.err("missing -gui-user arg", .{});
        return error.MissinGuiUserFlag;
    }
    if (flags.wpa == null) {
        logger.err("missing -wpa arg", .{});
        return error.MissingWpaFlag;
    }

    return flags;
}

/// sigquit tells nd to exit.
var sigquit: std.Thread.ResetEvent = .{};

fn sighandler(sig: c_int) callconv(.C) void {
    if (sigquit.isSet()) {
        return;
    }
    switch (sig) {
        os.SIG.INT, os.SIG.TERM => sigquit.set(),
        else => {},
    }
}

pub fn main() !void {
    // main heap allocator used throughout the lifetime of nd
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit() == .leak) {
        logger.err("memory leaks detected", .{});
    };
    const gpa = gpa_state.allocator();

    // parse program args first thing and fail fast if invalid
    const args = try parseArgs(gpa);
    defer args.deinit(gpa);
    logger.info("ndg version {any}", .{buildopts.semver});

    // reset the screen backlight to normal power regardless
    // of its previous state.
    screen.backlight(.on) catch |err| logger.err("backlight: {any}", .{err});

    // start ngui, unless -nogui mode
    const gui_path = args.gui.?; // guaranteed to be non-null
    var ngui = std.ChildProcess.init(&.{gui_path}, gpa);
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
        logger.err("unable to start ngui at path {s}", .{gui_path});
        return err;
    };
    // if the daemon fails to start and its process exits, ngui may hang forever
    // preventing system services monitoring to detect a failure and restart nd.
    // so, make sure to kill the ngui child process on fatal failures.
    errdefer _ = ngui.kill() catch {};

    // the i/o is closed as soon as ngui child process terminates.
    // note: read(2) indicates file destriptor i/o is atomic linux since 3.14.
    const uireader = ngui.stdout.?.reader();
    const uiwriter = ngui.stdin.?.writer();
    comm.initPipe(gpa, .{ .r = ngui.stdout.?, .w = ngui.stdin.? });

    // send UI a ping right away to make sure pipes are working, crash otherwise.
    comm.pipeWrite(.ping) catch |err| {
        logger.err("comm.write ping: {any}", .{err});
        return err;
    };

    var nd = try Daemon.init(.{
        .allocator = gpa,
        .confpath = args.conf.?,
        .uir = uireader,
        .uiw = uiwriter,
        .wpa = args.wpa.?,
    });
    defer nd.deinit();
    try nd.start();

    // graceful shutdown; see sigaction(2)
    const sa = os.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    try os.sigaction(os.SIG.INT, &sa, null);
    try os.sigaction(os.SIG.TERM, &sa, null);
    sigquit.wait();
    logger.info("sigquit: terminating ...", .{});

    // reached here due to sig TERM or INT.
    // tell deamon to terminate threads.
    nd.stop();
    // once ngui exits, it'll close uireader/writer i/o from child proc
    // which lets the daemon's wait() to return.
    _ = ngui.kill() catch |err| logger.err("ngui.kill: {any}", .{err});
    nd.wait();
}
