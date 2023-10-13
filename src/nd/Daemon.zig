//! daemon watches network status and communicates updates to the GUI using uiwriter.
//! usage example:
//!
//!     var nd = Daemon.init(gpa, ngui_io_reader, ngui_io_writer, "/run/wpa_suppl/wlan0");
//!     defer nd.deinit();
//!     try nd.start();
//!     // wait for sigterm...
//!     nd.stop();
//!     // terminate ngui proc...
//!     nd.wait();
//!

const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const time = std.time;

const bitcoindrpc = @import("../bitcoindrpc.zig");
const comm = @import("../comm.zig");
const Config = @import("Config.zig");
const lndhttp = @import("../lndhttp.zig");
const network = @import("network.zig");
const screen = @import("../ui/screen.zig");
const SysService = @import("SysService.zig");
const types = @import("../types.zig");

const logger = std.log.scoped(.daemon);

allocator: mem.Allocator,
conf: Config,
uireader: std.fs.File.Reader, // ngui stdout
uiwriter: std.fs.File.Writer, // ngui stdin
wpa_ctrl: types.WpaControl, // guarded by mu once start'ed

/// guards all the fields below to sync between pub fns and main/poweroff threads.
mu: std.Thread.Mutex = .{},

/// daemon state
state: enum {
    stopped,
    running,
    standby,
    poweroff,
    wallet_reset,
},

main_thread: ?std.Thread = null,
comm_thread: ?std.Thread = null,
poweroff_thread: ?std.Thread = null,

want_stop: bool = false, // tells daemon main loop to quit
// send all settings to ngui
want_settings: bool = false,
// network flags
want_network_report: bool, // start gathering network status and send out as soon as ready
want_wifi_scan: bool, // initiate wifi scan at the next loop cycle
network_report_ready: bool, // indicates whether the network status is ready to be sent
wifi_scan_in_progress: bool = false,
wpa_save_config_on_connected: bool = false,
// bitcoin fields
want_onchain_report: bool,
bitcoin_timer: time.Timer,
onchain_report_interval: u64 = 1 * time.ns_per_min,
// lightning fields
want_lnd_report: bool,
lnd_timer: time.Timer,
lnd_report_interval: u64 = 1 * time.ns_per_min,
lnd_tls_reset_count: usize = 0,

/// system services actively managed by the daemon.
/// these are stop'ed during poweroff and their shutdown progress sent to ngui.
/// initialized in start and never modified again: ok to access without holding self.mu.
services: struct {
    list: []SysService,

    fn stopWait(self: @This(), name: []const u8) !void {
        for (self.list) |*sv| {
            if (std.mem.eql(u8, sv.name, name)) {
                return sv.stopWait();
            }
        }
        return error.NoSuchServiceToStop;
    }

    fn start(self: @This(), name: []const u8) !void {
        for (self.list) |*sv| {
            if (std.mem.eql(u8, sv.name, name)) {
                return sv.start();
            }
        }
        return error.NoSuchServiceToStart;
    }

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        for (self.list) |*sv| {
            sv.deinit();
        }
        allocator.free(self.list);
    }
} = .{ .list = &.{} },

const Daemon = @This();

const Error = error{
    InvalidState,
    WalletResetActive,
    PoweroffActive,
    AlreadyStarted,
    ConnectWifiEmptySSID,
    MakeWalletUnlockFileFail,
    LndServiceStopFail,
    ResetLndFail,
    GenLndConfigFail,
    InitLndWallet,
    UnlockLndWallet,
};

const InitOpt = struct {
    allocator: std.mem.Allocator,
    confpath: []const u8,
    uir: std.fs.File.Reader,
    uiw: std.fs.File.Writer,
    wpa: [:0]const u8,
};

/// initializes a daemon instance using the provided GUI stdout reader and stdin writer,
/// and a filesystem path to WPA control socket.
/// callers must deinit when done.
pub fn init(opt: InitOpt) !Daemon {
    var svlist = std.ArrayList(SysService).init(opt.allocator);
    errdefer {
        for (svlist.items) |*sv| sv.deinit();
        svlist.deinit();
    }
    // the order is important. when powering off, the services are shut down
    // in the same order appended here.
    try svlist.append(SysService.init(opt.allocator, SysService.LND, .{ .stop_wait_sec = 600 }));
    try svlist.append(SysService.init(opt.allocator, SysService.BITCOIND, .{ .stop_wait_sec = 600 }));

    const conf = try Config.init(opt.allocator, opt.confpath);
    errdefer conf.deinit();
    return .{
        .allocator = opt.allocator,
        .conf = conf,
        .uireader = opt.uir,
        .uiwriter = opt.uiw,
        .wpa_ctrl = try types.WpaControl.open(opt.wpa),
        .state = .stopped,
        .services = .{ .list = try svlist.toOwnedSlice() },
        // send persisted settings immediately on start
        .want_settings = true,
        // send a network report right at start without wifi scan to make it faster.
        .want_network_report = true,
        .want_wifi_scan = false,
        .network_report_ready = true,
        // report bitcoind status immediately on start
        .want_onchain_report = true,
        .bitcoin_timer = try time.Timer.start(),
        // report lightning status immediately on start
        .want_lnd_report = true,
        .lnd_timer = try time.Timer.start(),
    };
}

/// releases all associated resources.
/// the daemon must be stop'ed and wait'ed before deiniting.
pub fn deinit(self: *Daemon) void {
    self.wpa_ctrl.close() catch |err| logger.err("deinit: wpa_ctrl.close: {any}", .{err});
    self.services.deinit(self.allocator);
    self.conf.deinit();
}

