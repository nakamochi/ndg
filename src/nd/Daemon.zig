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
want_bitcoind_report: bool,
bitcoin_timer: time.Timer,
bitcoin_report_interval: u64 = 1 * time.ns_per_min,
// lightning fields
want_lnd_report: bool,
lnd_timer: time.Timer,
lnd_report_interval: u64 = 1 * time.ns_per_min,

/// system services actively managed by the daemon.
/// these are stop'ed during poweroff and their shutdown progress sent to ngui.
/// initialized in start and never modified again: ok to access without holding self.mu.
services: []SysService = &.{},

const Daemon = @This();

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
    try svlist.append(SysService.init(opt.allocator, "lnd", .{ .stop_wait_sec = 600 }));
    try svlist.append(SysService.init(opt.allocator, "bitcoind", .{ .stop_wait_sec = 600 }));

    const conf = try Config.init(opt.allocator, opt.confpath);
    errdefer conf.deinit();
    return .{
        .allocator = opt.allocator,
        .conf = conf,
        .uireader = opt.uir,
        .uiwriter = opt.uiw,
        .wpa_ctrl = try types.WpaControl.open(opt.wpa),
        .state = .stopped,
        .services = try svlist.toOwnedSlice(),
        // send persisted settings immediately on start
        .want_settings = true,
        // send a network report right at start without wifi scan to make it faster.
        .want_network_report = true,
        .want_wifi_scan = false,
        .network_report_ready = true,
        // report bitcoind status immediately on start
        .want_bitcoind_report = true,
        .bitcoin_timer = try time.Timer.start(),
        // report lightning status immediately on start
        .want_lnd_report = true,
        .lnd_timer = try time.Timer.start(),
    };
}

/// releases all associated resources.
/// the daemon must be stop'ed and wait'ed before deiniting.
pub fn deinit(self: *Daemon) void {
    defer self.conf.deinit();
    self.wpa_ctrl.close() catch |err| logger.err("deinit: wpa_ctrl.close: {any}", .{err});
    for (self.services) |*sv| {
        sv.deinit();
    }
    self.allocator.free(self.services);
}

/// start launches daemon threads and returns immediately.
/// once started, the daemon must be eventually stop'ed and wait'ed to clean up
/// resources even if a poweroff sequence is initiated with beginPoweroff.
pub fn start(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .stopped => {}, // continue
        .poweroff => return error.InPoweroffState,
        else => return error.AlreadyStarted,
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
        .stopped, .poweroff => return error.InvalidState,
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
        .running => {},
        .stopped, .poweroff => return error.InvalidState,
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
        .stopped => return error.InvalidState,
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
    for (self.services) |*sv| {
        sv.stop() catch |err| logger.err("sv stop '{s}': {any}", .{ sv.name, err });
    }
    self.sendPoweroffReport() catch |err| logger.err("sendPoweroffReport: {any}", .{err});

    // wait each service until stopped or error.
    for (self.services) |*sv| {
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

    if (self.want_bitcoind_report or self.bitcoin_timer.read() > self.bitcoin_report_interval) {
        if (self.sendBitcoindReport()) {
            self.bitcoin_timer.reset();
            self.want_bitcoind_report = false;
        } else |err| {
            logger.err("sendBitcoinReport: {any}", .{err});
        }
    }
    if (self.want_lnd_report or self.lnd_timer.read() > self.lnd_report_interval) {
        if (self.sendLightningReport()) {
            self.lnd_timer.reset();
            self.want_lnd_report = false;
        } else |err| {
            logger.err("sendLightningReport: {any}", .{err});
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
                .running, .standby => {
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

        const msg = res.value;
        logger.debug("got msg: {s}", .{@tagName(msg)});
        switch (msg) {
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
            else => logger.warn("unhandled msg tag {s}", .{@tagName(msg)}),
        }

        self.mu.lock();
        quit = self.want_stop;
        self.mu.unlock();
    }

    logger.info("exiting comm thread loop", .{});
}

/// sends poweroff progress to uiwriter in comm.Message.PoweroffProgress format.
fn sendPoweroffReport(self: *Daemon) !void {
    var svstat = try self.allocator.alloc(comm.Message.PoweroffProgress.Service, self.services.len);
    defer self.allocator.free(svstat);
    for (self.services, svstat) |*sv, *stat| {
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
        return error.ConnectWifiEmptySSID;
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

fn sendBitcoindReport(self: *Daemon) !void {
    var client = bitcoindrpc.Client{
        .allocator = self.allocator,
        .cookiepath = "/ssd/bitcoind/mainnet/.cookie",
    };
    const bcinfo = try client.call(.getblockchaininfo, {});
    defer bcinfo.deinit();
    const netinfo = try client.call(.getnetworkinfo, {});
    defer netinfo.deinit();
    const mempool = try client.call(.getmempoolinfo, {});
    defer mempool.deinit();

    const balance: ?lndhttp.WalletBalance = blk: {
        var lndc = lndhttp.Client.init(.{
            .allocator = self.allocator,
            .tlscert_path = "/home/lnd/.lnd/tls.cert",
            .macaroon_ro_path = "/ssd/lnd/data/chain/bitcoin/mainnet/readonly.macaroon",
        }) catch break :blk null;
        defer lndc.deinit();
        const res = lndc.call(.walletbalance, {}) catch break :blk null;
        defer res.deinit();
        break :blk res.value;
    };

    const btcrep: comm.Message.BitcoinReport = .{
        .blocks = bcinfo.value.blocks,
        .headers = bcinfo.value.headers,
        .timestamp = bcinfo.value.time,
        .hash = bcinfo.value.bestblockhash,
        .ibd = bcinfo.value.initialblockdownload,
        .diskusage = bcinfo.value.size_on_disk,
        .version = netinfo.value.subversion,
        .conn_in = netinfo.value.connections_in,
        .conn_out = netinfo.value.connections_out,
        .warnings = bcinfo.value.warnings, // TODO: netinfo.result.warnings
        .localaddr = &.{}, // TODO: populate
        // something similar to this:
        // @round(bcinfo.verificationprogress * 100)
        .verifyprogress = 0,
        .mempool = .{
            .loaded = mempool.value.loaded,
            .txcount = mempool.value.size,
            .usage = mempool.value.usage,
            .max = mempool.value.maxmempool,
            .totalfee = mempool.value.total_fee,
            .minfee = mempool.value.mempoolminfee,
            .fullrbf = mempool.value.fullrbf,
        },
        .balance = if (balance) |bal| .{
            .source = .lnd,
            .total = bal.total_balance,
            .confirmed = bal.confirmed_balance,
            .unconfirmed = bal.unconfirmed_balance,
            .locked = bal.locked_balance,
            .reserved = bal.reserved_balance_anchor_chan,
        } else null,
    };

    try comm.write(self.allocator, self.uiwriter, .{ .bitcoind_report = btcrep });
}

fn sendLightningReport(self: *Daemon) !void {
    var client = try lndhttp.Client.init(.{
        .allocator = self.allocator,
        .tlscert_path = "/home/lnd/.lnd/tls.cert",
        .macaroon_ro_path = "/ssd/lnd/data/chain/bitcoin/mainnet/readonly.macaroon",
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
    daemon.want_bitcoind_report = false;
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

    try t.expect(daemon.services.len > 0);
    for (daemon.services) |*sv| {
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
    daemon.want_bitcoind_report = false;
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
    for (daemon.services) |*sv| {
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
