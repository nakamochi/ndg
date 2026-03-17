const buildopts = @import("build_options");
const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("grp.h");
    @cInclude("pwd.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

// Best-effort check to avoid signaling a child that has already been reaped.
// This does not fully eliminate PID reuse races: another thread may reap the
// child after this probe returns 0 and before termThenKill() sends signals.
// A complete fix requires exclusive child ownership or pidfd-based signaling.
fn safeTermThenKillGui(ngui: anytype) void {
    const pid = ngui.pid;
    var status: c_int = 0;

    while (true) {
        // Probe child state without blocking.
        const r = c.waitpid(@as(c.pid_t, @intCast(pid)), &status, c.WNOHANG);

        if (r == 0) {
            // Child is still running; it's safe to perform the usual TERM/KILL logic.
            ngui.termThenKill();
            return;
        }

        if (r == -1) {
            const err = getErrno();

            if (err == c.EINTR) {
                // Interrupted by a signal; retry the probe.
                continue;
            }

            if (err == c.ECHILD) {
                // No such child (likely already reaped by watcher); avoid signaling
                // to prevent hitting a recycled PID.
                return;
            }

            // On other errors, preserve existing behavior by falling back to
            // termThenKill(), even though it might fail; this maintains semantics
            // while still protecting the common ECHILD case.
            ngui.termThenKill();
            return;
        }

        // r > 0: we just reaped the child here; no need to send any signals and we
        // should not risk racing with PID reuse by calling termThenKill().
        return;
    }
}

const time = std.time;
const Address = std.net.Address;

const nif = @import("nif");

const comm = @import("comm.zig");
const Config = @import("nd/Config.zig");
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
        posix.SIG.INT, posix.SIG.TERM => sigquit.set(),
        else => {},
    }
}

fn getErrno() c_int {
    // Works on glibc + musl; both provide __errno_location()
    return c.__errno_location().*;
}

const ChildFailStage = enum(u8) {
    Dup2Stdin,
    Dup2Stdout,
    Dup2Close,
    UsernameZ,
    Getpwnam,
    Initgroups,
    Setgid,
    Setuid,
    ArgvAlloc,
    ArgvDupeZ,
    Execvp,
    ErrWrite,
};

const ChildFail = extern struct {
    stage: ChildFailStage,
    errno_: c_int,
};

fn closeIfOpen(fd: *posix.fd_t) void {
    if (fd.* >= 0) {
        _ = c.close(fd.*);
        fd.* = -1;
    }
}

fn setCloexec(fd: posix.fd_t) !void {
    // F_GETFD
    var flags: c_int = 0;
    while (true) {
        const r = c.fcntl(fd, c.F_GETFD);
        if (r >= 0) {
            flags = r;
            break;
        }
        const e = getErrno();
        if (e == c.EINTR) continue;
        return error.SetCloexecFailed;
    }

    // F_SETFD
    while (true) {
        const r = c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC);
        if (r >= 0) break;
        const e = getErrno();
        if (e == c.EINTR) continue;
        return error.SetCloexecFailed;
    }
}

fn childReportAndExit(err_fd: posix.fd_t, stage: ChildFailStage, code: u8) noreturn {
    var rec = ChildFail{
        .stage = stage,
        .errno_ = getErrno(),
    };

    const bytes = std.mem.asBytes(&rec);
    var off: usize = 0;

    while (off < bytes.len) {
        const r = c.write(err_fd, bytes.ptr + off, bytes.len - off);
        if (r < 0) {
            if (getErrno() == c.EINTR) continue;
            break; // can't report; fall through to exit
        }
        off += @as(usize, @intCast(r));
    }

    // Never return into parent code
    posix.exit(code);
}

fn reapNoIntr(pid: posix.pid_t) void {
    var st: c_int = 0;
    while (true) {
        const r = c.waitpid(@intCast(pid), &st, 0);
        if (r == @as(c.pid_t, @intCast(pid))) return;
        if (r == -1 and getErrno() == c.EINTR) continue;
        return; // ECHILD or other hard error; nothing more to do safely
    }
}