/// start launches daemon threads and returns immediately.
/// once started, the daemon must be eventually stop'ed and wait'ed to clean up
/// resources even if a poweroff sequence is initiated with beginPoweroff.
pub fn start(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .stopped => {}, // continue
        .poweroff => return Error.PoweroffActive,
        else => return Error.AlreadyStarted,
    }

    try self.wpa_ctrl.attach();
    errdefer {
        self.wpa_ctrl.detach() catch {};
        self.want_stop = true;
    }

    self.main_thread = try std.Thread.spawn(.{}, mainThreadLoop, .{self});
    self.comm_thread = try std.Thread.spawn(.{}, commThreadLoop, .{self});
    self.state = .running;
}

/// tells the daemon to stop threads to prepare for termination.
/// stop returns immediately.
/// callers must `wait` to release all resources.
pub fn stop(self: *Daemon) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.want_stop = true;
}

/// blocks and waits for all threads to terminate. the daemon instance cannot
/// be start'ed afterwards.
///
/// note that in order for wait to return, the GUI I/O reader provided at init
/// must be closed.
pub fn wait(self: *Daemon) void {
    if (self.main_thread) |th| {
        th.join();
        self.main_thread = null;
    }
    if (self.comm_thread) |th| {
        th.join();
        self.comm_thread = null;
    }
    // must be the last one to join because it sends a final poweroff report.
    if (self.poweroff_thread) |th| {
        th.join();
        self.poweroff_thread = null;
    }

    self.wpa_ctrl.detach() catch |err| logger.err("wait: wpa_ctrl.detach: {any}", .{err});
    self.want_stop = false;
    self.state = .stopped;
}

/// tells the daemon to go into a standby mode, typically due to user inactivity.
fn standby(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .standby => {},
        .stopped, .poweroff => return Error.InvalidState,
        .wallet_reset => return Error.WalletResetActive,
        .running => {
            try screen.backlight(.off);
            self.state = .standby;
        },
    }
}

/// tells the daemon to return from standby, typically due to user interaction.
fn wakeup(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .running, .wallet_reset => {},
        .stopped, .poweroff => return Error.InvalidState,
        .standby => {
            try screen.backlight(.on);
            self.state = .running;
        },
    }
}

/// initiates system poweroff sequence in a separate thread: shut down select
/// system services such as lnd and bitcoind, and issue "poweroff" command.
///
/// beingPoweroff also makes other threads exit but callers must still call `wait`
/// to make sure poweroff sequence is complete.
fn beginPoweroff(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .poweroff => {}, // already in poweroff mode
        .stopped => return Error.InvalidState,
        .wallet_reset => return Error.WalletResetActive,
        .running, .standby => {
            self.poweroff_thread = try std.Thread.spawn(.{}, poweroffThread, .{self});
            self.state = .poweroff;
            self.want_stop = true;
        },
    }
}

/// set when poweroff_thread starts. available in tests only.
var test_poweroff_started = if (builtin.is_test) std.Thread.ResetEvent{} else {};

/// the poweroff thread entry point: stops all monitored services and issues poweroff
/// command while reporting the progress to ngui.
/// exits after issuing "poweroff" command.
fn poweroffThread(self: *Daemon) void {
    if (builtin.is_test) {
        test_poweroff_started.set();
    }
    logger.info("begin powering off", .{});
    screen.backlight(.on) catch |err| {
        logger.err("screen.backlight(.on) during poweroff: {any}", .{err});
    };

    // initiate shutdown of all services concurrently.
    for (self.services.list) |*sv| {
        sv.stop() catch |err| logger.err("sv stop '{s}': {any}", .{ sv.name, err });
    }
    self.sendPoweroffReport() catch |err| logger.err("sendPoweroffReport: {any}", .{err});

    // wait each service until stopped or error.
    for (self.services.list) |*sv| {
        _ = sv.stopWait() catch {};
        logger.info("{s} sv is now stopped; err={any}", .{ sv.name, sv.lastStopError() });
        self.sendPoweroffReport() catch |err| logger.err("sendPoweroffReport: {any}", .{err});
    }

    // finally, initiate system shutdown and power it off.
    var off = types.ChildProcess.init(&.{"poweroff"}, self.allocator);
    const res = off.spawnAndWait();
    logger.info("poweroff: {any}", .{res});
}

/// main thread entry point: watches for want_xxx flags and monitors network.
/// exits when want_stop is true.
fn mainThreadLoop(self: *Daemon) void {
    var quit = false;
    while (!quit) {
        self.mainThreadLoopCycle() catch |err| logger.err("main thread loop: {any}", .{err});
        std.atomic.spinLoopHint();
        time.sleep(1 * time.ns_per_s);

        self.mu.lock();
        quit = self.want_stop;
        self.mu.unlock();
    }
    logger.info("exiting main thread loop", .{});
}

