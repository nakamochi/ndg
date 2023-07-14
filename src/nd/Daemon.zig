//! daemon watches network status and communicates updates to the GUI using uiwriter.
//! public fields are allocator
//! usage example:
//!
//!     var ctrl = try nif.wpa.Control.open("/run/wpa_supplicant/wlan0");
//!     defer ctrl.close() catch {};
//!     var nd: Daemon = .{
//!         .allocator = gpa,
//!         .uiwriter = ngui_stdio_writer,
//!         .wpa_ctrl = ctrl,
//!     };
//!     try nd.start();

const std = @import("std");
const mem = std.mem;
const time = std.time;

const nif = @import("nif");

const comm = @import("../comm.zig");
const screen = @import("../ui/screen.zig");
const types = @import("../types.zig");
const SysService = @import("SysService.zig");

const logger = std.log.scoped(.netmon);

allocator: mem.Allocator,
uiwriter: std.fs.File.Writer, // ngui stdin
wpa_ctrl: types.WpaControl, // guarded by mu once start'ed

/// guards all the fields below to sync between pub fns and main/poweroff threads.
mu: std.Thread.Mutex = .{},

/// daemon state
state: enum {
    stopped,
    running,
    poweroff,
},

main_thread: ?std.Thread = null,
poweroff_thread: ?std.Thread = null,

want_stop: bool = false, // tells daemon main loop to quit
want_network_report: bool = false,
want_wifi_scan: bool = false,
wifi_scan_in_progress: bool = false,
network_report_ready: bool = true, // no need to scan for an immediate report
wpa_save_config_on_connected: bool = false,

/// system services actively managed by the daemon.
/// these are stop'ed during poweroff and their shutdown progress sent to ngui.
/// initialized in start and never modified again: ok to access without holding self.mu.
services: []SysService = &.{},

const Daemon = @This();

/// callers must deinit when done.
pub fn init(a: std.mem.Allocator, iogui: std.fs.File.Writer, wpa_path: [:0]const u8) !Daemon {
    var svlist = std.ArrayList(SysService).init(a);
    errdefer {
        for (svlist.items) |*sv| sv.deinit();
        svlist.deinit();
    }
    // the order is important. when powering off, the services are shut down
    // in the same order appended here.
    try svlist.append(SysService.init(a, "lnd", .{ .stop_wait_sec = 600 }));
    try svlist.append(SysService.init(a, "bitcoind", .{ .stop_wait_sec = 600 }));
    return .{
        .allocator = a,
        .uiwriter = iogui,
        .wpa_ctrl = try types.WpaControl.open(wpa_path),
        .state = .stopped,
        .services = svlist.toOwnedSlice(),
    };
}

/// releases all associated resources.
/// if the daemon is not in a stopped or poweroff mode, deinit panics.
pub fn deinit(self: *Daemon) void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .stopped, .poweroff => if (self.want_stop) {
            @panic("deinit while stopping");
        },
        else => @panic("deinit while running"),
    }
    self.wpa_ctrl.close() catch |err| logger.err("deinit: wpa_ctrl.close: {any}", .{err});
    for (self.services) |*sv| {
        sv.deinit();
    }
    self.allocator.free(self.services);
}

/// start launches a main thread and returns immediately.
/// once started, the daemon must be eventually stop'ed to clean up resources
/// even if a poweroff sequence is launched with beginPoweroff. however, in the latter
/// case the daemon cannot be start'ed again after stop.
pub fn start(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .running => return error.AlreadyStarted,
        .poweroff => return error.InPoweroffState,
        .stopped => {}, // continue
    }

    try self.wpa_ctrl.attach();
    self.main_thread = try std.Thread.spawn(.{}, mainThreadLoop, .{self});
    self.state = .running;
}

