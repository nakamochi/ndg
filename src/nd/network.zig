//! network utility functions.
//! unsafe for concurrent use: callers must implement a fence mechanism
//! to allow only a single function execution concurrently when called with
//! the same WPA control socket, and possibly i/o writer or allocator unless
//! those already provide synchronization.

const std = @import("std");
const mem = std.mem;

const nif = @import("nif");
const comm = @import("../comm.zig");
const types = @import("../types.zig");

const logger = std.log.scoped(.network);

/// creates a new network using wpa_ctrl and configures its parameters.
/// returns an ID of the new wifi.
///
/// if password is blank, the key management config is set to NONE.
/// note: only cleartext passwords are supported at the moment.
pub fn addWifi(gpa: mem.Allocator, wpa_ctrl: *types.WpaControl, ssid: []const u8, password: []const u8) !u32 {
    // - ADD_NETWORK -> get id and set parameters
    // - SET_NETWORK <id> ssid "ssid"
    // - if password:
    //   SET_NETWORK <id> psk "password"
    // else:
    //   SET_NETWORK <id> key_mgmt NONE
    const new_wifi_id = try wpa_ctrl.addNetwork();
    errdefer wpa_ctrl.removeNetwork(new_wifi_id) catch |err| {
        logger.err("addWifiNetwork err cleanup: {any}", .{err});
    };
    var buf: [128:0]u8 = undefined;
    // TODO: convert ssid to hex string, to support special characters
    const ssidZ = try std.fmt.bufPrintZ(&buf, "\"{s}\"", .{ssid});
    try wpa_ctrl.setNetworkParam(new_wifi_id, "ssid", ssidZ);
    if (password.len > 0) {
        // TODO: switch to wpa_passphrase
        const v = try std.fmt.bufPrintZ(&buf, "\"{s}\"", .{password});
        try wpa_ctrl.setNetworkParam(new_wifi_id, "psk", v);
    } else {
        try wpa_ctrl.setNetworkParam(new_wifi_id, "key_mgmt", "NONE");
    }

    // - LIST_NETWORKS: network id / ssid / bssid / flags
    // - for each matching ssid unless it's newly created: REMOVE_NETWORK <id>
    if (queryWifiNetworksList(gpa, wpa_ctrl, .{ .ssid = ssid })) |res| {
        defer gpa.free(res);
        for (res) |id| {
            if (id == new_wifi_id) {
                continue;
            }
            wpa_ctrl.removeNetwork(id) catch |err| {
                logger.err("wpa_ctrl.removeNetwork({}): {any}", .{ id, err });
            };
        }
    } else |err| {
        logger.err("queryWifiNetworksList({s}): {any}; won't remove existing, if any", .{ ssid, err });
    }

    return new_wifi_id;
}

/// reports network status to the writer w in `comm.Message.NetworkReport` format.
pub fn sendReport(gpa: mem.Allocator, wpa_ctrl: *types.WpaControl, w: anytype) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report = comm.Message.NetworkReport{
        .ipaddrs = undefined,
        .wifi_ssid = null,
        .wifi_scan_networks = &.{},
    };

    // fetch all public IP addresses using getifaddrs
    const pubaddr = try nif.pubAddresses(arena, null);
    var ipaddr = try std.ArrayList([]const u8).initCapacity(arena, pubaddr.len);
    for (pubaddr) |apub| {
        try ipaddr.append(try std.fmt.allocPrint(arena, "{}", .{apub}));
    }
    report.ipaddrs = try ipaddr.toOwnedSlice();

    // get currently connected SSID, if any, from WPA ctrl
    report.wifi_ssid = queryWifiSSID(arena, wpa_ctrl) catch |err| blk: {
        logger.err("queryWifiSsid: {any}", .{err});
        break :blk null;
    };

    // fetch available wifi networks from scan results using WPA ctrl
    const wifi_networks: ?types.StringList = if (queryWifiScanResults(arena, wpa_ctrl)) |v| v else |err| blk: {
        logger.err("queryWifiScanResults: {any}", .{err});
        break :blk null;
    };
    if (wifi_networks) |list| {
        report.wifi_scan_networks = list.items();
    }

    // report everything back to ngui
    return comm.write(gpa, w, comm.Message{ .network_report = report });
}

/// returns SSID of the currenly connected wifi, if any.
/// callers must free returned value with the same allocator.
fn queryWifiSSID(gpa: mem.Allocator, wpa_ctrl: *types.WpaControl) !?[]const u8 {
    var buf: [512:0]u8 = undefined;
    const resp = try wpa_ctrl.request("STATUS", &buf, null);
    const ssid = "ssid=";
    var it = mem.tokenize(u8, resp, "\n");
    while (it.next()) |line| {
        if (mem.startsWith(u8, line, ssid)) {
            // TODO: check line.len vs ssid.len
            const v = try gpa.dupe(u8, line[ssid.len..]);
            return v;
        }
    }
    return null;
}

/// returns a list of all available wifi networks once a scan is complete.
/// the scan is initiated with wpa_ctrl.scan() and it is ready when CTRL-EVENT-SCAN-RESULTS
/// header is present on wpa_ctrl.
///
/// the retuned value must be free'd with StringList.deinit.
fn queryWifiScanResults(gpa: mem.Allocator, wpa_ctrl: *types.WpaControl) !types.StringList {
    var buf: [8192:0]u8 = undefined; // TODO: what if isn't enough?
    // first line is banner: "bssid / frequency / signal level / flags / ssid"
    const resp = try wpa_ctrl.request("SCAN_RESULTS", &buf, null);
    var it = mem.tokenize(u8, resp, "\n");
    if (it.next() == null) {
        return error.MissingWifiScanHeader;
    }

    var seen = std.BufSet.init(gpa);
    defer seen.deinit();
    var list = types.StringList.init(gpa);
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

/// returns a list of all configured network IDs or only those matching the filter.
/// the returned value must be free'd with the same allocator.
fn queryWifiNetworksList(gpa: mem.Allocator, wpa_ctrl: *types.WpaControl, filter: WifiNetworksListFilter) ![]u32 {
    var buf: [8192:0]u8 = undefined; // TODO: is this enough?
    // first line is banner: "network id / ssid / bssid / flags"
    const resp = try wpa_ctrl.request("LIST_NETWORKS", &buf, null);
    var it = mem.tokenize(u8, resp, "\n");
    if (it.next() == null) {
        return error.MissingWifiNetworksListHeader;
    }

    var list = std.ArrayList(u32).init(gpa);
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
    return try list.toOwnedSlice();
}
