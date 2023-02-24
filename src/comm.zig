///! daemon/gui communication.
///! the protocol is a simple TLV construct: MessageTag(u16), length(u64), json-marshalled Message;
///! little endian.
const std = @import("std");
const json = std.json;
const mem = std.mem;

const ByteArrayList = @import("types.zig").ByteArrayList;

/// common errors returned by read/write functions.
pub const Error = error{
    CommReadInvalidTag,
    CommReadZeroLenInNonVoidTag,
    CommWriteTooLarge,
};

/// daemon and gui exchange messages of this type.
pub const Message = union(MessageTag) {
    ping: void,
    pong: void,
    poweroff: void,
    standby: void,
    wakeup: void,
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

/// it is important to preserve ordinal values for future compatiblity,
/// especially when nd and gui may temporary diverge in their implementations.
pub const MessageTag = enum(u16) {
    ping = 0x01,
    pong = 0x02,
    poweroff = 0x03,
    wifi_connect = 0x04,
    network_report = 0x05,
    get_network_report = 0x06,
    // ngui -> nd: screen timeout, no user activity; no reply
    standby = 0x07,
    // ngui -> nd: resume screen due to user touch; no reply
    wakeup = 0x08,
    // next: 0x09
};

/// reads and parses a single message from the input stream reader.
/// callers must deallocate resources with free when done.
pub fn read(allocator: mem.Allocator, reader: anytype) !Message {
    // alternative is @intToEnum(reader.ReadIntLittle(u16)) but it may panic.
    const tag = reader.readEnum(MessageTag, .Little) catch {
        return Error.CommReadInvalidTag;
    };
    const len = try reader.readIntLittle(u64);
    if (len == 0) {
        return switch (tag) {
            .ping => Message{ .ping = {} },
            .pong => Message{ .pong = {} },
            .poweroff => Message{ .poweroff = {} },
            .standby => Message{ .standby = {} },
            .wakeup => Message{ .wakeup = {} },
            else => Error.CommReadZeroLenInNonVoidTag,
        };
    }

    var bytes = try allocator.alloc(u8, len);
    defer allocator.free(bytes);
    try reader.readNoEof(bytes);
    const jopt = json.ParseOptions{ .allocator = allocator, .ignore_unknown_fields = true };
    var jstream = json.TokenStream.init(bytes);
    return switch (tag) {
        .ping, .pong, .poweroff, .standby, .wakeup => unreachable, // handled above
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
    const jopt = .{ .whitespace = null };
    var data = ByteArrayList.init(allocator);
    defer data.deinit();
    switch (msg) {
        .ping, .pong, .poweroff, .standby, .wakeup => {}, // zero length payload
        .wifi_connect => try json.stringify(msg.wifi_connect, jopt, data.writer()),
        .network_report => try json.stringify(msg.network_report, jopt, data.writer()),
        .get_network_report => try json.stringify(msg.get_network_report, jopt, data.writer()),
    }
    if (data.items.len > std.math.maxInt(u64)) {
        return Error.CommWriteTooLarge;
    }

    try writer.writeIntLittle(u16, @enumToInt(msg));
    try writer.writeIntLittle(u64, data.items.len);
    try writer.writeAll(data.items);
}

pub fn free(allocator: mem.Allocator, m: Message) void {
    switch (m) {
        .ping, .pong, .poweroff, .standby, .wakeup => {}, // zero length payload
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
    try buf.writer().writeIntLittle(u16, @enumToInt(msg));
    try buf.writer().writeIntLittle(u64, data.items.len);
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
    try js.writer().writeIntLittle(u16, @enumToInt(msg));
    try js.writer().writeIntLittle(u64, payload.len);
    try js.appendSlice(payload);

    try t.expectEqualStrings(js.items, buf.items);
}

test "write/read void tags" {
    const t = std.testing;

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();

    const msg = [_]Message{
        Message.ping,
        Message.pong,
        Message.poweroff,
        Message.standby,
        Message.wakeup,
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