/// runs one cycle of the main thread loop iteration.
/// the cycle holds self.mu for the whole duration.
fn mainThreadLoopCycle(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();

    if (self.want_settings) {
        const ok = self.conf.safeReadOnly(struct {
            fn f(conf: Config.Data) bool {
                const msg: comm.Message.Settings = .{
                    .sysupdates = .{
                        .channel = switch (conf.syschannel) {
                            .dev => .edge,
                            .master => .stable,
                        },
                    },
                };
                comm.pipeWrite(.{ .settings = msg }) catch |err| {
                    logger.err("{}", .{err});
                    return false;
                };
                return true;
            }
        }.f);
        self.want_settings = !ok;
    }

    // network stats
    self.readWPACtrlMsg() catch |err| logger.err("readWPACtrlMsg: {any}", .{err});
    if (self.want_wifi_scan) {
        if (self.startWifiScan()) {
            self.want_wifi_scan = false;
        } else |err| {
            logger.err("startWifiScan: {any}", .{err});
        }
    }
    if (self.want_network_report and self.network_report_ready) {
        if (network.sendReport(self.allocator, &self.wpa_ctrl, self.uiwriter)) {
            self.want_network_report = false;
        } else |err| {
            logger.err("network.sendReport: {any}", .{err});
        }
    }

    // onchain bitcoin stats
    if (self.want_onchain_report or self.bitcoin_timer.read() > self.onchain_report_interval) {
        if (self.sendOnchainReport()) {
            self.bitcoin_timer.reset();
            self.want_onchain_report = false;
        } else |err| {
            logger.err("sendOnchainReport: {any}", .{err});
        }
    }

    // lightning stats
    if (self.state != .wallet_reset) {
        if (self.want_lnd_report or self.lnd_timer.read() > self.lnd_report_interval) {
            if (self.sendLightningReport()) {
                self.lnd_timer.reset();
                self.want_lnd_report = false;
            } else |err| {
                logger.info("sendLightningReport: {!}", .{err});
                self.processLndReportError(err) catch |err2| logger.err("processLndReportError: {!}", .{err2});
            }
        }
    }
}

/// comm thread entry point: reads messages sent from ngui and acts accordinly.
/// exits when want_stop is true or comm reader is closed.
/// note: the thread might not exit immediately on want_stop because comm.read
/// is blocking.
fn commThreadLoop(self: *Daemon) void {
    var quit = false;
    loop: while (!quit) {
        std.atomic.spinLoopHint();
        time.sleep(100 * time.ns_per_ms);

        const res = comm.read(self.allocator, self.uireader) catch |err| {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.want_stop) {
                break :loop; // pipe is most likely already closed
            }
            switch (self.state) {
                .stopped, .poweroff => break :loop,
                .running, .standby, .wallet_reset => {
                    logger.err("commThreadLoop: {any}", .{err});
                    if (err == error.EndOfStream) {
                        // pointless to continue running if comms I/O is broken.
                        self.want_stop = true;
                        break :loop;
                    }
                    continue;
                },
            }
        };
        defer res.deinit();

        logger.debug("got msg: {s}", .{@tagName(res.value)});
        switch (res.value) {
            .pong => {
                logger.info("received pong from ngui", .{});
            },
            .poweroff => {
                self.beginPoweroff() catch |err| logger.err("beginPoweroff: {any}", .{err});
            },
            .get_network_report => |req| {
                self.reportNetworkStatus(.{ .scan = req.scan });
            },
            .wifi_connect => |req| {
                self.startConnectWifi(req.ssid, req.password) catch |err| {
                    logger.err("startConnectWifi: {any}", .{err});
                };
            },
            .standby => {
                logger.info("entering standby mode", .{});
                self.standby() catch |err| logger.err("nd.standby: {any}", .{err});
            },
            .wakeup => {
                logger.info("wakeup from standby", .{});
                self.wakeup() catch |err| logger.err("nd.wakeup: {any}", .{err});
            },
            .switch_sysupdates => |chan| {
                logger.info("switching sysupdates channel to {s}", .{@tagName(chan)});
                self.switchSysupdates(chan) catch |err| {
                    logger.err("switchSysupdates: {any}", .{err});
                    // TODO: send err back to ngui
                };
            },
            .lightning_genseed => {
                self.generateWalletSeed() catch |err| {
                    logger.err("generateWalletSeed: {!}", .{err});
                    // TODO: send err back to ngui
                };
            },
            .lightning_init_wallet => |req| {
                self.initWallet(req) catch |err| {
                    logger.err("initWallet: {!}", .{err});
                    // TODO: send err back to ngui
                };
            },
            .lightning_get_ctrlconn => {
                self.sendLightningPairingConn() catch |err| {
                    logger.err("sendLightningPairingConn: {!}", .{err});
                    // TODO: send err back to ngui
                };
            },
            .lightning_reset => {
                self.resetLndNode() catch |err| logger.err("resetLndNode: {!}", .{err});
            },
            else => |v| logger.warn("unhandled msg tag {s}", .{@tagName(v)}),
        }

        self.mu.lock();
        quit = self.want_stop;
        self.mu.unlock();
    }

    logger.info("exiting comm thread loop", .{});
}

/// sends poweroff progress to uiwriter in comm.Message.PoweroffProgress format.
fn sendPoweroffReport(self: *Daemon) !void {
    var svstat = try self.allocator.alloc(comm.Message.PoweroffProgress.Service, self.services.list.len);
    defer self.allocator.free(svstat);
    for (self.services.list, svstat) |*sv, *stat| {
        stat.* = .{
            .name = sv.name,
            .stopped = sv.status() == .stopped,
            .err = if (sv.lastStopError()) |err| @errorName(err) else null,
        };
    }
    const report = comm.Message{ .poweroff_progress = .{ .services = svstat } };
    try comm.write(self.allocator, self.uiwriter, report);
}

/// caller must hold self.mu.
fn startWifiScan(self: *Daemon) !void {
    try self.wpa_ctrl.scan();
    self.wifi_scan_in_progress = true;
    self.network_report_ready = false;
}

/// invoked when CTRL-EVENT-SCAN-RESULTS event is seen.
/// caller must hold self.mu.
fn wifiScanComplete(self: *Daemon) void {
    self.wifi_scan_in_progress = false;
    self.network_report_ready = true;
}

/// invoked when CTRL-EVENT-CONNECTED event is seen.
/// caller must hold self.mu.
fn wifiConnected(self: *Daemon) void {
    if (self.wpa_save_config_on_connected) {
        // fails if update_config=0 in wpa_supplicant.conf
        const ok_saved = self.wpa_ctrl.saveConfig();
        if (ok_saved) {
            self.wpa_save_config_on_connected = false;
        } else |err| {
            logger.err("wifiConnected: {any}", .{err});
        }
    }
    // always send a network report when connected
    self.want_network_report = true;
}