/// stop blocks until all daemon threads exit, including poweroff if any.
/// once stopped, the daemon can be start'ed again unless a poweroff was initiated.
///
/// note: stop leaves system services like lnd and bitcoind running.
pub fn stop(self: *Daemon) void {
    self.mu.lock();
    if (self.want_stop or self.state == .stopped) {
        self.mu.unlock();
        return; // already in progress or stopped
    }
    self.want_stop = true;
    self.mu.unlock(); // avoid threads deadlock

    if (self.main_thread) |th| {
        th.join();
        self.main_thread = null;
    }
    // must be the last one to join because it sends a final poweroff report.
    if (self.poweroff_thread) |th| {
        th.join();
        self.poweroff_thread = null;
    }

    self.mu.lock();
    defer self.mu.unlock();
    self.want_stop = false;
    if (self.state != .poweroff) { // keep poweroff to prevent start'ing again
        self.state = .stopped;
    }
    self.wpa_ctrl.detach() catch |err| logger.err("stop: wpa_ctrl.detach: {any}", .{err});
}

pub fn standby(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();
    switch (self.state) {
        .poweroff => return error.InPoweroffState,
        .running, .stopped => {}, // continue
    }
    try screen.backlight(.off);
}

pub fn wakeup(_: *Daemon) !void {
    try screen.backlight(.on);
}

/// initiates system poweroff sequence in a separate thread: shut down select
/// system services such as lnd and bitcoind, and issue "poweroff" command.
///
/// in the poweroff mode, the daemon is still running as usual and must be stop'ed.
/// however, in poweroff mode regular functionalities are disabled, such as
/// wifi scan and standby.
pub fn beginPoweroff(self: *Daemon) !void {
    self.mu.lock();
    defer self.mu.unlock();
    if (self.state == .poweroff) {
        return; // already in poweroff state
    }

    self.poweroff_thread = try std.Thread.spawn(.{}, poweroffThread, .{self});
    self.state = .poweroff;
}

