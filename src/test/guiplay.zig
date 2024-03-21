const std = @import("std");
const time = std.time;
const os = std.os;

const comm = @import("comm");
const types = @import("../types.zig");

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
    slock: bool = false, // gui screen lock

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
        } else if (std.mem.eql(u8, a, "-slock")) {
            flags.slock = true;
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

/// global vars for comm read/write threads
var state: struct {
    mu: std.Thread.Mutex = .{},
    nodename: types.BufTrimString(std.os.HOST_NAME_MAX) = .{},
    slock_pincode: ?[]const u8 = null, // disabled when null
    settings_sent: bool = false,

    fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        if (self.slock_pincode) |s| {
            gpa.free(s);
        }
    }
} = .{};

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
            .lightning_genseed => {
                time.sleep(2 * time.ns_per_s);
                comm.write(gpa, w, .{ .lightning_genseed_result = &.{
                    "ability", "dance", "scatter", "raw",     "fly",    "dentist",  "bar",     "nominee",
                    "exhaust", "wine",  "snap",    "super",   "cost",   "case",     "coconut", "ticket",
                    "spread",  "funny", "grain",   "chimney", "aspect", "business", "quiz",    "ginger",
                } }) catch |err| logger.err("{!}", .{err});
            },
            .lightning_init_wallet => |v| {
                logger.info("mnemonic: {s}", .{v.mnemonic});
                time.sleep(3 * time.ns_per_s);
            },
            .lightning_get_ctrlconn => {
                var conn: comm.Message.LightningCtrlConn = &.{
                    .{ .url = "lndconnect://adfkjhadwaepoijsadflkjtrpoijawokjafulkjsadfkjhgjfdskjszd.onion:10009?macaroon=Adasjsadkfljhfjhasdpiuhfiuhawfffoihgpoiadsfjharpoiuhfdsgpoihafdsgpoiheafoiuhasdfhisdufhiuhfewiuhfiuhrfl6prrx", .typ = .lnd_rpc, .perm = .admin },
                    .{ .url = "lndconnect://adfkjhadwaepoijsadflkjtrpoijawokjafulkjsadfkjhgjfdskjszd.onion:10010?macaroon=Adasjsadkfljhfjhasdpiuhfiuhawfffoihgpoiadsfjharpoiuhfdsgpoihafdsgpoiheafoiuhasdfhisdufhiuhfewiuhfiuhrfl6prrx", .typ = .lnd_http, .perm = .admin },
                };
                comm.write(gpa, w, .{ .lightning_ctrlconn = conn }) catch |err| logger.err("{!}", .{err});
            },
            .set_nodename => |s| {
                state.mu.lock();
                defer state.mu.unlock();
                state.nodename.set(s);
                state.settings_sent = false;
            },
            .unlock_screen => |pin| {
                logger.info("unlock pincode: {s}", .{pin});
                time.sleep(1 * time.ns_per_s);
                state.mu.lock();
                defer state.mu.unlock();
                if (state.slock_pincode == null or std.mem.eql(u8, pin, state.slock_pincode.?)) {
                    const res: comm.Message.ScreenUnlockResult = .{
                        .ok = true,
                        .err = null,
                    };
                    comm.write(gpa, w, .{ .screen_unlock_result = res }) catch |err| logger.err("{!}", .{err});
                } else {
                    comm.write(gpa, w, .{ .screen_unlock_result = .{
                        .ok = false,
                        .err = "incorrect pin code",
                    } }) catch |err| logger.err("{!}", .{err});
                }
            },
            .slock_set_pincode => |newpin| {
                logger.info("slock_set_pincode: {?s}", .{newpin});
                time.sleep(1 * time.ns_per_s);
                state.mu.lock();
                defer state.mu.unlock();
                if (state.slock_pincode) |s| {
                    gpa.free(s);
                }
                state.slock_pincode = if (newpin) |pin| gpa.dupe(u8, pin) catch unreachable else null;
                state.settings_sent = false;
            },
            else => {},
        }
    }

    logger.info("exiting comm thread loop", .{});
    sigquit.set();
}