/// invoked when CTRL-EVENT-SSID-TEMP-DISABLED event with authentication failures is seen.
/// callers must hold self.mu.
fn wifiInvalidKey(self: *Daemon) void {
    self.wpa_save_config_on_connected = false;
    self.want_network_report = true;
    self.network_report_ready = true;
}

const ReportNetworkStatusOpt = struct {
    scan: bool,
};

/// tells the daemon to start preparing network status report, including a wifi
/// scan as an option.
fn reportNetworkStatus(self: *Daemon, opt: ReportNetworkStatusOpt) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.want_network_report = true;
    self.want_wifi_scan = opt.scan and !self.wifi_scan_in_progress;
    if (self.want_wifi_scan and self.network_report_ready) {
        self.network_report_ready = false;
    }
}

/// initiates wifi connection procedure in a separate thread
fn startConnectWifi(self: *Daemon, ssid: []const u8, password: []const u8) !void {
    if (ssid.len == 0) {
        return Error.ConnectWifiEmptySSID;
    }
    const ssid_copy = try self.allocator.dupe(u8, ssid);
    const pwd_copy = try self.allocator.dupe(u8, password);
    const th = try std.Thread.spawn(.{}, connectWifiThread, .{ self, ssid_copy, pwd_copy });
    th.detach();
}

/// the wifi connection procedure thread entry point.
/// holds self.mu for the whole duration. however the thread lifetime is expected
/// to be short since all it does is issuing commands to self.wpa_ctrl.
///
/// the thread owns ssid and password args, and frees them at exit.
fn connectWifiThread(self: *Daemon, ssid: []const u8, password: []const u8) void {
    self.mu.lock();
    defer {
        self.mu.unlock();
        self.allocator.free(ssid);
        self.allocator.free(password);
    }

    // https://hostap.epitest.fi/wpa_supplicant/devel/ctrl_iface_page.html
    // https://wiki.archlinux.org/title/WPA_supplicant

    const id = network.addWifi(self.allocator, &self.wpa_ctrl, ssid, password) catch |err| {
        logger.err("addWifi: {any}; exiting", .{err});
        return;
    };
    // SELECT_NETWORK <id> - this disables others
    // ENABLE_NETWORK <id>
    self.wpa_ctrl.selectNetwork(id) catch |err| {
        logger.err("selectNetwork({d}): {any}", .{ id, err });
        // non-critical; can try to continue
    };
    self.wpa_ctrl.enableNetwork(id) catch |err| {
        logger.err("enableNetwork({d}): {any}; cannot continue", .{ id, err });
        self.wpa_ctrl.removeNetwork(id) catch {};
        return;
    };

    // wait for CTRL-EVENT-CONNECTED, SAVE_CONFIG and send network report.
    self.wpa_save_config_on_connected = true;
}

/// reads all available messages from self.wpa_ctrl and acts accordingly.
/// callers must hold self.mu.
fn readWPACtrlMsg(self: *Daemon) !void {
    var buf: [512:0]u8 = undefined;
    while (try self.wpa_ctrl.pending()) {
        const m = try self.wpa_ctrl.receive(&buf);
        logger.debug("wpa_ctrl msg: {s}", .{m});
        if (mem.indexOf(u8, m, "CTRL-EVENT-SCAN-RESULTS") != null) {
            self.wifiScanComplete();
        }
        if (mem.indexOf(u8, m, "CTRL-EVENT-CONNECTED") != null) {
            self.wifiConnected();
        }
        if (mem.indexOf(u8, m, "CTRL-EVENT-SSID-TEMP-DISABLED") != null) {
            // TODO: what about CTRL-EVENT-DISCONNECTED bssid=xx:xx:xx:xx:xx:xx reason=15
            // CTRL-EVENT-SSID-TEMP-DISABLED id=1 ssid="<ssid>" auth_failures=3 duration=49 reason=WRONG_KEY
            var it = mem.tokenize(u8, m, " ");
            while (it.next()) |kv_str| {
                var kv = mem.split(u8, kv_str, "=");
                if (mem.eql(u8, kv.first(), "auth_failures")) {
                    const v = kv.next();
                    if (v != null and !mem.eql(u8, v.?, "0")) {
                        self.wifiInvalidKey();
                        break;
                    }
                }
            }
        }
        // TODO: CTRL-EVENT-DISCONNECTED
    }
}

