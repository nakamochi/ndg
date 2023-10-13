//! lnd lightning HTTP client and utility functions.

const std = @import("std");
const base64enc = std.base64.standard.Encoder;

const types = @import("types.zig");

/// safe for concurrent use as long as Client.allocator is.
pub const Client = struct {
    allocator: std.mem.Allocator,
    hostname: []const u8 = "localhost",
    port: u16 = 10010,
    apibase: []const u8, // https://localhost:10010
    macaroon: struct {
        readonly: ?[]const u8,
        admin: ?[]const u8,
    },
    httpClient: std.http.Client,

    pub const Error = error{
        LndHttpMissingMacaroon,
        LndHttpBadStatusCode,
        LndPayloadWriteFail,
    };

    pub const ApiMethod = enum {
        // no auth methods
        genseed, // generate a new wallet seed; non-committing
        walletstatus, // server/wallet status
        initwallet, // commit a seed and create a node wallet
        unlockwallet, // required after successfull initwallet
        // read-only
        feereport, // fees of all active channels
        getinfo, // general host node info
        getnetworkinfo, // visible graph info
        listchannels, // active channels
        pendingchannels, // pending open/close channels
        walletbalance, // onchain balance
        // fwdinghistory, getchaninfo, getnodeinfo
        // watchtower: getinfo, stats, list, add, remove

        fn apipath(self: @This()) []const u8 {
            return switch (self) {
                .feereport => "v1/fees",
                .genseed => "v1/genseed",
                .getinfo => "v1/getinfo",
                .getnetworkinfo => "v1/graph/info",
                .initwallet => "v1/initwallet",
                .listchannels => "v1/channels",
                .pendingchannels => "v1/channels/pending",
                .unlockwallet => "v1/unlockwallet",
                .walletbalance => "v1/balance/blockchain",
                .walletstatus => "v1/state",
            };
        }
    };

    pub fn MethodArgs(comptime m: ApiMethod) type {
        return switch (m) {
            .initwallet => struct {
                unlock_password: []const u8, // min 8 bytes
                mnemonic: []const []const u8, // 24 words
                passphrase: ?[]const u8 = null,
                // TODO: restore an existing wallet:
                //recovery_window: i32 = 0, // applies to each branch of BIP44 derivation path
                //channel_backups
            },
            .unlockwallet => struct {
                unlock_password: []const u8, // from initwallet
                // TODO: restore an existing wallet:
                //recovery_window: i32 = 0, // applies to each branch of BIP44 derivation path
                //channel_backups
            },
            .listchannels => struct {
                status: ?enum { active, inactive } = null,
                advert: ?enum { public, private } = null,
                peer: ?[]const u8 = null, // hex pubkey; filter out non-matching peers
                peer_alias_lookup: bool, // performance penalty if set to true
            },
            else => void,
        };
    }

    pub fn ResultValue(comptime m: ApiMethod) type {
        return switch (m) {
            .feereport => FeeReport,
            .genseed => GeneratedSeed,
            .getinfo => LndInfo,
            .getnetworkinfo => NetworkInfo,
            .initwallet => InitedWallet,
            .listchannels => ChannelsList,
            .pendingchannels => PendingList,
            .unlockwallet => struct {},
            .walletbalance => WalletBalance,
            .walletstatus => WalletStatus,
        };
    }

    pub const InitOpt = struct {
        allocator: std.mem.Allocator,
        hostname: []const u8 = "localhost", // must be present in tlscert_path SANs
        port: u16 = 10010, // HTTP API port
        tlscert_path: []const u8, // must contain the hostname in SANs
        macaroon_ro_path: ?[]const u8 = null, // readonly macaroon path
        macaroon_admin_path: ?[]const u8 = null, // required only for requests mutating lnd state
    };

    /// opt slices are dup'ed and need not be kept alive.
    /// must deinit when done.
    pub fn init(opt: InitOpt) !Client {
        var ca = std.crypto.Certificate.Bundle{}; // deinit'ed by http.Client.deinit
        try ca.addCertsFromFilePathAbsolute(opt.allocator, opt.tlscert_path);
        errdefer ca.deinit(opt.allocator);
        const mac_ro: ?[]const u8 = if (opt.macaroon_ro_path) |p| try readMacaroonOrNull(opt.allocator, p) else null;
        errdefer if (mac_ro) |v| opt.allocator.free(v);
        const mac_admin: ?[]const u8 = if (opt.macaroon_admin_path) |p| try readMacaroonOrNull(opt.allocator, p) else null;
        errdefer if (mac_admin) |v| opt.allocator.free(v);
        const apibase = try std.fmt.allocPrint(opt.allocator, "https://{s}:{d}", .{ opt.hostname, opt.port });
        errdefer opt.allocator.free(apibase);
        return .{
            .allocator = opt.allocator,
            .apibase = apibase,
            .macaroon = .{ .readonly = mac_ro, .admin = mac_admin },
            .httpClient = std.http.Client{
                .allocator = opt.allocator,
                .ca_bundle = ca,
                .next_https_rescan_certs = false, // use only the provided CA bundle above
            },
        };
    }

    pub fn deinit(self: *Client) void {
        self.httpClient.deinit();
        self.allocator.free(self.apibase);
        if (self.macaroon.readonly) |ro| self.allocator.free(ro);
        if (self.macaroon.admin) |a| self.allocator.free(a);
    }

    pub fn Result(comptime m: ApiMethod) type {
        return if (@TypeOf(ResultValue(m)) == void) void else types.Deinitable(ResultValue(m));
    }

    pub fn call(self: *Client, comptime apimethod: ApiMethod, args: MethodArgs(apimethod)) !Result(apimethod) {
        const formatted = try self.formatreq(apimethod, args);
        defer formatted.deinit();
        const reqinfo = formatted.value;
        const opt = std.http.Client.Options{ .handle_redirects = false }; // no redirects in REST API
        var req = try self.httpClient.request(reqinfo.httpmethod, reqinfo.url, reqinfo.headers, opt);
        defer req.deinit();
        if (reqinfo.payload) |p| {
            req.transfer_encoding = .{ .content_length = p.len };
        }

        try req.start();
        if (reqinfo.payload) |p| {
            req.writer().writeAll(p) catch return Error.LndPayloadWriteFail;
            try req.finish();
        }
        try req.wait();
        if (req.response.status.class() != .success) {
            // a structured error reporting in lnd is in a less than desirable state.
            // https://github.com/lightningnetwork/lnd/issues/5586
            // TODO: return a more detailed error when the upstream improves.
            return Error.LndHttpBadStatusCode;
        }
        if (@TypeOf(Result(apimethod)) == void) {
            return; // void response; need no json parsing
        }

        const body = try req.reader().readAllAlloc(self.allocator, 1 << 20); // 1Mb should be enough for all response types
        defer self.allocator.free(body);
        var res = try Result(apimethod).init(self.allocator);
        errdefer res.deinit();
        res.value = try std.json.parseFromSliceLeaky(ResultValue(apimethod), res.arena.allocator(), body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        return res;
    }

    const HttpReqInfo = struct {
        httpmethod: std.http.Method,
        url: std.Uri,
        headers: std.http.Headers,
        payload: ?[]const u8,
    };

    fn formatreq(self: Client, comptime apimethod: ApiMethod, args: MethodArgs(apimethod)) !types.Deinitable(HttpReqInfo) {
        const authHeaderName = "grpc-metadata-macaroon";
        var reqinfo = try types.Deinitable(HttpReqInfo).init(self.allocator);
        errdefer reqinfo.deinit();
        const arena = reqinfo.arena.allocator();
        reqinfo.value = switch (apimethod) {
            .genseed, .walletstatus => |m| .{
                .httpmethod = .GET,
                .url = try std.Uri.parse(try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.apibase, m.apipath() })),
                .headers = std.http.Headers{ .allocator = arena },
                .payload = null,
            },
            .initwallet => |m| blk: {
                const payload = p: {
                    var params: struct {
                        wallet_password: []const u8, // base64
                        cipher_seed_mnemonic: []const []const u8,
                        aezeed_passphrase: ?[]const u8 = null, // base64
                    } = .{
                        .wallet_password = try base64EncodeAlloc(arena, args.unlock_password),
                        .cipher_seed_mnemonic = args.mnemonic,
                        .aezeed_passphrase = if (args.passphrase) |p| try base64EncodeAlloc(arena, p) else null,
                    };
                    var buf = std.ArrayList(u8).init(arena);
                    try std.json.stringify(params, .{ .emit_null_optional_fields = false }, buf.writer());
                    break :p try buf.toOwnedSlice();
                };
                break :blk .{
                    .httpmethod = .POST,
                    .url = try std.Uri.parse(try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.apibase, m.apipath() })),
                    .headers = std.http.Headers{ .allocator = arena },
                    .payload = payload,
                };
            },
            .unlockwallet => |m| blk: {
                const payload = p: {
                    var params: struct {
                        wallet_password: []const u8, // base64
                    } = .{
                        .wallet_password = try base64EncodeAlloc(arena, args.unlock_password),
                    };
                    var buf = std.ArrayList(u8).init(arena);
                    try std.json.stringify(params, .{ .emit_null_optional_fields = false }, buf.writer());
                    break :p try buf.toOwnedSlice();
                };
                break :blk .{
                    .httpmethod = .POST,
                    .url = try std.Uri.parse(try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.apibase, m.apipath() })),
                    .headers = std.http.Headers{ .allocator = arena },
                    .payload = payload,
                };
            },
            .feereport, .getinfo, .getnetworkinfo, .pendingchannels, .walletbalance => |m| .{
                .httpmethod = .GET,
                .url = try std.Uri.parse(try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.apibase, m.apipath() })),
                .headers = blk: {
                    if (self.macaroon.readonly == null) {
                        return Error.LndHttpMissingMacaroon;
                    }
                    var h = std.http.Headers{ .allocator = arena };
                    try h.append(authHeaderName, self.macaroon.readonly.?);
                    break :blk h;
                },
                .payload = null,
            },
            .listchannels => .{
                .httpmethod = .GET,
                .url = blk: {
                    var buf = std.ArrayList(u8).init(arena); // free'ed when arena is deinit'ed, formatreq call site
                    const w = buf.writer();
                    try std.fmt.format(w, "{s}/v1/channels?peer_alias_lookup={}", .{ self.apibase, args.peer_alias_lookup });
                    if (args.status) |v| switch (v) {
                        .active => try w.writeAll("&active_only=true"),
                        .inactive => try w.writeAll("&inactive_only=true"),
                    };
                    if (args.advert) |v| switch (v) {
                        .public => try w.writeAll("&public_only=true"),
                        .private => try w.writeAll("&private_only=true"),
                    };
                    if (args.peer) |v| {
                        // TODO: sanitize; Uri.writeEscapedQuery(w, q);
                        try std.fmt.format(w, "&peer={s}", .{v});
                    }
                    break :blk try std.Uri.parse(buf.items); // uri point to the original buf
                },
                .headers = blk: {
                    if (self.macaroon.readonly == null) {
                        return Error.LndHttpMissingMacaroon;
                    }
                    var h = std.http.Headers{ .allocator = arena };
                    try h.append(authHeaderName, self.macaroon.readonly.?);
                    break :blk h;
                },
                .payload = null,
            },
        };
        return reqinfo;
    }

    /// returns null if file not found.
    /// callers own returned value.
    fn readMacaroonOrNull(gpa: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();
        const raw = try file.readToEndAlloc(gpa, 1024);
        defer gpa.free(raw);
        const hex = try std.fmt.allocPrint(gpa, "{}", .{std.fmt.fmtSliceHexLower(raw)});
        return hex;
    }

    fn base64EncodeAlloc(gpa: std.mem.Allocator, v: []const u8) ![]const u8 {
        var buf = try gpa.alloc(u8, base64enc.calcSize(v.len));
        return base64enc.encode(buf, v); // always returns a slice of buf.len
    }
};

