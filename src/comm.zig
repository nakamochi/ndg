//! daemon/gui communication.
//! the protocol is a simple TLV construct: MessageTag(u16), length(u64), json-marshalled Message;
//! little endian.

const std = @import("std");
const json = std.json;
const mem = std.mem;

const types = @import("types.zig");

const logger = std.log.scoped(.comm);

var plumb: struct {
    a: std.mem.Allocator,
    r: std.fs.File.Reader,
    w: std.fs.File.Writer,

    fn pipeRead(self: @This()) !ParsedMessage {
        return read(self.a, self.r);
    }

    fn pipeWrite(self: @This(), m: Message) !void {
        return write(self.a, self.w, m);
    }
} = undefined;

/// initializes a global comm pipe, making `pipeRead` and `pipeWrite` ready to use from any module.
/// a message sent with `pipeWrite` can be subsequently read with `pipeRead`.
pub fn initPipe(a: std.mem.Allocator, p: types.IoPipe) void {
    plumb = .{ .a = a, .r = p.r.reader(), .w = p.w.writer() };
}

/// similar to `read` but uses a global pipe initialized with `initPipe`.
/// blocking call.
pub fn pipeRead() !ParsedMessage {
    return plumb.pipeRead();
}

/// similar to `write` but uses a global pipe initialized with `initPipe`.
/// blocking but normally buffered.
/// callers must deallocate resources with ParsedMessage.deinit when done.
pub fn pipeWrite(m: Message) !void {
    return plumb.pipeWrite(m);
}

/// common errors returned by read/write functions.
pub const Error = error{
    CommReadInvalidTag,
    CommReadZeroLenInNonVoidTag,
    CommWriteTooLarge,
};

/// it is important to preserve ordinal values for future compatiblity,
/// especially when nd and gui may temporary diverge in their implementations.
pub const MessageTag = enum(u16) {
    ping = 0x01,
    pong = 0x02,
    poweroff = 0x03,
    // nd -> ngui: reports poweroff progress
    poweroff_progress = 0x09,
    // ngui -> nd: screen timeout, no user activity; no reply
    standby = 0x07,
    // ngui -> nd: resume screen due to user touch; no reply
    wakeup = 0x08,
    wifi_connect = 0x04,
    network_report = 0x05,
    get_network_report = 0x06,
    // nd -> ngui: bitcoin core daemon status report
    onchain_report = 0x0a,
    // nd -> ngui: lnd status and stats report
    lightning_report = 0x0b,
    // nd -> ngui: error report when not in a regular running mode
    lightning_error = 0x0e,
    // ngui -> nd: call lnd to generate a new seed during initial setup
    lightning_genseed = 0x0f,
    // nd -> ngui: the result of genseed
    lightning_genseed_result = 0x10,
    // ngui -> nd: proceed with initializing a new or existing wallet
    lightning_init_wallet = 0x11,
    // ngui -> nd: request connection URLs for a controller app
    lightning_get_ctrlconn = 0x12,
    // nd -> ngui: lightning_get_ctrlconn result
    lightning_ctrlconn = 0x13,
    // ngui -> nd: factory reset lnd node; wipes out the wallet
    lightning_reset = 0x14,
    // ngui -> nd: switch sysupdates channel
    switch_sysupdates = 0x0c,
    // ngui -> nd: rename node, both hostname and lnd alias
    set_nodename = 0x15,
    // nd -> ngui: all ndg settings
    settings = 0x0d,
    // ngui -> nd: verify pincode
    unlock_screen = 0x17,
    // nd -> ngui: result of try_unlock
    screen_unlock_result = 0x18,
    // ngui -> nd: set or disable screenlock pin code
    slock_set_pincode = 0x19,
    // next: 0x1a
};