/// callers must hold self.mu due to self.state read access via fetchOnchainStats.
fn sendOnchainReport(self: *Daemon) !void {
    const stats = self.fetchOnchainStats() catch |err| {
        switch (err) {
            error.FileNotFound, // cookie file might not exist yet
            error.RpcInWarmup,
            // bitcoind is still starting up: pretend the repost is sent.
            // TODO: report actual startup ptogress to the UI
            // https://git.qcode.ch/nakamochi/ndg/issues/30
            => return,
            // otherwise, propagate the error to the caller.
            else => return err,
        }
    };
    defer {
        stats.bcinfo.deinit();
        stats.netinfo.deinit();
        stats.mempool.deinit();
        if (stats.balance) |bal| bal.deinit();
    }

    const btcrep: comm.Message.OnchainReport = .{
        .blocks = stats.bcinfo.value.blocks,
        .headers = stats.bcinfo.value.headers,
        .timestamp = stats.bcinfo.value.time,
        .hash = stats.bcinfo.value.bestblockhash,
        .ibd = stats.bcinfo.value.initialblockdownload,
        .diskusage = stats.bcinfo.value.size_on_disk,
        .version = stats.netinfo.value.subversion,
        .conn_in = stats.netinfo.value.connections_in,
        .conn_out = stats.netinfo.value.connections_out,
        .warnings = stats.bcinfo.value.warnings, // TODO: netinfo.result.warnings
        .localaddr = &.{}, // TODO: populate
        // something similar to this:
        // @round(bcinfo.verificationprogress * 100)
        .verifyprogress = 0,
        .mempool = .{
            .loaded = stats.mempool.value.loaded,
            .txcount = stats.mempool.value.size,
            .usage = stats.mempool.value.usage,
            .max = stats.mempool.value.maxmempool,
            .totalfee = stats.mempool.value.total_fee,
            .minfee = stats.mempool.value.mempoolminfee,
            .fullrbf = stats.mempool.value.fullrbf,
        },
        .balance = if (stats.balance) |bal| .{
            .source = .lnd,
            .total = bal.value.total_balance,
            .confirmed = bal.value.confirmed_balance,
            .unconfirmed = bal.value.unconfirmed_balance,
            .locked = bal.value.locked_balance,
            .reserved = bal.value.reserved_balance_anchor_chan,
        } else null,
    };

    try comm.write(self.allocator, self.uiwriter, .{ .onchain_report = btcrep });
}

const OnchainStats = struct {
    bcinfo: bitcoindrpc.Client.Result(.getblockchaininfo),
    netinfo: bitcoindrpc.Client.Result(.getnetworkinfo),
    mempool: bitcoindrpc.Client.Result(.getmempoolinfo),
    // lnd wallet may be uninitialized
    balance: ?lndhttp.Client.Result(.walletbalance),
};

/// call site must hold self.mu due to self.state read access.
/// callers own returned value.
fn fetchOnchainStats(self: *Daemon) !OnchainStats {
    var client = bitcoindrpc.Client{
        .allocator = self.allocator,
        .cookiepath = "/ssd/bitcoind/mainnet/.cookie",
    };
    const bcinfo = try client.call(.getblockchaininfo, {});
    const netinfo = try client.call(.getnetworkinfo, {});
    const mempool = try client.call(.getmempoolinfo, {});

    const balance: ?lndhttp.Client.Result(.walletbalance) = blk: { // lndhttp.WalletBalance
        if (self.state == .wallet_reset) {
            break :blk null;
        }
        var lndc = lndhttp.Client.init(.{
            .allocator = self.allocator,
            .tlscert_path = Config.LND_TLSCERT_PATH,
            .macaroon_ro_path = Config.LND_MACAROON_RO_PATH,
            .macaroon_admin_path = Config.LND_MACAROON_ADMIN_PATH,
        }) catch break :blk null;
        defer lndc.deinit();
        const res = lndc.call(.walletbalance, {}) catch break :blk null;
        break :blk res;
    };
    return .{
        .bcinfo = bcinfo,
        .netinfo = netinfo,
        .mempool = mempool,
        .balance = balance,
    };
}

fn sendLightningReport(self: *Daemon) !void {
    var client = try lndhttp.Client.init(.{
        .allocator = self.allocator,
        .tlscert_path = Config.LND_TLSCERT_PATH,
        .macaroon_ro_path = Config.LND_MACAROON_RO_PATH,
        .macaroon_admin_path = Config.LND_MACAROON_ADMIN_PATH,
    });
    defer client.deinit();

    const info = try client.call(.getinfo, {});
    defer info.deinit();
    const feerep = try client.call(.feereport, {});
    defer feerep.deinit();
    const chanlist = try client.call(.listchannels, .{ .peer_alias_lookup = true });
    defer chanlist.deinit();
    const pending = try client.call(.pendingchannels, {});
    defer pending.deinit();

    var lndrep = comm.Message.LightningReport{
        .version = info.value.version,
        .pubkey = info.value.identity_pubkey,
        .alias = info.value.alias,
        .npeers = info.value.num_peers,
        .height = info.value.block_height,
        .hash = info.value.block_hash,
        .sync = .{
            .chain = info.value.synced_to_chain,
            .graph = info.value.synced_to_graph,
        },
        .uris = &.{}, // TODO: dedup info.uris
        .totalbalance = .{
            .local = 0, // available; computed below
            .remote = 0, // available; computed below
            .unsettled = 0, // computed below
            .pending = pending.value.total_limbo_balance,
        },
        .totalfees = .{
            .day = feerep.value.day_fee_sum,
            .week = feerep.value.week_fee_sum,
            .month = feerep.value.month_fee_sum,
        },
        .channels = undefined, // populated below
    };

    var feemap = std.StringHashMap(struct { base: i64, ppm: i64 }).init(self.allocator);
    defer feemap.deinit();
    for (feerep.value.channel_fees) |item| {
        try feemap.put(item.chan_id, .{ .base = item.base_fee_msat, .ppm = item.fee_per_mil });
    }

    var channels = std.ArrayList(@typeInfo(@TypeOf(lndrep.channels)).Pointer.child).init(self.allocator);
    defer channels.deinit();
    for (pending.value.pending_open_channels) |item| {
        try channels.append(.{
            .id = null,
            .state = .pending_open,
            .private = item.channel.private,
            .point = item.channel.channel_point,
            .closetxid = null,
            .peer_pubkey = item.channel.remote_node_pub,
            .peer_alias = "", // TODO: a cached getnodeinfo?
            .capacity = item.channel.capacity,
            .balance = .{
                .local = item.channel.local_balance,
                .remote = item.channel.remote_balance,
                .unsettled = 0,
                .limbo = 0,
            },
            .totalsats = .{ .sent = 0, .received = 0 },
            .fees = .{ .base = 0, .ppm = 0 },
        });
    }
    for (pending.value.waiting_close_channels) |item| {
        try channels.append(.{
            .id = null,
            .state = .pending_close,
            .private = item.channel.private,
            .point = item.channel.channel_point,
            .closetxid = item.closing_txid,
            .peer_pubkey = item.channel.remote_node_pub,
            .peer_alias = "", // TODO: a cached getnodeinfo?
            .capacity = item.channel.capacity,
            .balance = .{
                .local = item.channel.local_balance,
                .remote = item.channel.remote_balance,
                .unsettled = 0,
                .limbo = item.limbo_balance,
            },
            .totalsats = .{ .sent = 0, .received = 0 },
            .fees = .{ .base = 0, .ppm = 0 },
        });
    }
    for (pending.value.pending_force_closing_channels) |item| {
        try channels.append(.{
            .id = null,
            .state = .pending_close,
            .private = item.channel.private,
            .point = item.channel.channel_point,
            .closetxid = item.closing_txid,
            .peer_pubkey = item.channel.remote_node_pub,
            .peer_alias = "", // TODO: a cached getnodeinfo?
            .capacity = item.channel.capacity,
            .balance = .{
                .local = item.channel.local_balance,
                .remote = item.channel.remote_balance,
                .unsettled = 0,
                .limbo = item.limbo_balance,
            },
            .totalsats = .{ .sent = 0, .received = 0 },
            .fees = .{ .base = 0, .ppm = 0 },
        });
    }
    for (chanlist.value.channels) |ch| {
        lndrep.totalbalance.local += ch.local_balance;
        lndrep.totalbalance.remote += ch.remote_balance;
        lndrep.totalbalance.unsettled += ch.unsettled_balance;
        try channels.append(.{
            .id = ch.chan_id,
            .state = if (ch.active) .active else .inactive,
            .private = ch.private,
            .point = ch.channel_point,
            .closetxid = null,
            .peer_pubkey = ch.remote_pubkey,
            .peer_alias = ch.peer_alias,
            .capacity = ch.capacity,
            .balance = .{
                .local = ch.local_balance,
                .remote = ch.remote_balance,
                .unsettled = ch.unsettled_balance,
                .limbo = 0,
            },
            .totalsats = .{
                .sent = ch.total_satoshis_sent,
                .received = ch.total_satoshis_received,
            },
            .fees = if (feemap.get(ch.chan_id)) |v| .{ .base = v.base, .ppm = v.ppm } else .{ .base = 0, .ppm = 0 },
        });
    }

    lndrep.channels = channels.items;
    try comm.write(self.allocator, self.uiwriter, .{ .lightning_report = lndrep });
}