fn watchGuiChild(pid: posix.pid_t) void {
    var status: c_int = 0;

    while (true) {
        const r = c.waitpid(@as(c.pid_t, @intCast(pid)), &status, 0);
        if (r == -1) {
            const e = getErrno();
            if (e == c.EINTR) continue;
            if (e != c.ECHILD) {
                logger.err("waitpid(ngui): errno {}", .{e});
            }
            return;
        }

        if (c.WIFEXITED(status)) {
            logger.warn("ngui exited with code {}", .{c.WEXITSTATUS(status)});
        } else if (c.WIFSIGNALED(status)) {
            logger.warn("ngui terminated by signal {}", .{c.WTERMSIG(status)});
        } else {
            logger.warn("ngui exited", .{});
        }

        sigquit.set();
        return;
    }
}

const SpawnedChild = struct {
    pid: posix.pid_t,
    stdin: std.fs.File, // parent writes -> child's stdin
    stdout: std.fs.File, // parent reads  <- child's stdout

    fn deinit(self: *@This()) void {
        self.stdin.close();
        self.stdout.close();
    }

    fn termThenKill(self: *const @This()) void {
        const pid: c.pid_t = @intCast(self.pid);

        // SIGTERM first (ignore ESRCH)
        _ = c.kill(pid, c.SIGTERM);

        var status: c_int = 0;

        // Poll up to ~2 seconds
        var ticks: usize = 0;
        while (ticks < 20) {
            const r = c.waitpid(pid, &status, c.WNOHANG);
            if (r == pid) return; // exited and reaped
            if (r == 0) {
                // still running
                std.time.sleep(100 * std.time.ns_per_ms);
                ticks += 1;
                continue;
            }

            // r == -1
            const e = getErrno();
            if (e == c.EINTR) {
                // interrupted by signal: retry without consuming a tick
                continue;
            }
            if (e == c.ECHILD) {
                // already reaped elsewhere / not our child anymore
                return;
            }

            // Other hard failure (e.g. EINVAL): avoid hanging; give up
            return;
        }

        // Still running: SIGKILL (ignore ESRCH)
        _ = c.kill(pid, c.SIGKILL);

        // Reap it. Handle EINTR as well.
        while (true) {
            const r2 = c.waitpid(pid, &status, 0);
            if (r2 == pid) return;
            if (r2 == -1 and getErrno() == c.EINTR) continue;
            return;
        }
    }
};