/// daemon and gui exchange messages of this type.
pub const Message = union(MessageTag) {
    ping: void,
    pong: void,
    poweroff: void,
    poweroff_progress: PoweroffProgress,
    standby: void,
    wakeup: void,
    wifi_connect: WifiConnect,
    network_report: NetworkReport,
    get_network_report: GetNetworkReport,
    onchain_report: OnchainReport,
    lightning_report: LightningReport,
    lightning_error: LightningError,
    lightning_genseed: LightningGenSeed,
    lightning_genseed_result: []const []const u8,
    lightning_init_wallet: LightningInitWallet,
    lightning_get_ctrlconn: void,
    lightning_ctrlconn: LightningCtrlConn,
    lightning_reset: void,
    switch_sysupdates: SysupdatesChan,
    set_nodename: []const u8,
    settings: Settings,
    unlock_screen: []const u8, // pincode
    screen_unlock_result: ScreenUnlockResult,
    slock_set_pincode: ?[]const u8,

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

    pub const PoweroffProgress = struct {
        services: []const Service,

        pub const Service = struct {
            name: []const u8,
            stopped: bool,
            err: ?[]const u8,
        };
    };

    pub const OnchainReport = struct {
        blocks: u64,
        headers: u64,
        timestamp: u64, // unix epoch
        hash: []const u8, // best block hash
        ibd: bool, // initial block download
        verifyprogress: u8, // 0-100%
        diskusage: u64, // estimated size on disk, in bytes
        version: []const u8, // bitcoin core version string
        conn_in: u16,
        conn_out: u16,
        warnings: []const u8,
        localaddr: []struct {
            addr: []const u8,
            port: u16,
            score: i16,
        },
        mempool: struct {
            loaded: bool,
            txcount: usize,
            usage: u64, // in memory, bytes
            max: u64, // bytes
            totalfee: f32, // in BTC
            minfee: f32, // BTC/kvB
            fullrbf: bool,
        },
        /// on-chain balance, all values in satoshis.
        /// may not be available due to disabled wallet, if bitcoin core is used,
        /// or lnd turned off/nonfunctional.
        balance: ?struct {
            source: enum { lnd, bitcoincore },
            total: i64,
            confirmed: i64,
            unconfirmed: i64,
            locked: i64, // output leases
            reserved: i64, // for fee bumps
        } = null,
    };

    pub const LightningReport = struct {
        version: []const u8,
        pubkey: []const u8,
        alias: []const u8,
        npeers: u32,
        height: u32,
        hash: []const u8,
        sync: struct { chain: bool, graph: bool },
        uris: []const []const u8,
        /// only lightning channels balance is reported here
        totalbalance: struct { local: i64, remote: i64, unsettled: i64, pending: i64 },
        totalfees: struct { day: u64, week: u64, month: u64 }, // sats
        channels: []const struct {
            id: ?[]const u8 = null, // null for pending_xxx state
            state: enum { active, inactive, pending_open, pending_close },
            private: bool,
            point: []const u8, // funding txid:index
            closetxid: ?[]const u8 = null, // non-null for pending_close
            peer_pubkey: []const u8,
            peer_alias: []const u8,
            capacity: i64,
            balance: struct { local: i64, remote: i64, unsettled: i64, limbo: i64 },
            totalsats: struct { sent: i64, received: i64 },
            fees: struct {
                base: i64, // msat
                ppm: i64, // per milli-satoshis, in millionths of satoshi
                // TODO: remote base and ppm from getchaninfo
                // https://docs.lightning.engineering/lightning-network-tools/lnd/channel-fees
            },
        },
    };

    pub const LightningCtrlConn = []const LnCtrlConnItem;

    pub const LnCtrlConnItem = struct {
        url: []const u8,
        typ: enum { lnd_rpc, lnd_http },
        perm: enum { admin }, // TODO: support read-only and invoice-only permissions
    };

    pub const LightningError = struct {
        code: enum(u8) {
            uninitialized, // wallet uninitialized
            //init_failed, TODO: when .lightning_init_wallet results in an error
            not_ready, // in a startup mode
            locked, // wallet locked
        },
    };

    /// https://lightning.engineering/api-docs/api/lnd/wallet-unlocker/gen-seed
    pub const LightningGenSeed = struct {
        // TODO: support passphrase
        //passphrase: ?[]const u8,
    };

    /// https://lightning.engineering/api-docs/api/lnd/wallet-unlocker/init-wallet
    pub const LightningInitWallet = struct {
        mnemonic: []const []const u8, // 24 words
        // TODO: support passphrase
        //passphrase: ?[]const u8,

        // TODO: support extra fields for restoring an existing wallet, like recovery_window
    };

    pub const SysupdatesChan = enum {
        stable, // master branch in sysupdates
        edge, // dev branch in sysupdates
    };

    pub const Settings = struct {
        slock_enabled: bool,
        hostname: []const u8, // see .set_nodename
        sysupdates: struct {
            channel: SysupdatesChan,
        },
    };

    pub const ScreenUnlockResult = struct {
        ok: bool,
        err: ?[]const u8 = null, // error message when !ok
    };
};