/// evaluates any error returned from `sendLightningReport`.
/// callers must hold self.mu.
fn processLndReportError(self: *Daemon, err: anyerror) !void {
    const msg_starting: comm.Message = .{ .lightning_error = .{ .code = .not_ready } };
    const msg_locked: comm.Message = .{ .lightning_error = .{ .code = .locked } };
    const msg_uninitialized: comm.Message = .{ .lightning_error = .{ .code = .uninitialized } };

    switch (err) {
        error.ConnectionRefused,
        error.FileNotFound, // tls cert file missing, not re-generated by lnd yet
        => return comm.write(self.allocator, self.uiwriter, msg_starting),
        // old tls cert, refused by our http client
        std.http.Client.ConnectUnproxiedError.TlsInitializationFailed => {
            try self.resetLndTlsUnguarded();
            return error.LndReportRetryLater;
        },
        else => {}, // continue
    }

    // checking wallet status requires no macaroon auth
    var client = try lndhttp.Client.init(.{ .allocator = self.allocator, .tlscert_path = Config.LND_TLSCERT_PATH });
    defer client.deinit();
    const status = client.call(.walletstatus, {}) catch |err2| {
        switch (err2) {
            error.TlsInitializationFailed => {
                try self.resetLndTlsUnguarded();
                return error.LndReportRetryLater;
            },
            else => return err2,
        }
    };
    defer status.deinit();
    logger.info("processLndReportError: lnd wallet state: {s}", .{@tagName(status.value.state)});
    return switch (status.value.state) {
        .NON_EXISTING => {
            try comm.write(self.allocator, self.uiwriter, msg_uninitialized);
            self.lnd_timer.reset();
            self.want_lnd_report = false;
        },
        .LOCKED => {
            try comm.write(self.allocator, self.uiwriter, msg_locked);
            self.lnd_timer.reset();
            self.want_lnd_report = false;
        },
        .UNLOCKED, .RPC_ACTIVE, .WAITING_TO_START => comm.write(self.allocator, self.uiwriter, msg_starting),
        // active server indicates the lnd is ready to accept calls. so, the error
        // must have been due to factors other than unoperational lnd state.
        .SERVER_ACTIVE => err,
    };
}

fn sendLightningPairingConn(self: *Daemon) !void {
    const tor_rpc = try self.conf.lndConnectWaitMacaroonFile(self.allocator, .tor_rpc);
    defer self.allocator.free(tor_rpc);
    const tor_http = try self.conf.lndConnectWaitMacaroonFile(self.allocator, .tor_http);
    defer self.allocator.free(tor_http);
    var conn: comm.Message.LightningCtrlConn = &.{
        .{ .url = tor_rpc, .typ = .lnd_rpc, .perm = .admin },
        .{ .url = tor_http, .typ = .lnd_http, .perm = .admin },
    };
    try comm.write(self.allocator, self.uiwriter, .{ .lightning_ctrlconn = conn });
}