/// Spawn a process as `username` with correct supplementary groups (initgroups).
/// stdin/stdout are piped; stderr is inherited.
fn spawnAsUser(argv: []const []const u8, username: []const u8) !SpawnedChild {
    if (argv.len == 0) return error.EmptyArgv;

    // ---- pipes ----
    var stdin_pipe = try posix.pipe();
    errdefer {
        closeIfOpen(&stdin_pipe[0]);
        closeIfOpen(&stdin_pipe[1]);
    }
    try setCloexec(stdin_pipe[0]);
    try setCloexec(stdin_pipe[1]);

    var stdout_pipe = try posix.pipe();
    errdefer {
        closeIfOpen(&stdout_pipe[0]);
        closeIfOpen(&stdout_pipe[1]);
    }
    try setCloexec(stdout_pipe[0]);
    try setCloexec(stdout_pipe[1]);

    // error-reporting pipe: child writes failures; CLOEXEC closes on successful exec
    var err_pipe = try posix.pipe();
    errdefer {
        closeIfOpen(&err_pipe[0]);
        closeIfOpen(&err_pipe[1]);
    }
    try setCloexec(err_pipe[1]);

    // ---- prebuild C strings in parent BEFORE fork (fork-safe) ----
    const username_z: [:0]u8 = try std.heap.c_allocator.dupeZ(u8, username);
    errdefer std.heap.c_allocator.free(username_z);

    // Build argv buffers in the parent before fork.
    // Cleanup must only free successfully initialized entries.
    const argv_bufs: [][:0]u8 = try std.heap.c_allocator.alloc([:0]u8, argv.len);
    var argv_bufs_init: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < argv_bufs_init) : (i += 1) {
            std.heap.c_allocator.free(argv_bufs[i]);
        }
        std.heap.c_allocator.free(argv_bufs);
    }

    const argv_ptrs: []?[*:0]u8 = try std.heap.c_allocator.alloc(?[*:0]u8, argv.len + 1);
    errdefer std.heap.c_allocator.free(argv_ptrs);

    for (argv, 0..) |a, i| {
        argv_bufs[i] = try std.heap.c_allocator.dupeZ(u8, a);
        argv_bufs_init += 1;
        argv_ptrs[i] = @as([*:0]u8, @ptrCast(argv_bufs[i].ptr));
    }
    argv_ptrs[argv.len] = null;

    // ---- fork ----
    const pid = try posix.fork();
    if (pid == 0) {
        // ---------- child ----------
        // Never return from this block.
        _ = c.close(err_pipe[0]); // child writes only

        // Close parent ends of stdio pipes
        _ = c.close(stdin_pipe[1]);
        _ = c.close(stdout_pipe[0]);

        if (c.dup2(stdin_pipe[0], c.STDIN_FILENO) < 0) childReportAndExit(err_pipe[1], .Dup2Stdin, 127);
        if (c.dup2(stdout_pipe[1], c.STDOUT_FILENO) < 0) childReportAndExit(err_pipe[1], .Dup2Stdout, 127);

        // Only close original fds if they are not the stdio fd (pipe() might have returned 0/1)
        if (stdin_pipe[0] != c.STDIN_FILENO) _ = c.close(stdin_pipe[0]);
        if (stdout_pipe[1] != c.STDOUT_FILENO) _ = c.close(stdout_pipe[1]);

        const username_c: [*c]const u8 = @ptrCast(username_z.ptr);
        const pw = c.getpwnam(username_c) orelse childReportAndExit(err_pipe[1], .Getpwnam, 126);

        if (c.initgroups(username_c, pw.*.pw_gid) != 0) childReportAndExit(err_pipe[1], .Initgroups, 126);
        if (c.setgid(pw.*.pw_gid) != 0) childReportAndExit(err_pipe[1], .Setgid, 126);
        if (c.setuid(pw.*.pw_uid) != 0) childReportAndExit(err_pipe[1], .Setuid, 126);

        const argv_exec = @as([*c]const [*c]u8, @ptrCast(argv_ptrs.ptr));
        _ = c.execvp(argv_ptrs[0].?, argv_exec);

        childReportAndExit(err_pipe[1], .Execvp, 127);
    }

    // ---------- parent ----------
    // Parent does not need prebuilt strings anymore; child has its own COW copy.
    std.heap.c_allocator.free(username_z);
    for (argv_bufs) |s| std.heap.c_allocator.free(s);
    std.heap.c_allocator.free(argv_bufs);
    std.heap.c_allocator.free(argv_ptrs);

    closeIfOpen(&err_pipe[1]); // parent reads only
    closeIfOpen(&stdin_pipe[0]);
    closeIfOpen(&stdout_pipe[1]);

    // Read exactly one ChildFail record, or EOF for "success".
    var rec: ChildFail = undefined;
    const rec_bytes = std.mem.asBytes(&rec);
    var have: usize = 0;

    const n: isize = blk: while (true) {
        while (have < rec_bytes.len) {
            const r = c.read(err_pipe[0], rec_bytes.ptr + have, rec_bytes.len - have);
            if (r < 0) {
                if (getErrno() == c.EINTR) continue;
                break :blk -1;
            }
            if (r == 0) {
                if (have == 0) break :blk 0; // EOF immediately => exec success (tentative)
                break :blk @as(isize, @intCast(have)); // partial => protocol error
            }
            have += @as(usize, @intCast(r));
        }
        break :blk @as(isize, @intCast(have));
    };

    closeIfOpen(&err_pipe[0]);

    if (n < 0) {
        closeIfOpen(&stdin_pipe[1]);
        closeIfOpen(&stdout_pipe[0]);
        _ = c.kill(@as(c.pid_t, @intCast(pid)), c.SIGKILL);
        reapNoIntr(pid);
        return error.ChildErrPipeReadFailed;
    }

    if (n == 0) {
        // EOF on error pipe: verify child is still alive (avoid misclassifying early death).
        var st: c_int = 0;
        const cpid: c.pid_t = @as(c.pid_t, @intCast(pid));
        const wr: c.pid_t = while (true) {
            const r = c.waitpid(cpid, &st, c.WNOHANG);
            if (r == -1 and getErrno() == c.EINTR) continue;
            break r;
        };

        if (wr == cpid) {
            // already exited
            closeIfOpen(&stdin_pipe[1]);
            closeIfOpen(&stdout_pipe[0]);
            return error.ChildExitedDuringSpawn;
        } else if (wr == -1) {
            closeIfOpen(&stdin_pipe[1]);
            closeIfOpen(&stdout_pipe[0]);
            return error.ChildSpawnVerifyFailed;
        }

        // still running: transfer ownership to caller (and neutralize errdefer)
        const in_fd = stdin_pipe[1];
        const out_fd = stdout_pipe[0];
        stdin_pipe[1] = -1;
        stdout_pipe[0] = -1;

        return .{
            .pid = pid,
            .stdin = std.fs.File{ .handle = in_fd },
            .stdout = std.fs.File{ .handle = out_fd },
        };
    }

    if (@as(usize, @intCast(n)) != @sizeOf(ChildFail)) {
        closeIfOpen(&stdin_pipe[1]);
        closeIfOpen(&stdout_pipe[0]);
        _ = c.kill(@as(c.pid_t, @intCast(pid)), c.SIGKILL);
        reapNoIntr(pid);
        return error.ChildErrPipeProtocolError;
    }

    // child reported failure
    closeIfOpen(&stdin_pipe[1]);
    closeIfOpen(&stdout_pipe[0]);
    _ = c.kill(@as(c.pid_t, @intCast(pid)), c.SIGKILL);
    reapNoIntr(pid);

    return switch (rec.stage) {
        .Dup2Stdin, .Dup2Stdout, .Dup2Close => error.ChildDup2Failed,
        .UsernameZ => error.ChildUsernameAllocFailed,
        .Getpwnam => error.ChildGetpwnamFailed,
        .Initgroups => error.ChildInitgroupsFailed,
        .Setgid => error.ChildSetgidFailed,
        .Setuid => error.ChildSetuidFailed,
        .ArgvAlloc => error.ChildArgvAllocFailed,
        .ArgvDupeZ => error.ChildArgvDupeFailed,
        .Execvp => error.ChildExecFailed,
        .ErrWrite => error.ChildErrPipeWriteFailed,
    };
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

    // load config file to figure out whether to start ngui in screenlocked mode.
    const conf = try Config.init(gpa, args.conf.?);
    defer conf.deinit();

    // start ngui, unless -nogui mode
    const gui_path = args.gui.?; // guaranteed to be non-null
    var ngui_args = std.ArrayList([]const u8).init(gpa);
    defer ngui_args.deinit();
    try ngui_args.append(gui_path);
    if (conf.data.slock != null) {
        try ngui_args.append("-slock");
    }
    var ngui = spawnAsUser(ngui_args.items, args.gui_user.?) catch |err| {
        logger.err(
            "unable to start ngui at path {s} for gui_user {s}: {any}",
            .{ gui_path, args.gui_user.?, err },
        );
        return err;
    };
    defer ngui.deinit();
    // if the daemon fails to start and its process exits, ngui may hang forever
    // preventing system services monitoring to detect a failure and restart nd.
    // so, make sure to kill the ngui child process on fatal failures.
    const ngui_watch_thread = std.Thread.spawn(.{}, watchGuiChild, .{ngui.pid}) catch |err| {
        logger.err("unable to start ngui watcher thread: {any}", .{err});
        safeTermThenKillGui(ngui);
        return err;
    };
    defer ngui_watch_thread.join();
    errdefer safeTermThenKillGui(ngui);

    // the i/o is closed as soon as ngui child process terminates.
    const uireader = ngui.stdout.reader();
    const uiwriter = ngui.stdin.writer();
    comm.initPipe(gpa, .{ .r = ngui.stdout, .w = ngui.stdin });

    // send UI a ping right away to make sure pipes are working, crash otherwise.
    comm.pipeWrite(.ping) catch |err| {
        logger.err("comm.write ping: {any}", .{err});
        return err;
    };

    var nd = try Daemon.init(.{
        .allocator = gpa,
        .conf = conf,
        .uir = uireader,
        .uiw = uiwriter,
        .wpa = args.wpa.?,
    });
    defer nd.deinit();
    try nd.start();

    // graceful shutdown; see sigaction(2)
    const sa = posix.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    try posix.sigaction(posix.SIG.INT, &sa, null);
    try posix.sigaction(posix.SIG.TERM, &sa, null);
    sigquit.wait();
    logger.info("sigquit: terminating ...", .{});

    // reached here due to sig TERM or INT.
    // tell deamon to terminate threads.
    nd.stop();
    // once ngui exits, it'll close uireader/writer i/o from child proc
    // which lets the daemon's wait() to return.
    safeTermThenKillGui(ngui);
    nd.wait();
}