/// general info and stats around the host lnd.
pub const LndInfo = struct {
    version: []const u8,
    identity_pubkey: []const u8,
    alias: []const u8,
    color: []const u8,
    num_pending_channels: u32,
    num_active_channels: u32,
    num_inactive_channels: u32,
    num_peers: u32,
    block_height: u32,
    block_hash: []const u8,
    synced_to_chain: bool,
    synced_to_graph: bool,
    chains: []const struct {
        chain: []const u8,
        network: []const u8,
    },
    uris: []const []const u8,
    // best_header_timestamp and features?
};

pub const NetworkInfo = struct {
    graph_diameter: u32,
    avg_out_degree: f32,
    max_out_degree: u32,
    num_nodes: u32,
    num_channels: u32,
    total_network_capacity: i64,
    avg_channel_size: f64,
    min_channel_size: i64,
    max_channel_size: i64,
    median_channel_size_sat: i64,
    num_zombie_chans: u64,
};

pub const FeeReport = struct {
    day_fee_sum: u64,
    week_fee_sum: u64,
    month_fee_sum: u64,
    channel_fees: []struct {
        chan_id: []const u8,
        channel_point: []const u8,
        base_fee_msat: i64,
        fee_per_mil: i64, // per milli-satoshis, in millionths of satoshi
        fee_rate: f64, // fee_per_mil/10^6, in milli-satoshis
    },
};