/// a non-committal seed generator. can be called any number of times.
fn generateWalletSeed(self: *Daemon) !void {
    // genseed needs no auth
    var client = try lndhttp.Client.init(.{ .allocator = self.allocator, .tlscert_path = Config.LND_TLSCERT_PATH });
    defer client.deinit();
    const res = try client.call(.genseed, {});
    defer res.deinit();
    const msg = comm.Message{ .lightning_genseed_result = res.value.cipher_seed_mnemonic };
    return comm.write(self.allocator, self.uiwriter, msg);
}

/// commit req.mnemonic as the new lightning wallet.
/// this also creates a new unlock password, placing it at `Config.LND_WALLETUNLOCK_PATH`,
/// and finally generates a new lnd config file to persist the changes.
fn initWallet(self: *Daemon, req: comm.Message.LightningInitWallet) !void {
    self.mu.lock();
    switch (self.state) {
        .stopped, .poweroff, .wallet_reset => {
            defer self.mu.unlock();
            switch (self.state) {
                .poweroff => return Error.PoweroffActive,
                .wallet_reset => return Error.WalletResetActive,
                else => return Error.InvalidState,
            }
        },
        // proceed only when in one of the following states
        .standby => screen.backlight(.on) catch |err| logger.err("initWallet: backlight on: {!}", .{err}),
        .running => {},
    }
    defer {
        self.mu.lock();
        self.state = .running;
        self.mu.unlock();
    }
    self.state = .wallet_reset;
    self.mu.unlock();

    // generate a new wallet unlock password; used together with seed committal below.
    var buf: [128]u8 = undefined;
    const unlock_pwd = self.conf.makeWalletUnlockFile(&buf, 8) catch |err| {
        logger.err("makeWalletUnlockFile: {!}", .{err});
        return Error.MakeWalletUnlockFileFail;
    };

    // commit the seed: initwallet needs no auth
    logger.info("initwallet: committing new seed and an unlock password", .{});
    var client = try lndhttp.Client.init(.{ .allocator = self.allocator, .tlscert_path = Config.LND_TLSCERT_PATH });
    defer client.deinit();
    const res = client.call(.initwallet, .{ .unlock_password = unlock_pwd, .mnemonic = req.mnemonic }) catch |err| {
        logger.err("lnd client initwallet: {!}", .{err});
        return Error.InitLndWallet;
    };
    res.deinit(); // unused

    // generate a valid lnd config before unlocking the first time but without auto-unlock.
    // the latter works only after first unlock - see below.
    //
    // important details about a "valid" config is lnd needs correct bitcoind rpc auth,
    // which historically has been missing at the initial OS image build.
    logger.info("initwallet: generating lnd config file without auto-unlock", .{});
    try self.conf.genLndConfig(.{ .autounlock = false });

    // restart the lnd service to pick up the newly generated config above.
    logger.info("initwallet: restarting lnd", .{});
    try self.services.stopWait(SysService.LND);
    try self.services.start(SysService.LND);
    var timer = try types.Timer.start();
    while (timer.read() < 10 * time.ns_per_s) {
        const status = client.call(.walletstatus, {}) catch |err| {
            logger.info("initwallet: waiting lnd restart: {!}", .{err});
            std.time.sleep(1 * time.ns_per_s);
            continue;
        };
        defer status.deinit();
        switch (status.value.state) {
            .LOCKED => break,
            else => |t| {
                logger.info("initwallet: waiting lnd restart: {s}", .{@tagName(t)});
                std.time.sleep(1 * time.ns_per_s);
                continue;
            },
        }
    }

    // unlock the wallet for the first time: required after initwallet.
    // it generates macaroon files and completes a wallet initialization.
    logger.info("initwallet: unlocking new wallet for the first time", .{});
    const res2 = client.call(.unlockwallet, .{ .unlock_password = unlock_pwd }) catch |err| {
        logger.err("lnd client unlockwallet: {!}", .{err});
        return Error.UnlockLndWallet;
    };
    res2.deinit(); // unused

    // same as above genLndConfig but with auto-unlock enabled.
    // no need to restart lnd: it'll pick up the new config on next boot.
    logger.info("initwallet: re-generating lnd config with auto-unlock", .{});
    try self.conf.genLndConfig(.{ .autounlock = true });
}

/// factory-resets lnd node; wipes out the wallet.
fn resetLndNode(self: *Daemon) !void {
    self.mu.lock();
    switch (self.state) {
        .stopped, .poweroff, .wallet_reset => {
            defer self.mu.unlock();
            switch (self.state) {
                .poweroff => return Error.PoweroffActive,
                .wallet_reset => return Error.WalletResetActive,
                else => return Error.InvalidState,
            }
        },
        // proceed only when in one of the following states
        .running, .standby => {},
    }
    const prevstate = self.state;
    defer {
        self.mu.lock();
        self.state = prevstate;
        self.mu.unlock();
    }
    self.state = .wallet_reset;
    self.mu.unlock();

    // 1. stop lnd service
    try self.services.stopWait(SysService.LND);

    // 2. delete all data directories
    try std.fs.cwd().deleteTree(Config.LND_DATA_DIR);
    try std.fs.cwd().deleteTree(Config.LND_LOG_DIR);
    try std.fs.cwd().deleteFile(Config.LND_WALLETUNLOCK_PATH);
    if (std.fs.path.dirname(Config.LND_TLSCERT_PATH)) |dir| {
        try std.fs.cwd().deleteTree(dir);
    }
    // TODO: reset tor hidden service pubkey?

    // 3. generate a new blank config so lnd can start up again and respond
    // to status requests.
    try self.conf.genLndConfig(.{ .autounlock = false });

    // 4. start lnd service
    try self.services.start(SysService.LND);
}