// stops all monitored services and issue poweroff command while reporting
// the progress to ngui.
fn poweroffThread(self: *Daemon) !void {
    logger.info("begin powering off", .{});
    screen.backlight(.on) catch |err| {
        logger.err("screen.backlight(.on) during poweroff: {any}", .{err});
    };
    self.wpa_ctrl.detach() catch {}; // don't care because powering off anyway

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

/// main thread entry point.
fn mainThreadLoop(self: *Daemon) !void {
    var quit = false;
    while (!quit) {
        self.mainThreadLoopCycle() catch |err| logger.err("main thread loop: {any}", .{err});
        time.sleep(1 * time.ns_per_s);

        self.mu.lock();
        quit = self.want_stop;
        self.mu.unlock();
    }
}

/// run one cycle of the main thread loop iteration.
/// unless in poweroff mode, the cycle holds self.mu for the whole duration.
fn mainThreadLoopCycle(self: *Daemon) !void {
    switch (self.state) {
        // poweroff mode: do nothing; handled by poweroffThread
        .poweroff => {},
        // normal state: running or standby
        else => {
            self.mu.lock();
            defer self.mu.unlock();
            self.readWPACtrlMsg() catch |err| logger.err("readWPACtrlMsg: {any}", .{err});
            if (self.want_wifi_scan) {
                if (self.startWifiScan()) {
                    self.want_wifi_scan = false;
                } else |err| {
                    logger.err("startWifiScan: {any}", .{err});
                }
            }
            if (self.want_network_report and self.network_report_ready) {
                if (self.sendNetworkReport()) {
                    self.want_network_report = false;
                } else |err| {
                    logger.err("sendNetworkReport: {any}", .{err});
                }
            }
        },
    }
}

fn sendPoweroffReport(self: *Daemon) !void {
    var svstat = try self.allocator.alloc(comm.Message.PoweroffProgress.Service, self.services.len);
    defer self.allocator.free(svstat);
    for (self.services) |*sv, i| {
        svstat[i] = .{
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
/// caller must hold self.mu.
fn wifiInvalidKey(self: *Daemon) void {
    self.wpa_save_config_on_connected = false;
    self.want_network_report = true;
    self.network_report_ready = true;
}

pub const ReportNetworkStatusOpt = struct {
    scan: bool,
};

pub fn reportNetworkStatus(self: *Daemon, opt: ReportNetworkStatusOpt) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.want_network_report = true;
    self.want_wifi_scan = opt.scan and !self.wifi_scan_in_progress;
    if (self.want_wifi_scan and self.network_report_ready) {
        self.network_report_ready = false;
    }
}

pub fn startConnectWifi(self: *Daemon, ssid: []const u8, password: []const u8) !void {
    if (ssid.len == 0) {
        return error.ConnectWifiEmptySSID;
    }
    const ssid_copy = try self.allocator.dupe(u8, ssid);
    const pwd_copy = try self.allocator.dupe(u8, password);
    const th = try std.Thread.spawn(.{}, connectWifiThread, .{ self, ssid_copy, pwd_copy });
    th.detach();
}

fn connectWifiThread(self: *Daemon, ssid: []const u8, password: []const u8) void {
    defer {
        self.allocator.free(ssid);
        self.allocator.free(password);
    }
    // https://hostap.epitest.fi/wpa_supplicant/devel/ctrl_iface_page.html
    // https://wiki.archlinux.org/title/WPA_supplicant

    // this prevents main thread from looping until released,
    // but the following commands and expected to be pretty quick.
    self.mu.lock();
    defer self.mu.unlock();

    const id = self.addWifiNetwork(ssid, password) catch |err| {
        logger.err("addWifiNetwork: {any}; exiting", .{err});
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

/// adds a new network and configures its parameters.
/// caller must hold self.mu.
fn addWifiNetwork(self: *Daemon, ssid: []const u8, password: []const u8) !u32 {
    // - ADD_NETWORK -> get id and set parameters
    // - SET_NETWORK <id> ssid "ssid"
    // - if password:
    //   SET_NETWORK <id> psk "password"
    // else:
    //   SET_NETWORK <id> key_mgmt NONE
    const newWifiId = try self.wpa_ctrl.addNetwork();
    errdefer self.wpa_ctrl.removeNetwork(newWifiId) catch |err| {
        logger.err("addWifiNetwork cleanup: {any}", .{err});
    };
    var buf: [128:0]u8 = undefined;
    // TODO: convert ssid to hex string, to support special characters
    const ssidZ = try std.fmt.bufPrintZ(&buf, "\"{s}\"", .{ssid});
    try self.wpa_ctrl.setNetworkParam(newWifiId, "ssid", ssidZ);
    if (password.len > 0) {
        // TODO: switch to wpa_passphrase
        const v = try std.fmt.bufPrintZ(&buf, "\"{s}\"", .{password});
        try self.wpa_ctrl.setNetworkParam(newWifiId, "psk", v);
    } else {
        try self.wpa_ctrl.setNetworkParam(newWifiId, "key_mgmt", "NONE");
    }

    // - LIST_NETWORKS: network id / ssid / bssid / flags
    // - for each matching ssid unless it's newly created: REMOVE_NETWORK <id>
    if (self.queryWifiNetworksList(.{ .ssid = ssid })) |res| {
        defer self.allocator.free(res);
        for (res) |id| {
            if (id == newWifiId) {
                continue;
            }
            self.wpa_ctrl.removeNetwork(id) catch |err| {
                logger.err("wpa_ctrl.removeNetwork({}): {any}", .{ id, err });
            };
        }
    } else |err| {
        logger.err("queryWifiNetworksList({s}): {any}; won't remove existing, if any", .{ ssid, err });
    }

    return newWifiId;
}

/// caller must hold self.mu.
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

/// report network status to ngui.
/// caller must hold self.mu.
fn sendNetworkReport(self: *Daemon) !void {
    var report = comm.Message.NetworkReport{
        .ipaddrs = undefined,
        .wifi_ssid = null,
        .wifi_scan_networks = undefined,
    };

    // fetch all public IP addresses using getifaddrs
    const pubaddr = try nif.pubAddresses(self.allocator, null);
    defer self.allocator.free(pubaddr);
    //var addrs = std.ArrayList([]).init(t.allocator);
    var ipaddrs = try self.allocator.alloc([]const u8, pubaddr.len);
    for (pubaddr) |a, i| {
        ipaddrs[i] = try std.fmt.allocPrint(self.allocator, "{s}", .{a});
    }
    defer {
        for (ipaddrs) |a| self.allocator.free(a);
        self.allocator.free(ipaddrs);
    }
    report.ipaddrs = ipaddrs;

    // get currently connected SSID, if any, from WPA ctrl
    const ssid = self.queryWifiSSID() catch |err| blk: {
        logger.err("queryWifiSsid: {any}", .{err});
        break :blk null;
    };
    defer if (ssid) |v| self.allocator.free(v);
    report.wifi_ssid = ssid;

    // fetch available wifi networks from scan results using WPA ctrl
    var wifi_networks: ?StringList = if (self.queryWifiScanResults()) |v| v else |err| blk: {
        logger.err("queryWifiScanResults: {any}", .{err});
        break :blk null;
    };
    defer if (wifi_networks) |*list| list.deinit();
    if (wifi_networks) |list| {
        report.wifi_scan_networks = list.items();
    }

    // report everything back to ngui
    return comm.write(self.allocator, self.uiwriter, comm.Message{ .network_report = report });
}

/// caller must hold self.mu.
fn queryWifiSSID(self: *Daemon) !?[]const u8 {
    var buf: [512:0]u8 = undefined;
    const resp = try self.wpa_ctrl.request("STATUS", &buf, null);
    const ssid = "ssid=";
    var it = mem.tokenize(u8, resp, "\n");
    while (it.next()) |line| {
        if (mem.startsWith(u8, line, ssid)) {
            // TODO: check line.len vs ssid.len
            const v = try self.allocator.dupe(u8, line[ssid.len..]);
            return v;
        }
    }
    return null;
}

/// caller must hold self.mu.
/// the retuned value must free'd with StringList.deinit.
fn queryWifiScanResults(self: *Daemon) !StringList {
    var buf: [8192:0]u8 = undefined; // TODO: what if isn't enough?
    // first line is banner: "bssid / frequency / signal level / flags / ssid"
    const resp = try self.wpa_ctrl.request("SCAN_RESULTS", &buf, null);
    var it = mem.tokenize(u8, resp, "\n");
    if (it.next() == null) {
        return error.MissingWifiScanHeader;
    }

    var seen = std.BufSet.init(self.allocator);
    defer seen.deinit();
    var list = StringList.init(self.allocator);
    errdefer list.deinit();
    while (it.next()) |line| {
        // TODO: wpactrl's text protocol won't work for names with control characters
        if (mem.lastIndexOfScalar(u8, line, '\t')) |i| {
            const s = mem.trim(u8, line[i..], "\t\n");
            if (s.len == 0 or seen.contains(s)) {
                continue;
            }
            try seen.insert(s);
            try list.append(s);
        }
    }
    return list;
}

const WifiNetworksListFilter = struct {
    ssid: ?[]const u8, // ignore networks whose ssid doesn't match
};

/// caller must hold self.mu.
/// the returned value must be free'd with self.allocator.
fn queryWifiNetworksList(self: *Daemon, filter: WifiNetworksListFilter) ![]u32 {
    var buf: [8192:0]u8 = undefined; // TODO: is this enough?
    // first line is banner: "network id / ssid / bssid / flags"
    const resp = try self.wpa_ctrl.request("LIST_NETWORKS", &buf, null);
    var it = mem.tokenize(u8, resp, "\n");
    if (it.next() == null) {
        return error.MissingWifiNetworksListHeader;
    }

    var list = std.ArrayList(u32).init(self.allocator);
    while (it.next()) |line| {
        var cols = mem.tokenize(u8, line, "\t");
        const id_str = cols.next() orelse continue; // bad line format?
        const ssid = cols.next() orelse continue; // bad line format?
        const id = std.fmt.parseUnsigned(u32, id_str, 10) catch continue; // skip bad line
        if (filter.ssid != null and !mem.eql(u8, filter.ssid.?, ssid)) {
            continue;
        }
        list.append(id) catch {}; // grab anything we can
    }
    return list.toOwnedSlice();
}

// TODO: turns this into a UniqStringList backed by StringArrayHashMap; also see std.BufSet
const StringList = struct {
    l: std.ArrayList([]const u8),
    allocator: mem.Allocator,

    const Self = @This();

    pub fn init(allocator: mem.Allocator) Self {
        return Self{
            .l = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.l.items) |a| {
            self.allocator.free(a);
        }
        self.l.deinit();
    }

    pub fn append(self: *Self, s: []const u8) !void {
        const item = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(item);
        try self.l.append(item);
    }

    pub fn items(self: Self) []const []const u8 {
        return self.l.items;
    }
};

test "start-stop" {
    const t = std.testing;

    const pipe = try types.IoPipe.create();
    defer pipe.close();
    var daemon = try Daemon.init(t.allocator, pipe.writer(), "/dev/null");

    try t.expect(daemon.state == .stopped);
    try daemon.start();
    try t.expect(daemon.state == .running);
    try t.expect(daemon.wpa_ctrl.opened);
    try t.expect(daemon.wpa_ctrl.attached);

    daemon.stop();
    try t.expect(daemon.state == .stopped);
    try t.expect(!daemon.want_stop);
    try t.expect(!daemon.wpa_ctrl.attached);
    try t.expect(daemon.wpa_ctrl.opened);
    try t.expect(daemon.main_thread == null);
    try t.expect(daemon.poweroff_thread == null);

    try t.expect(daemon.services.len > 0);
    for (daemon.services) |*sv| {
        try t.expect(!sv.stop_proc.spawned);
        try t.expectEqual(SysService.Status.initial, sv.status());
    }

    daemon.deinit();
    try t.expect(!daemon.wpa_ctrl.opened);
}

test "start-poweroff-stop" {
    const t = std.testing;
    const tt = @import("../test.zig");

    var arena_alloc = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const pipe = try types.IoPipe.create();
    var daemon = try Daemon.init(arena, pipe.writer(), "/dev/null");
    defer {
        daemon.deinit();
        pipe.close();
    }

    try daemon.start();
    try daemon.beginPoweroff();
    daemon.stop();
    try t.expect(daemon.state == .poweroff);
    for (daemon.services) |*sv| {
        try t.expect(sv.stop_proc.spawned);
        try t.expect(sv.stop_proc.waited);
        try t.expectEqual(SysService.Status.stopped, sv.status());
    }

    const pipe_reader = pipe.reader();
    const msg1 = try comm.read(arena, pipe_reader);
    try tt.expectDeepEqual(comm.Message{ .poweroff_progress = .{ .services = &.{
        .{ .name = "lnd", .stopped = false, .err = null },
        .{ .name = "bitcoind", .stopped = false, .err = null },
    } } }, msg1);

    const msg2 = try comm.read(arena, pipe_reader);
    try tt.expectDeepEqual(comm.Message{ .poweroff_progress = .{ .services = &.{
        .{ .name = "lnd", .stopped = true, .err = null },
        .{ .name = "bitcoind", .stopped = false, .err = null },
    } } }, msg2);

    const msg3 = try comm.read(arena, pipe_reader);
    try tt.expectDeepEqual(comm.Message{ .poweroff_progress = .{ .services = &.{
        .{ .name = "lnd", .stopped = true, .err = null },
        .{ .name = "bitcoind", .stopped = true, .err = null },
    } } }, msg3);

    // TODO: ensure "poweroff" was executed once custom runner is in a zig release;
    // need custom runner to set up a global registry for child processes.
    // https://github.com/ziglang/zig/pull/13411
}
