///! daemon <-> gui communication
const std = @import("std");
const json = std.json;
const mem = std.mem;

pub const Message = union(MessageTag) {
    ping: void,
    pong: void,
    poweroff: void,
    wifi_connect: WifiConnect,
    network_report: NetworkReport,
    get_network_report: GetNetworkReport,

    pub const WifiConnect = struct {
        ssid: []const u8,
        password: []const u8,
    };

    pub const NetworkReport = struct {
        ipaddrs: []const []const u8,
        wifi_ssid: ?[]const u8, // null indicates disconnected from wifi
        wifi_scan_networks: []const []const u8,
    };

    pub const GetNetworkReport = struct {
        scan: bool, // true starts a wifi scan and send NetworkReport only after completion
    };
};

pub const MessageTag = enum(u8) {
    ping,
    pong,
    poweroff,
    wifi_connect,
    network_report,
    get_network_report,
};

const Header = extern struct {
    tag: MessageTag,
    len: usize,
};

/// reads and parses a single message from the input stream reader.
/// callers must deallocate resources with free when done.
pub fn read(allocator: mem.Allocator, reader: anytype) anyerror!Message {
    const h = try reader.readStruct(Header);
    if (h.len == 0) {
        const m = switch (h.tag) {
            .ping => Message{ .ping = {} },
            .pong => Message{ .pong = {} },
            .poweroff => Message{ .poweroff = {} },
            else => error.ZeroLenInNonVoidTag,
        };
        return m;
    }

    // TODO: limit h.len to some max value
    var bytes = try allocator.alloc(u8, h.len);
    defer allocator.free(bytes);
    try reader.readNoEof(bytes);

    const jopt = json.ParseOptions{ .allocator = allocator, .ignore_unknown_fields = true };
    var jstream = json.TokenStream.init(bytes);
    return switch (h.tag) {
        .ping, .pong, .poweroff => unreachable, // void
        .wifi_connect => Message{
            .wifi_connect = try json.parse(Message.WifiConnect, &jstream, jopt),
        },
        .network_report => Message{
            .network_report = try json.parse(Message.NetworkReport, &jstream, jopt),
        },
        .get_network_report => Message{
            .get_network_report = try json.parse(Message.GetNetworkReport, &jstream, jopt),
        },
    };
}

/// outputs the message msg using writer.
/// all allocated resources are freed upon return.
pub fn write(allocator: mem.Allocator, writer: anytype, msg: Message) !void {
    var header = Header{ .tag = msg, .len = 0 };
    switch (msg) {
        .ping, .pong, .poweroff => return writer.writeStruct(header),
        else => {}, // non-zero payload; continue
    }

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    const jopt = .{ .whitespace = null };
    switch (msg) {
        .ping, .pong, .poweroff => unreachable,
        .wifi_connect => try json.stringify(msg.wifi_connect, jopt, data.writer()),
        .network_report => try json.stringify(msg.network_report, jopt, data.writer()),
        .get_network_report => try json.stringify(msg.get_network_report, jopt, data.writer()),
    }

    header.len = data.items.len;
    try writer.writeStruct(header);
    try writer.writeAll(data.items);
}

pub fn free(allocator: mem.Allocator, m: Message) void {
    switch (m) {
        .ping, .pong, .poweroff => {},
        else => |v| {
            json.parseFree(@TypeOf(v), v, .{ .allocator = allocator });
        },
    }
}

test "read" {
    const t = std.testing;

    var data = std.ArrayList(u8).init(t.allocator);
    defer data.deinit();
    const msg = Message{ .wifi_connect = .{ .ssid = "hello", .password = "world" } };
    try json.stringify(msg.wifi_connect, .{}, data.writer());

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    try buf.writer().writeStruct(Header{ .tag = msg, .len = data.items.len });
    try buf.writer().writeAll(data.items);

    var bs = std.io.fixedBufferStream(buf.items);
    const res = try read(t.allocator, bs.reader());
    defer free(t.allocator, res);

    try t.expectEqualStrings(msg.wifi_connect.ssid, res.wifi_connect.ssid);
    try t.expectEqualStrings(msg.wifi_connect.password, res.wifi_connect.password);
}

test "write" {
    const t = std.testing;

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    const msg = Message{ .wifi_connect = .{ .ssid = "wlan", .password = "secret" } };
    try write(t.allocator, buf.writer(), msg);

    const payload = "{\"ssid\":\"wlan\",\"password\":\"secret\"}";
    var js = std.ArrayList(u8).init(t.allocator);
    defer js.deinit();
    try js.writer().writeStruct(Header{ .tag = msg, .len = payload.len });
    try js.appendSlice(payload);

    try t.expectEqualSlices(u8, js.items, buf.items);
}

test "write/read void tags" {
    const t = std.testing;

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();

    const msg = [_]Message{
        Message.ping,
        Message.pong,
        Message.poweroff,
    };

    for (msg) |m| {
        buf.clearAndFree();
        try write(t.allocator, buf.writer(), m);
        var bs = std.io.fixedBufferStream(buf.items);
        const res = try read(t.allocator, bs.reader());
        free(t.allocator, res); // noop
        try t.expectEqual(m, res);
    }
}

test "msg sequence" {
    const t = std.testing;

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();

    const msgs = [_]Message{
        Message.ping,
        Message{ .wifi_connect = .{ .ssid = "wlan", .password = "secret" } },
        Message.pong,
        Message{ .network_report = .{
            .ipaddrs = &.{},
            .wifi_ssid = null,
            .wifi_scan_networks = &.{ "foo", "bar" },
        } },
    };
    for (msgs) |m| {
        try write(t.allocator, buf.writer(), m);
    }

    var bs = std.io.fixedBufferStream(buf.items);
    for (msgs) |m| {
        const res = try read(t.allocator, bs.reader());
        defer free(t.allocator, res);
        try t.expectEqual(@as(MessageTag, m), @as(MessageTag, res));
    }
}