/// the return value type from `read` fn.
pub const ParsedMessage = struct {
    value: Message,
    arena: ?*std.heap.ArenaAllocator = null, // null for void message tags

    /// releases all resources used by the message.
    pub fn deinit(self: @This()) void {
        if (self.arena) |a| {
            const allocator = a.child_allocator;
            a.deinit();
            allocator.destroy(a);
        }
    }
};

/// reads and parses a single message from the input stream reader.
/// propagates reader errors as is. for example, a closed reader returns
/// error.EndOfStream.
///
/// callers must deallocate resources with ParsedMessage.deinit when done.
pub fn read(allocator: mem.Allocator, reader: anytype) !ParsedMessage {
    // alternative is @intToEnum(reader.ReadIntLittle(u16)) but it may panic.
    const tag = try reader.readEnum(MessageTag, .little);
    const len = try reader.readInt(u64, .little);
    if (len == 0) {
        return switch (tag) {
            .lightning_get_ctrlconn => .{ .value = .lightning_get_ctrlconn },
            .lightning_reset => .{ .value = .lightning_reset },
            .ping => .{ .value = .{ .ping = {} } },
            .pong => .{ .value = .{ .pong = {} } },
            .poweroff => .{ .value = .{ .poweroff = {} } },
            .standby => .{ .value = .{ .standby = {} } },
            .wakeup => .{ .value = .{ .wakeup = {} } },
            else => Error.CommReadZeroLenInNonVoidTag,
        };
    }
    switch (tag) {
        .lightning_get_ctrlconn,
        .lightning_reset,
        .ping,
        .pong,
        .poweroff,
        .standby,
        .wakeup,
        => unreachable, // handled above
        inline else => |t| {
            const bytes = try allocator.alloc(u8, len);
            defer allocator.free(bytes);
            try reader.readNoEof(bytes);

            var arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer {
                arena.deinit();
                allocator.destroy(arena);
            }
            const jopt = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_always };
            const v = try json.parseFromSliceLeaky(std.meta.TagPayload(Message, t), arena.allocator(), bytes, jopt);
            const parsed = ParsedMessage{
                .arena = arena,
                .value = @unionInit(Message, @tagName(t), v),
            };
            return parsed;
        },
    }
}