/// like resetLndNode but resets only tls certs, nothing else.
/// callers must acquire self.mu.
fn resetLndTlsUnguarded(self: *Daemon) !void {
    if (self.lnd_tls_reset_count > 0) {
        return error.LndTlsResetCount;
    }
    switch (self.state) {
        .stopped, .poweroff, .wallet_reset => {
            defer self.mu.unlock();
            switch (self.state) {
                .poweroff => return Error.PoweroffActive,
                .wallet_reset => return Error.WalletResetActive,
                else => return Error.InvalidState,
            }
        },
        // proceed only when in one of the following states
        .running, .standby => {},
    }
    logger.info("resetting lnd tls certs", .{});
    try std.fs.cwd().deleteFile(Config.LND_TLSKEY_PATH);
    try std.fs.cwd().deleteFile(Config.LND_TLSCERT_PATH);
    try self.services.stopWait(SysService.LND);
    try self.services.start(SysService.LND);
    self.lnd_tls_reset_count += 1;
}

fn switchSysupdates(self: *Daemon, chan: comm.Message.SysupdatesChan) !void {
    const th = try std.Thread.spawn(.{}, switchSysupdatesThread, .{ self, chan });
    th.detach();
}

fn switchSysupdatesThread(self: *Daemon, chan: comm.Message.SysupdatesChan) void {
    const conf_chan: Config.SysupdatesChannel = switch (chan) {
        .stable => .master,
        .edge => .dev,
    };
    self.conf.switchSysupdates(conf_chan, .{ .run = true }) catch |err| {
        logger.err("config.switchSysupdates: {any}", .{err});
        // TODO: send err back to ngui
    };
    // schedule settings report for ngui
    self.mu.lock();
    defer self.mu.unlock();
    self.want_settings = true;
}

test "start-stop" {
    const t = std.testing;

    const pipe = try types.IoPipe.create();
    var daemon = try Daemon.init(.{
        .allocator = t.allocator,
        .confpath = "/unused.json",
        .uir = pipe.reader(),
        .uiw = pipe.writer(),
        .wpa = "/dev/null",
    });
    daemon.want_settings = false;
    daemon.want_network_report = false;
    daemon.want_onchain_report = false;
    daemon.want_lnd_report = false;

    try t.expect(daemon.state == .stopped);
    try daemon.start();
    try t.expect(daemon.state == .running);
    try t.expect(daemon.main_thread != null);
    try t.expect(daemon.comm_thread != null);
    try t.expect(daemon.poweroff_thread == null);
    try t.expect(daemon.wpa_ctrl.opened);
    try t.expect(daemon.wpa_ctrl.attached);

    daemon.stop();
    pipe.close();
    daemon.wait();
    try t.expect(daemon.state == .stopped);
    try t.expect(daemon.main_thread == null);
    try t.expect(daemon.comm_thread == null);
    try t.expect(daemon.poweroff_thread == null);
    try t.expect(!daemon.wpa_ctrl.attached);
    try t.expect(daemon.wpa_ctrl.opened);

    try t.expect(daemon.services.list.len > 0);
    for (daemon.services.list) |*sv| {
        try t.expect(!sv.stop_proc.spawned);
        try t.expectEqual(SysService.Status.initial, sv.status());
    }

    daemon.deinit();
    try t.expect(!daemon.wpa_ctrl.opened);
}

test "start-poweroff" {
    const t = std.testing;
    const tt = @import("../test.zig");

    var arena_alloc = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const gui_stdin = try types.IoPipe.create();
    const gui_stdout = try types.IoPipe.create();
    const gui_reader = gui_stdin.reader();
    var daemon = try Daemon.init(.{
        .allocator = arena,
        .confpath = "/unused.json",
        .uir = gui_stdout.reader(),
        .uiw = gui_stdin.writer(),
        .wpa = "/dev/null",
    });
    daemon.want_settings = false;
    daemon.want_network_report = false;
    daemon.want_onchain_report = false;
    daemon.want_lnd_report = false;
    defer {
        daemon.deinit();
        gui_stdin.close();
    }

    try daemon.start();
    try comm.write(arena, gui_stdout.writer(), comm.Message.poweroff);
    try test_poweroff_started.timedWait(2 * time.ns_per_s);
    try t.expect(daemon.state == .poweroff);

    gui_stdout.close();
    daemon.wait();
    try t.expect(daemon.state == .stopped);
    try t.expect(daemon.poweroff_thread == null);
    for (daemon.services.list) |*sv| {
        try t.expect(sv.stop_proc.spawned);
        try t.expect(sv.stop_proc.waited);
        try t.expectEqual(SysService.Status.stopped, sv.status());
    }

    const msg1 = try comm.read(arena, gui_reader);
    try tt.expectDeepEqual(comm.Message{ .poweroff_progress = .{ .services = &.{
        .{ .name = "lnd", .stopped = false, .err = null },
        .{ .name = "bitcoind", .stopped = false, .err = null },
    } } }, msg1.value);

    const msg2 = try comm.read(arena, gui_reader);
    try tt.expectDeepEqual(comm.Message{ .poweroff_progress = .{ .services = &.{
        .{ .name = "lnd", .stopped = true, .err = null },
        .{ .name = "bitcoind", .stopped = false, .err = null },
    } } }, msg2.value);

    const msg3 = try comm.read(arena, gui_reader);
    try tt.expectDeepEqual(comm.Message{ .poweroff_progress = .{ .services = &.{
        .{ .name = "lnd", .stopped = true, .err = null },
        .{ .name = "bitcoind", .stopped = true, .err = null },
    } } }, msg3.value);

    // TODO: ensure "poweroff" was executed once custom runner is in a zig release;
    // need custom runner to set up a global registry for child processes.
    // https://github.com/ziglang/zig/pull/13411
}