pub const ChannelsList = struct {
    channels: []struct {
        chan_id: []const u8, // [0..3]: height, [3..6]: index within block, [6..8]: chan out idx
        remote_pubkey: []const u8,
        channel_point: []const u8, // txid:index of the funding tx
        capacity: i64,
        local_balance: i64,
        remote_balance: i64,
        unsettled_balance: i64,
        total_satoshis_sent: i64,
        total_satoshis_received: i64,
        active: bool,
        private: bool,
        initiator: bool,
        peer_alias: []const u8,
        // https://github.com/lightningnetwork/lnd/blob/d930dcec/channeldb/channel.go#L616-L644
        //chan_status_flag: ChannelStatus
        //local_constraints, remote_constraints, pending_htlcs
    },
};

pub const PendingList = struct {
    total_limbo_balance: i64, // balance in satoshis encumbered in pending channels
    pending_open_channels: []struct {
        channel: PendingChannel,
        commit_fee: i64,
    },
    pending_force_closing_channels: []struct {
        channel: PendingChannel,
        closing_txid: []const u8,
        limbo_balance: i64,
        maturity_height: u32,
        blocks_til_maturity: i32, // negative indicates n blocks since maturity
        recovered_balance: i64, // total funds successfully recovered from this channel
        // pending_htlcs, anchor
    },
    waiting_close_channels: []struct { // waiting for closing tx confirmation
        channel: PendingChannel,
        limbo_balance: i64,
        closing_txid: []const u8,
        // commitments?
    },
};

