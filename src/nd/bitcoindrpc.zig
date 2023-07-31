const std = @import("std");
const Atomic = std.atomic.Atomic;
const base64enc = std.base64.standard.Encoder;

pub const Client = struct {
    allocator: std.mem.Allocator,
    cookiepath: []const u8,
    addr: []const u8 = "127.0.0.1",
    port: u16 = 8332,

    // each request gets a new ID with a value of reqid.fetchAdd(1, .Monotonic)
    reqid: Atomic(u64) = Atomic(u64).init(1),

    pub const MethodTag = enum {
        getblockhash,
        getblockchaininfo,
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

    /// makes an RPC call to the addr:port endpoint.
    /// the returned value always has a .result field of type ResultType(method);
    /// all other fields are for internal use.
    ///
    /// callers must free resources allocated for the retuned value using its `free` function.
    pub fn call(self: *Client, comptime method: MethodTag, args: MethodArgs(method)) !CallRetType(method) {
        const addrport = try std.net.Address.resolveIp(self.addr, self.port);
        const reqbytes = try self.formatreq(method, args);
        defer self.allocator.free(reqbytes);

        // connect and send the request
        const stream = try std.net.tcpConnectToAddress(addrport);
        errdefer stream.close();
        const reader = stream.reader();
        _ = try stream.writer().writeAll(reqbytes);

        // read response
        var buf: [512]u8 = undefined;
        var resbytes = std.ArrayList(u8).init(self.allocator);
        defer resbytes.deinit();
        while (true) {
            // TODO: use LimitedReader
            const n = try reader.read(&buf);
            if (n == 0) {
                break; // EOS
            }
            try resbytes.appendSlice(buf[0..n]);
        }

        // search for end of headers in the response
        var last_byte: u8 = 0;
        var idx: usize = 0;
        for (resbytes.items) |v, i| {
            if (v == '\r') {
                continue;
            }
            if (v == '\n' and last_byte == '\n') {
                idx = i + 1;
                break;
            }
            last_byte = v;
        }
        if (idx == 0 or idx >= resbytes.items.len) {
            return error.NoBodyInResponse;
        }

        // parse the response body and return its .result field or an error.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        var jstream = std.json.TokenStream.init(resbytes.items[idx..]);
        const jopt = std.json.ParseOptions{ .allocator = arena, .ignore_unknown_fields = true };
        const Typ = RpcRespType(method);
        @setEvalBranchQuota(2000); // std/json.zig:1520:24: error: evaluation exceeded 1000 backwards branches
        const resp = try std.json.parse(Typ, &jstream, jopt);
        if (resp.@"error") |errfield| {
            return rpcErrorFromCode(errfield.code) orelse error.UnknownError;
        }
        if (resp.result == null) {
            return error.NullResult;
        }
        return .{ .result = &resp.result.?, .arena = arena_state };
    }

    fn CallRetType(comptime method: MethodTag) type {
        return struct {
            result: *const ResultType(method),
            arena: std.heap.ArenaAllocator,

            pub fn free(self: @This()) void {
                self.arena.deinit();
            }
        };
    }

    pub fn MethodArgs(comptime m: MethodTag) type {
        return switch (m) {
            .getblockchaininfo, .getnetworkinfo => void,
            .getblockhash => struct { height: u64 },
        };
    }
    pub fn ResultType(comptime m: MethodTag) type {
        return switch (m) {
            .getblockchaininfo => BlockchainInfo,
            .getnetworkinfo => NetworkInfo,
            .getblockhash => []const u8,
        };
    }

    fn RpcReqType(comptime m: MethodTag) type {
        return struct {
            jsonrpc: []const u8 = "1.0",
            id: u64,
            method: []const u8,
            params: MethodArgs(m),
        };
    }

    fn RpcRespType(comptime m: MethodTag) type {
        return struct {
            id: u64,
            result: ?ResultType(m), // keep field name or modify free fn in CallRetType
            @"error": ?struct {
                code: isize,
                //message: []const u8, // no use for this atm
            },
        };
    }

    fn formatreq(self: *Client, comptime m: MethodTag, args: MethodArgs(m)) ![]const u8 {
        const req = RpcReqType(m){
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
        try w.print("Content-Length: {d}\r\n\r\n", .{jreq.items.len});
        try w.writeAll(jreq.items);
        return bytes.toOwnedSlice();
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
    //headers: u64,
    bestblockhash: []const u8,
    //difficulty: f64,
    time: u64, // block time, unix epoch
    //mediantime: u64, // median block time, unix epoch
    verificationprogress: f32, // estimate in [0..1]
    initialblockdownload: bool,
    size_on_disk: u64,
    pruned: bool,
    //pruneheight: ?u64, // present if pruning is enabled
    //automatic_prunning: ?bool, // present if pruning is enabled
    //prune_target_size: ?u64, // present if automatic is enabled
    warnings: []const u8,
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
