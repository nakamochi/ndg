//! a bitcoin core RPC client.

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Atomic = std.atomic.Atomic;
const base64enc = std.base64.standard.Encoder;

const types = @import("types.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    cookiepath: []const u8,
    addr: []const u8 = "127.0.0.1",
    port: u16 = 8332,

    // each request gets a new ID with a value of reqid.fetchAdd(1, .Monotonic)
    reqid: Atomic(u64) = Atomic(u64).init(1),

    pub const Method = enum {
        getblockchaininfo,
        getblockhash,
        getmempoolinfo,
        getnetworkinfo,
    };

    pub const RpcError = error{
        // json-rpc 2.0
        RpcInvalidRequest,
        RpcMethodNotFound,
        RpcInvalidParams,
        RpcInternalError,
        RpcParseError,
        // general purpose errors
        RpcMiscError,
        RpcTypeError,
        RpcInvalidAddressOrKey,
        RpcOutOfMemory,
        RpcInvalidParameter,
        RpcDatabaseError,
        RpcDeserializationError,
        RpcVerifyError,
        RpcVerifyRejected,
        RpcVerifyAlreadyInChain,
        RpcInWarmup,
        RpcMethodDeprecated,
        // p2p client errors
        RpcClientNotConnected,
        RpcClientInInitialDownload,
        RpcClientNodeAlreadyAdded,
        RpcClientNodeNotAdded,
        RpcClientNodeNotConnected,
        RpcClientInvalidIpOrSubnet,
        RpcClientP2pDisabled,
        RpcClientNodeCapacityReached,
        // chain errors
        RpcClientMempoolDisabled,
    };

    pub fn Result(comptime m: Method) type {
        return types.Deinitable(ResultValue(m));
    }

    pub fn ResultValue(comptime m: Method) type {
        return switch (m) {
            .getblockchaininfo => BlockchainInfo,
            .getblockhash => []const u8,
            .getmempoolinfo => MempoolInfo,
            .getnetworkinfo => NetworkInfo,
        };
    }

    pub fn MethodArgs(comptime m: Method) type {
        return switch (m) {
            .getblockchaininfo, .getmempoolinfo, .getnetworkinfo => void,
            .getblockhash => struct { height: u64 },
        };
    }

    fn RpcRequest(comptime m: Method) type {
        return struct {
            jsonrpc: []const u8 = "1.0",
            id: u64,
            method: []const u8,
            params: MethodArgs(m),
        };
    }

    fn RpcResponse(comptime m: Method) type {
        return struct {
            id: u64,
            result: ?ResultValue(m),
            @"error": ?struct {
                code: isize,
                //message: ?[]const u8, // no use for it atm
            },
        };
    }

    /// makes an RPC call to the addr:port endpoint.
    /// the returned value must be deinit'ed when done.
    pub fn call(self: *Client, comptime method: Method, args: MethodArgs(method)) !Result(method) {
        const addrport = try std.net.Address.resolveIp(self.addr, self.port);
        const reqbytes = try self.formatreq(method, args);
        defer self.allocator.free(reqbytes);

        // connect and send the request
        const stream = try std.net.tcpConnectToAddress(addrport);
        defer stream.close();
        const reader = stream.reader();
        _ = try stream.writer().writeAll(reqbytes);

        // read and parse the response
        try skipResponseHeaders(reader, 4096);
        const body = try reader.readAllAlloc(self.allocator, 1 << 20); // 1Mb should be enough for all response types
        defer self.allocator.free(body);
        return self.parseResponse(method, body);
    }

    /// reads all response headers, at most `limit` bytes, and returns the index
    /// at which response body starts or error.EndOfStream.
    /// single header length must be at most `limit` or 1024, whichever is smaller.
    fn skipResponseHeaders(r: anytype, comptime limit: usize) !void {
        var n: usize = 0;
        var buf: [@min(1024, limit)]u8 = undefined;
        while (true) {
            const slice = try r.readUntilDelimiter(&buf, '\n');
            n += slice.len + 1; // delimiter is not included in the slice
            if (n > limit) {
                return error.StreamTooLong;
            }
            if (slice.len == 0 or (slice.len == 1 and slice[0] == '\r')) {
                return;
            }
        }
    }

    fn parseResponse(self: Client, comptime m: Method, b: []const u8) !Result(m) {
        var resp = try types.Deinitable(RpcResponse(m)).init(self.allocator);
        errdefer resp.deinit();
        resp.value = try std.json.parseFromSliceLeaky(RpcResponse(m), self.allocator, b, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (resp.value.@"error") |errfield| {
            return rpcErrorFromCode(errfield.code) orelse error.UnknownError;
        }
        if (resp.value.result == null) {
            return error.NullResult;
        }
        return .{ .value = resp.value.result.?, .arena = resp.arena };
    }

    fn formatreq(self: *Client, comptime m: Method, args: MethodArgs(m)) ![]const u8 {
        const req = RpcRequest(m){
            .id = self.reqid.fetchAdd(1, .Monotonic),
            .method = @tagName(m),
            .params = args,
        };
        var jreq = std.ArrayList(u8).init(self.allocator);
        defer jreq.deinit();
        try std.json.stringify(req, .{}, jreq.writer());

        const auth = try self.getAuthBase64();
        defer self.allocator.free(auth);

        var bytes = std.ArrayList(u8).init(self.allocator);
        const w = bytes.writer();
        try w.writeAll("POST / HTTP/1.0\r\n");
        //try w.writeAll("Host: 127.0.0.1\n", .{});
        try w.writeAll("Connection: close\r\n");
        try w.print("Authorization: Basic {s}\r\n", .{auth});
        try w.writeAll("Accept: application/json-rpc\r\n");
        try w.writeAll("Content-Type: application/json-rpc\r\n");
        try w.print("Content-Length: {d}\r\n", .{jreq.items.len});
        try w.writeAll("\r\n");
        try w.writeAll(jreq.items);
        return try bytes.toOwnedSlice();
    }

    fn getAuthBase64(self: Client) ![]const u8 {
        const file = try std.fs.openFileAbsolute(self.cookiepath, .{ .mode = .read_only });
        defer file.close();
        const cookie = try file.readToEndAlloc(self.allocator, 1024);
        defer self.allocator.free(cookie);
        var auth = try self.allocator.alloc(u8, base64enc.calcSize(cookie.len));
        return base64enc.encode(auth, cookie);
    }

    // taken from bitcoind source code.
    // see https://github.com/bitcoin/bitcoin/blob/64440bb73/src/rpc/protocol.h#L23
    fn rpcErrorFromCode(code: isize) ?RpcError {
        return switch (code) {
            // json-rpc 2.0
            -32600 => error.RpcInvalidRequest,
            -32601 => error.RpcMethodNotFound,
            -32602 => error.RpcInvalidParams,
            -32603 => error.RpcInternalError,
            -32700 => error.RpcParseError,
            // general purpose errors
            -1 => error.RpcMiscError,
            -3 => error.RpcTypeError,
            -5 => error.RpcInvalidAddressOrKey,
            -7 => error.RpcOutOfMemory,
            -8 => error.RpcInvalidParameter,
            -20 => error.RpcDatabaseError,
            -22 => error.RpcDeserializationError,
            -25 => error.RpcVerifyError,
            -26 => error.RpcVerifyRejected,
            -27 => error.RpcVerifyAlreadyInChain,
            -28 => error.RpcInWarmup,
            -32 => error.RpcMethodDeprecated,
            // p2p client errors
            -9 => error.RpcClientNotConnected,
            -10 => error.RpcClientInInitialDownload,
            -23 => error.RpcClientNodeAlreadyAdded,
            -24 => error.RpcClientNodeNotAdded,
            -29 => error.RpcClientNodeNotConnected,
            -30 => error.RpcClientInvalidIpOrSubnet,
            -31 => error.RpcClientP2pDisabled,
            -34 => error.RpcClientNodeCapacityReached,
            // chain errors
            -33 => error.RpcClientMempoolDisabled,
            else => null,
        };
    }
};

pub const BlockchainInfo = struct {
    chain: []const u8,
    blocks: u64,
    headers: u64,
    bestblockhash: []const u8,
    difficulty: f64,
    time: u64, // block time, unix epoch
    mediantime: u64, // median block time, unix epoch
    verificationprogress: f32, // estimate in [0..1]
    initialblockdownload: bool,
    size_on_disk: u64,
    pruned: bool,
    //pruneheight: ?u64, // present if pruning is enabled
    //automatic_prunning: ?bool, // present if pruning is enabled
    //prune_target_size: ?u64, // present if automatic is enabled
    warnings: []const u8,
};

pub const MempoolInfo = struct {
    loaded: bool, // whether the mempool is fully loaded
    size: usize, // tx count
    bytes: u64, //  sum of all virtual transaction sizes as per BIP-141 (discounted witness data)
    usage: u64, //  total memory usage
    total_fee: f32, //  total fees in BTC ignoring modified fees through prioritisetransaction
    maxmempool: u64, //  memory usage cap, in bytes
    mempoolminfee: f32, //  min fee rate in BTC/kvB for tx to be accepted
    minrelaytxfee: f32, // current min relay fee rate
    incrementalrelayfee: f32, // min fee rate increment for replacement, in BTC/kvB
    unbroadcastcount: u64, // number of transactions that haven't passed initial broadcast yet
    fullrbf: bool, // whether the mempool accepts RBF without replaceability signaling inspection
};

pub const NetworkInfo = struct {
    version: u32,
    subversion: []const u8,
    protocolversion: u32,
    connections: u16, // in + out
    connections_in: u16,
    connections_out: u16,
    networkactive: bool,
    networks: []struct {
        name: []const u8, // ipv4, ipv6, onion, i2p, cjdns
        limited: bool, // whether this network is limited with -onlynet flag
        reachable: bool,
    },
    relayfee: f32, // min rate, in BTC/kvB
    incrementalfee: f32, // min rate increment for RBF in BTC/vkB
    localaddresses: []struct {
        address: []const u8,
        port: u16,
        score: i16,
    },
    warnings: []const u8,
};
