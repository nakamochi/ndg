///! daemon watches network status and communicates updates to the gui
///! using uiwriter
const std = @import("std");
const mem = std.mem;
const time = std.time;

const nif = @import("nif");

const comm = @import("../comm.zig");
const screen = @import("../ui/screen.zig");

const logger = std.log.scoped(.netmon);

// pub fields
allocator: mem.Allocator,
uiwriter: std.fs.File.Writer, // ngui stdin
wpa_ctrl: nif.wpa.Control, // guarded by mu once start'ed

// private fields
mu: std.Thread.Mutex = .{},
quit: bool = false, // tells daemon to quit
main_thread: ?std.Thread = null, // non-nill if started
want_report: bool = false,
want_wifi_scan: bool = false,
wifi_scan_in_progress: bool = false,
report_ready: bool = true, // no need to scan for an immediate report
wpa_save_config_on_connected: bool = false,

const Daemon = @This();

pub fn start(self: *Daemon) !void {
    // TODO: return error if already started
    self.main_thread = try std.Thread.spawn(.{}, mainThreadLoop, .{self});
}

pub fn stop(self: *Daemon) void {
    self.mu.lock();
    self.quit = true;
    self.mu.unlock();
    if (self.main_thread) |th| {
        th.join();
    }
}

pub fn standby(_: *Daemon) !void {
    try screen.backlight(.off);
}

pub fn wakeup(_: *Daemon) !void {
    try screen.backlight(.on);
}

/// main thread entry point.
fn mainThreadLoop(self: *Daemon) !void {
    try self.wpa_ctrl.attach();
    defer self.wpa_ctrl.detach() catch |err| logger.err("wpa_ctrl.detach failed on exit: {any}", .{err});

    while (true) {
        time.sleep(1 * time.ns_per_s);
        self.mainThreadLoopCycle();

        self.mu.lock();
        const do_quit = self.quit;
        self.mu.unlock();
        if (do_quit) {
            break;
        }
    }
}

/// run one cycle of the main thread loop iteration.
/// holds self.mu for the whole duration.
fn mainThreadLoopCycle(self: *Daemon) void {
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
    if (self.want_report and self.report_ready) {
        if (self.sendNetworkReport()) {
            self.want_report = false;
        } else |err| {
            logger.err("sendNetworkReport: {any}", .{err});
        }
    }
}

/// caller must hold self.mu.
fn startWifiScan(self: *Daemon) !void {
    try self.wpa_ctrl.scan();
    self.wifi_scan_in_progress = true;
    self.report_ready = false;
}

/// invoked when CTRL-EVENT-SCAN-RESULTS event is seen.
/// caller must hold self.mu.
fn wifiScanComplete(self: *Daemon) void {
    self.wifi_scan_in_progress = false;
    self.report_ready = true;
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
    self.want_report = true;
}

/// invoked when CTRL-EVENT-SSID-TEMP-DISABLED event with authentication failures is seen.
/// caller must hold self.mu.
fn wifiInvalidKey(self: *Daemon) void {
    self.wpa_save_config_on_connected = false;
    self.want_report = true;
    self.report_ready = true;
}

pub const ReportNetworkStatusOpt = struct {
    scan: bool,
};

pub fn reportNetworkStatus(self: *Daemon, opt: ReportNetworkStatusOpt) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.want_report = true;
    self.want_wifi_scan = opt.scan and !self.wifi_scan_in_progress;
    if (self.want_wifi_scan and self.report_ready) {
        self.report_ready = false;
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

    // unfortunately, this prevents main thread from looping until released.
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

/// callers must free with StringList.deinit.
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

/// caller must release results with allocator.free.
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