/// outputs the message msg using writer.
/// all allocated resources are freed upon return.
pub fn write(allocator: mem.Allocator, writer: anytype, msg: Message) !void {
    var data = types.ByteArrayList.init(allocator);
    defer data.deinit();
    switch (msg) {
        .ping, .pong, .poweroff, .standby, .wakeup => {}, // zero length payload
        .wifi_connect => try json.stringify(msg.wifi_connect, .{}, data.writer()),
        .network_report => try json.stringify(msg.network_report, .{}, data.writer()),
        .get_network_report => try json.stringify(msg.get_network_report, .{}, data.writer()),
        .poweroff_progress => try json.stringify(msg.poweroff_progress, .{}, data.writer()),
        .onchain_report => try json.stringify(msg.onchain_report, .{}, data.writer()),
        .lightning_report => try json.stringify(msg.lightning_report, .{}, data.writer()),
        .lightning_error => try json.stringify(msg.lightning_error, .{}, data.writer()),
        .lightning_genseed => try json.stringify(msg.lightning_genseed, .{}, data.writer()),
        .lightning_genseed_result => try json.stringify(msg.lightning_genseed_result, .{}, data.writer()),
        .lightning_init_wallet => try json.stringify(msg.lightning_init_wallet, .{}, data.writer()),
        .lightning_get_ctrlconn => {}, // zero length payload
        .lightning_ctrlconn => try json.stringify(msg.lightning_ctrlconn, .{}, data.writer()),
        .lightning_reset => {}, // zero length payload
        .switch_sysupdates => try json.stringify(msg.switch_sysupdates, .{}, data.writer()),
        .set_nodename => try json.stringify(msg.set_nodename, .{}, data.writer()),
        .settings => try json.stringify(msg.settings, .{}, data.writer()),
        .unlock_screen => try json.stringify(msg.unlock_screen, .{}, data.writer()),
        .screen_unlock_result => try json.stringify(msg.screen_unlock_result, .{}, data.writer()),
        .slock_set_pincode => try json.stringify(msg.slock_set_pincode, .{}, data.writer()),
    }
    if (data.items.len > std.math.maxInt(u64)) {
        return Error.CommWriteTooLarge;
    }

    try writer.writeInt(u16, @intFromEnum(msg), .little);
    try writer.writeInt(u64, data.items.len, .little);
    try writer.writeAll(data.items);
}

// TODO: use fifo
//
//    var buf = std.fifo.LinearFifo(u8, .Dynamic).init(t.allocator);
//    defer buf.deinit();
//    const w = buf.writer();
//    const r = buf.reader();
//    try w.writeAll("hello there");
//
//    var b: [100]u8 = undefined;
//    var n = try r.readAll(&b);
//    try t.expectEqualStrings("hello there", b[0..n]);
//
//    try w.writeAll("once more");
//    n = try r.readAll(&b);
//    try t.expectEqualStrings("once more2", b[0..n]);

test "read" {
    const t = std.testing;

    var data = std.ArrayList(u8).init(t.allocator);
    defer data.deinit();
    const msg = Message{ .wifi_connect = .{ .ssid = "hello", .password = "world" } };
    try json.stringify(msg.wifi_connect, .{}, data.writer());

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    try buf.writer().writeInt(u16, @intFromEnum(msg), .little);
    try buf.writer().writeInt(u64, data.items.len, .little);
    try buf.writer().writeAll(data.items);

    var bs = std.io.fixedBufferStream(buf.items);
    const res = try read(t.allocator, bs.reader());
    defer res.deinit();

    try t.expectEqualStrings(msg.wifi_connect.ssid, res.value.wifi_connect.ssid);
    try t.expectEqualStrings(msg.wifi_connect.password, res.value.wifi_connect.password);
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
    try js.writer().writeInt(u16, @intFromEnum(msg), .little);
    try js.writer().writeInt(u64, payload.len, .little);
    try js.appendSlice(payload);

    try t.expectEqualStrings(js.items, buf.items);
}

test "write enum" {
    const t = std.testing;

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    const msg = Message{ .switch_sysupdates = .edge };
    try write(t.allocator, buf.writer(), msg);

    const payload = "\"edge\"";
    var js = std.ArrayList(u8).init(t.allocator);
    defer js.deinit();
    try js.writer().writeInt(u16, @intFromEnum(msg), .little);
    try js.writer().writeInt(u64, payload.len, .little);
    try js.appendSlice(payload);

    try t.expectEqualStrings(js.items, buf.items);
}

test "write/read void tags" {
    const t = std.testing;

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();

    const msg = [_]Message{
        Message.lightning_get_ctrlconn,
        Message.lightning_reset,
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
        res.deinit(); // noop due to void type
        try t.expectEqual(m, res.value);
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
        defer res.deinit();
        try t.expectEqual(@as(MessageTag, m), @as(MessageTag, res.value));
    }
}