pub const PendingChannel = struct {
    remote_node_pub: []const u8,
    channel_point: []const u8,
    capacity: i64,
    local_balance: i64,
    remote_balance: i64,
    private: bool,
    // local_chan_reserve_sat, remote_chan_reserve_sat, initiator, chan_status_flags, memo
};

/// on-chain balance, in satoshis.
pub const WalletBalance = struct {
    total_balance: i64,
    confirmed_balance: i64,
    unconfirmed_balance: i64,
    locked_balance: i64, // output leases
    reserved_balance_anchor_chan: i64, // for fee bumps
};

pub const WalletStatus = struct {
    state: enum(u8) {
        NON_EXISTING = 0, // uninitialized
        LOCKED = 1, // requires password to unlocked
        UNLOCKED = 2, // RPC isn't ready
        RPC_ACTIVE = 3, // lnd server active but not ready for calls yet
        SERVER_ACTIVE = 4, // ready to accept calls
        WAITING_TO_START = 255,
    },
};

/// https://lightning.engineering/api-docs/api/lnd/wallet-unlocker/gen-seed
pub const GeneratedSeed = struct {
    cipher_seed_mnemonic: []const []const u8, // 24 words aezeed
};

/// https://lightning.engineering/api-docs/api/lnd/wallet-unlocker/init-wallet
pub const InitedWallet = struct {
    admin_macaroon: []const u8, // base64?
};