fn commWriteThread(gpa: std.mem.Allocator, w: anytype) !void {
    var sectimer = try time.Timer.start();
    var block_count: u32 = 801365;
    var lnd_uninited_sent = false;

    while (true) {
        time.sleep(time.ns_per_s);
        if (sectimer.read() < 3 * time.ns_per_s) {
            continue;
        }
        sectimer.reset();

        state.mu.lock();
        defer state.mu.unlock();

        if (!state.settings_sent) {
            state.settings_sent = true;
            const sett: comm.Message.Settings = .{
                .slock_enabled = state.slock_pincode != null,
                .hostname = state.nodename.val(),
                .sysupdates = .{ .channel = .edge },
            };
            comm.write(gpa, w, .{ .settings = sett }) catch |err| {
                logger.err("{}", .{err});
                state.settings_sent = false;
            };
        }

        block_count += 1;
        const now = time.timestamp();

        const btcrep: comm.Message.OnchainReport = .{
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
            .balance = .{
                .source = .lnd,
                .total = 800000,
                .confirmed = 350000,
                .unconfirmed = 350000,
                .locked = 0,
                .reserved = 100000,
            },
        };
        comm.write(gpa, w, .{ .onchain_report = btcrep }) catch |err| logger.err("comm.write: {any}", .{err});

        if (!lnd_uninited_sent and block_count % 2 == 0) {
            comm.write(gpa, w, .{ .lightning_error = .{ .code = .uninitialized } }) catch |err| logger.err("{any}", .{err});
            lnd_uninited_sent = true;
        }

        if (block_count % 2 == 0) {
            const lndrep: comm.Message.LightningReport = .{
                .version = "0.16.4-beta commit=v0.16.4-beta",
                .pubkey = "142874abcdeadbeef8839bdfaf8439fac9b0327bf78acdee8928efbac982de822a",
                .alias = "testnode",
                .npeers = 15,
                .height = block_count,
                .hash = "00000000000000000002bf8029f6be4e40b4a3e0e161b6a1044ddaf9eb126504",
                .sync = .{ .chain = true, .graph = true },
                .uris = &.{}, // TODO
                .totalbalance = .{ .local = 10123567, .remote = 4239870, .unsettled = 0, .pending = 430221 },
                .totalfees = .{ .day = 13, .week = 132, .month = 1321 },
                .channels = &.{
                    .{
                        .id = null,
                        .state = .pending_open,
                        .private = false,
                        .point = "1b332afe982befbdcbadff33099743099eef00bcdbaef788320db328efeaa91b:0",
                        .closetxid = null,
                        .peer_pubkey = "def3829fbdeadbeef8839bdfaf8439fac9b0327bf78acdee8928efbac229aaabc2",
                        .peer_alias = "chan-peer-alias1",
                        .capacity = 900000,
                        .balance = .{ .local = 1123456, .remote = 0, .unsettled = 0, .limbo = 0 },
                        .totalsats = .{ .sent = 0, .received = 0 },
                        .fees = .{ .base = 0, .ppm = 0 },
                    },
                    .{
                        .id = null,
                        .state = .pending_close,
                        .private = false,
                        .point = "932baef3982befbdcbadff33099743099eef00bcdbaef788320db328e82afdd7:0",
                        .closetxid = "fe829832982befbdcbadff33099743099eef00bcdbaef788320db328eaffeb2b",
                        .peer_pubkey = "01feba38fe8adbeef8839bdfaf8439fac9b0327bf78acdee8928efbac2abfec831",
                        .peer_alias = "chan-peer-alias2",
                        .capacity = 800000,
                        .balance = .{ .local = 10000, .remote = 788000, .unsettled = 0, .limbo = 10000 },
                        .totalsats = .{ .sent = 0, .received = 0 },
                        .fees = .{ .base = 0, .ppm = 0 },
                    },
                    .{
                        .id = "848352385882718209",
                        .state = .active,
                        .private = false,
                        .point = "36277666abcbefbdcbadff33099743099eef00bcdbaef788320db328e828e00d:1",
                        .closetxid = null,
                        .peer_pubkey = "e7287abcfdeadbeef8839bdfaf8439fac9b0327bf78acdee8928efbac229acddbe",
                        .peer_alias = "chan-peer-alias3",
                        .capacity = 1000000,
                        .balance = .{ .local = 1000000 / 2, .remote = 1000000 / 2, .unsettled = 0, .limbo = 0 },
                        .totalsats = .{ .sent = 3287320, .received = 2187482 },
                        .fees = .{ .base = 1000, .ppm = 400 },
                    },
                    .{
                        .id = "134439885882718428",
                        .state = .inactive,
                        .private = false,
                        .point = "abafe483982befbdcbadff33099743099eef00bcdbaef788320db328e828339c:0",
                        .closetxid = null,
                        .peer_pubkey = "20398287fdeadbeef8839bdfaf8439fac9b0327bf78acdee8928efbac229a03928",
                        .peer_alias = "chan-peer-alias4",
                        .capacity = 900000,
                        .balance = .{ .local = 900000, .remote = 0, .unsettled = 0, .limbo = 0 },
                        .totalsats = .{ .sent = 328732, .received = 2187482 },
                        .fees = .{ .base = 1000, .ppm = 500 },
                    },
                },
            };
            comm.write(gpa, w, .{ .lightning_report = lndrep }) catch |err| logger.err("comm.write: {any}", .{err});
        }
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

    state.slock_pincode = if (flags.slock) try gpa.dupe(u8, "0000") else null;
    state.nodename.set("guiplayhost");
    defer state.deinit(gpa);

    var a = std.ArrayList([]const u8).init(gpa);
    defer a.deinit();
    try a.append(flags.ngui_path.?);
    if (flags.slock) {
        try a.append("-slock");
    }
    ngui_proc = std.ChildProcess.init(a.items, gpa);
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
