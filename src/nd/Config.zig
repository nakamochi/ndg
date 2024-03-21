//! ndg persistent configuration, loaded from and stored to disk in JSON format.
//! the structure is defined in `Data`.

const std = @import("std");
const lightning = @import("../lightning.zig");
const types = @import("../types.zig");
const sys = @import("../sys.zig");

const logger = std.log.scoped(.config);

// default values. these should match what's in the sysupdates repo.
const SYSUPDATES_CRON_SCRIPT_PATH = "/etc/cron.hourly/sysupdate";
/// must be the same as https://git.qcode.ch/nakamochi/sysupdates/src/branch/master/update.sh
const SYSUPDATES_RUN_SCRIPT_NAME = "update.sh";
const SYSUPDATES_RUN_SCRIPT_PATH = "/ssd/sysupdates/" ++ SYSUPDATES_RUN_SCRIPT_NAME;

/// must be the same as https://git.qcode.ch/nakamochi/sysupdates/src/branch/master/lnd
pub const LND_OS_USER = "lnd";
pub const LND_DATA_DIR = "/ssd/lnd/data";
pub const LND_LOG_DIR = "/ssd/lnd/logs";
pub const LND_HOMEDIR = "/home/lnd";
pub const LND_CONF_PATH = LND_HOMEDIR ++ "/lnd.mainnet.conf";
pub const LND_TLSKEY_PATH = LND_HOMEDIR ++ "/.lnd/tls.key";
pub const LND_TLSCERT_PATH = LND_HOMEDIR ++ "/.lnd/tls.cert";
pub const LND_WALLETUNLOCK_PATH = LND_HOMEDIR ++ "/walletunlock.txt";
pub const LND_MACAROON_RO_PATH = LND_DATA_DIR ++ "/chain/bitcoin/mainnet/readonly.macaroon";
pub const LND_MACAROON_ADMIN_PATH = LND_DATA_DIR ++ "/chain/bitcoin/mainnet/admin.macaroon";

pub const BITCOIND_CONFIG_PATH = "/home/bitcoind/mainnet.conf";
pub const TOR_DATA_DIR = "/ssd/tor";

arena: *std.heap.ArenaAllocator, // data is allocated here
confpath: []const u8, // fs path to where data is persisted

/// any heap-alloc'ed field values are in `arena.allocator()`.
static: StaticData,
/// guards `data` as well as `static.hostname` when the latter changed using `setHostname`.
mu: std.Thread.RwLock = .{},
data: Data,

/// top struct stored on disk.
/// access with `safeReadOnly` or lock/unlock `mu`.
///
/// for backwards compatibility, all newly introduced fields must have default values.
pub const Data = struct {
    slock: ?struct { // null indicates screenlock is disabled
        bcrypt_hash: []const u8, // std.crypto.bcrypt .phc format
        incorrect_attempts: u8, // reset after each successful unlock
    } = null,
    syschannel: SysupdatesChannel,
    syscronscript: []const u8,
    sysrunscript: []const u8,
};

/// static data is interred at init and never changes except for hostname - see `setHostname`.
pub const StaticData = struct {
    hostname: []const u8, // guarded by self.mu
    lnd_user: ?std.process.UserInfo,
    lnd_tor_hostname: ?[]const u8,
    bitcoind_rpc_pass: ?[]const u8,
};

/// enums must match git branches in https://git.qcode.ch/nakamochi/sysupdates.
pub const SysupdatesChannel = enum {
    master, // stable
    dev, // edge
};

const Config = @This();

/// confpath must outlive returned Config instance.
pub fn init(allocator: std.mem.Allocator, confpath: []const u8) !Config {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    return .{
        .arena = arena,
        .confpath = confpath,
        .data = try initData(arena.allocator(), confpath),
        .static = try inferStaticData(arena.allocator()),
    };
}

pub fn deinit(self: Config) void {
    const allocator = self.arena.child_allocator;
    self.arena.deinit();
    allocator.destroy(self.arena);
}

fn initData(allocator: std.mem.Allocator, filepath: []const u8) !Data {
    const maxsize: usize = 1 << 20; // 1Mb JSON conf file size should be more than enough
    const bytes = std.fs.cwd().readFileAlloc(allocator, filepath, maxsize) catch |err| switch (err) {
        error.FileNotFound => return inferData(),
        else => return err,
    };
    defer allocator.free(bytes);
    const jopt = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    return std.json.parseFromSliceLeaky(Data, allocator, bytes, jopt) catch |err| {
        logger.err("initData: {any}", .{err});
        return error.BadConfigSyntax;
    };
}

fn inferData() Data {
    return .{
        .syschannel = inferSysupdatesChannel(SYSUPDATES_CRON_SCRIPT_PATH),
        .syscronscript = SYSUPDATES_CRON_SCRIPT_PATH,
        .sysrunscript = SYSUPDATES_RUN_SCRIPT_PATH,
    };
}

fn inferSysupdatesChannel(cron_script_path: []const u8) SysupdatesChannel {
    var buf: [1024]u8 = undefined;
    const bytes = std.fs.cwd().readFile(cron_script_path, &buf) catch return .master;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    // looking for "/ssd/sysupdates/update.sh <channel>?" where <channel> may be in quotes
    const needle = SYSUPDATES_RUN_SCRIPT_NAME;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle)) |i| {
            var s = line[i + needle.len ..];
            s = std.mem.trim(u8, s, " \n'\"");
            return std.meta.stringToEnum(SysupdatesChannel, s) orelse .master;
        }
    }
    return .master;
}

fn inferStaticData(allocator: std.mem.Allocator) !StaticData {
    const hostname = try sys.hostname(allocator);
    const lnduser: ?std.process.UserInfo = blk: {
        const uid = std.os.linux.getuid();
        const uinfo = types.getUserInfo(LND_OS_USER) catch break :blk null;
        // assume there's no lnd user if uid is root or same as current process.
        break :blk if (uinfo.uid == 0 or uinfo.uid == uid) null else uinfo;
    };
    return .{
        .hostname = hostname,
        .lnd_user = lnduser,
        .lnd_tor_hostname = inferLndTorHostname(allocator) catch null,
        .bitcoind_rpc_pass = inferBitcoindRpcPass(allocator) catch null,
    };
}

fn inferLndTorHostname(allocator: std.mem.Allocator) ![]const u8 {
    var raw = try std.fs.cwd().readFileAlloc(allocator, TOR_DATA_DIR ++ "/lnd/hostname", 1024);
    const hostname = std.mem.trim(u8, raw, &std.ascii.whitespace);
    logger.info("inferred lnd tor hostname: [{s}]", .{hostname});
    return hostname;
}

fn inferBitcoindRpcPass(allocator: std.mem.Allocator) ![]const u8 {
    // a hack to recover bitcoind rpc password from an original conf template.
    // the password was placed on a separate comment line, preceding another comment
    // line containing "rpcauth.py".
    // TODO: get rid of the hack; do something more robust
    var conf = try std.fs.cwd().readFileAlloc(allocator, BITCOIND_CONFIG_PATH, 1024 * 1024);
    var it = std.mem.tokenizeScalar(u8, conf, '\n');
    var next_is_pass = false;
    while (it.next()) |line| {
        if (next_is_pass) {
            if (!std.mem.startsWith(u8, line, "#")) {
                return error.UninferrableBitcoindRpcPass;
            }
            return std.mem.trim(u8, line[1..], &std.ascii.whitespace);
        }
        if (std.mem.startsWith(u8, line, "#") and std.mem.indexOf(u8, line, "rpcauth.py") != null) {
            next_is_pass = true;
        }
    }
    return error.UninferrableBitcoindRpcPass;
}

/// calls F while holding a readonly lock and passes on F's result as is.
/// F is expected to take `Data` and `StaticData` args.
pub fn safeReadOnly(self: *Config, comptime F: anytype) @typeInfo(@TypeOf(F)).Fn.return_type.? {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return F(self.data, self.static);
}

/// matches the `input` against the hash in `Data.slock.bcrypt_hash` previously set with `setSlockPin`.
/// incrementing `Data.slock.incorrect_attempts` each unsuccessful result.
/// the number of attemps are persisted at `Config.confpath` upon function return.
pub fn verifySlockPin(self: *Config, input: []const u8) !void {
    self.mu.lock();
    defer self.mu.unlock();
    const slock = self.data.slock orelse return;
    defer self.dumpUnguarded() catch |errdump| logger.err("dumpUnguarded: {!}", .{errdump});
    std.crypto.pwhash.bcrypt.strVerify(slock.bcrypt_hash, input, .{}) catch |err| {
        if (err == error.PasswordVerificationFailed) {
            self.data.slock.?.incorrect_attempts += 1;
            return error.IncorrectSlockPin;
        }
        logger.err("bcrypt.strVerify: {!}", .{err});
        return err;
    };
    self.data.slock.?.incorrect_attempts = 0;
}

/// enables or disables screenlock, persistently. null `code` indicates disabled.
/// safe for concurrent use.
pub fn setSlockPin(self: *Config, code: ?[]const u8) !void {
    self.mu.lock();
    defer self.mu.unlock();
    // TODO: free existing slock.bcrypt_hash? it is in arena but still
    if (code) |s| {
        const bcrypt = std.crypto.pwhash.bcrypt;
        const opt: bcrypt.HashOptions = .{
            .params = .{ .rounds_log = 12 },
            .encoding = .phc,
            .silently_truncate_password = false,
        };
        var buf: [bcrypt.hash_length * 2]u8 = undefined;
        const hash = try bcrypt.strHash(s, opt, &buf);
        self.data.slock = .{
            .bcrypt_hash = try self.arena.allocator().dupe(u8, hash),
            .incorrect_attempts = 0,
        };
    } else {
        self.data.slock = null;
    }
    try self.dumpUnguarded();
}

/// used by mutateLndConf to guard concurrent access.
var lndconf_mu: std.Thread.Mutex = .{};

pub const MutateLndConfOpt = struct {
    filepath: ?[]const u8 = null, // lnd conf file name; defaults to LND_CONF_PATH
};

/// allows callers to serialize access to an lnd config file.
pub fn beginMutateLndConf(self: *Config, opt: MutateLndConfOpt) !LndConfMut {
    lndconf_mu.lock();
    errdefer lndconf_mu.unlock();
    const allocator = self.arena.child_allocator;
    const filepath = opt.filepath orelse LND_CONF_PATH;
    return .{
        .lndconf = try lightning.LndConf.load(allocator, filepath),
        .allocator = allocator,
        .filepath = filepath,
        .lnduser = self.static.lnd_user,
        .mu = &lndconf_mu,
    };
}

pub const LndConfMut = struct {
    lndconf: lightning.LndConf,

    allocator: std.mem.Allocator,
    filepath: []const u8,
    lnduser: ?std.process.UserInfo = null,
    mu: *std.Thread.Mutex,

    pub fn persist(self: @This()) !void {
        const file = try std.io.BufferedAtomicFile.create(self.allocator, std.fs.cwd(), self.filepath, .{ .mode = 0o400 });
        defer file.destroy(); // frees resources; does NOT delete the file
        try self.lndconf.dumpWriter(file.writer());
        try file.finish(); // persist the file in the correct location
        // change ownership to that of the lnd sys user
        if (self.lnduser) |user| {
            try chown(self.filepath, user);
        }
    }

    /// relinquish concurrent access guard and resources.
    pub fn finish(self: @This()) void {
        defer self.mu.unlock();
        self.lndconf.deinit();
    }
};

/// stores current `Config.data` to disk, into `Config.confpath`.
pub fn dump(self: *Config) !void {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return self.dumpUnguarded();
}

fn dumpUnguarded(self: Config) !void {
    const allocator = self.arena.child_allocator;
    const opt = .{ .mode = 0o600 };
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), self.confpath, opt);
    defer file.destroy();
    try std.json.stringify(self.data, .{ .whitespace = .indent_2 }, file.writer());
    try file.finish();
}

/// sets hostname to a new name at runtime in both the OS and `Config.static.hostname`.
/// see `sys.setHostname` for `newname` sanitization rules.
/// the name arg must outlive this function call.
/// safe for concurrent use.
pub fn setHostname(self: *Config, newname: []const u8) !void {
    self.mu.lock(); // for self.static.hostname
    defer self.mu.unlock();
    const allocator = self.arena.allocator();

    const dupname = try allocator.dupe(u8, newname);
    errdefer allocator.free(dupname);
    try sys.setHostname(allocator, newname);
    allocator.free(self.static.hostname);
    self.static.hostname = dupname;
}

/// when run is set, executes the update after changing the channel.
/// executing an update may terminate and start a new nd+ngui instance.
pub fn switchSysupdates(self: *Config, chan: SysupdatesChannel, opt: struct { run: bool }) !void {
    self.mu.lock();
    defer self.mu.unlock();

    self.data.syschannel = chan;
    try self.dumpUnguarded();

    try self.genSysupdatesCronScript();
    if (opt.run) {
        try runSysupdates(self.arena.child_allocator, self.data.syscronscript);
    }
}

/// caller must hold self.mu.
fn genSysupdatesCronScript(self: Config) !void {
    if (self.data.sysrunscript.len == 0) {
        return error.NoSysRunScriptPath;
    }
    const allocator = self.arena.child_allocator;
    const opt = .{ .mode = 0o755 };
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), self.data.syscronscript, opt);
    defer file.destroy();

    const script =
        \\#!/bin/sh
        \\exec {[path]s} "{[chan]s}"
    ;
    try std.fmt.format(file.writer(), script, .{
        .path = self.data.sysrunscript,
        .chan = @tagName(self.data.syschannel),
    });
    try file.finish();
}

/// the scriptpath is typically the cronjob script, not a SYSUPDATES_RUN_SCRIPT
/// because the latter requires command args which is what cron script does.
///
/// the caller must serialize this function calls.
fn runSysupdates(allocator: std.mem.Allocator, scriptpath: []const u8) !void {
    const res = try std.ChildProcess.exec(.{ .allocator = allocator, .argv = &.{scriptpath} });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    switch (res.term) {
        .Exited => |code| if (code != 0) {
            logger.err("runSysupdates: {s} exit code = {d}; stderr: {s}", .{ scriptpath, code, res.stderr });
            return error.RunSysupdatesBadExit;
        },
        else => {
            logger.err("runSysupdates: {s} term = {any}", .{ scriptpath, res.term });
            return error.RunSysupdatesBadTerm;
        },
    }
}

/// waits until lnd admin macaroon is readable and returns an lndconnect URL.
/// caller owns returned value.
pub fn lndConnectWaitMacaroonFile(self: Config, allocator: std.mem.Allocator, typ: enum { tor_rpc, tor_http }) ![]const u8 {
    var macaroon: []const u8 = undefined;
    while (true) {
        macaroon = std.fs.cwd().readFileAlloc(allocator, LND_MACAROON_ADMIN_PATH, 2048) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    std.atomic.spinLoopHint();
                    std.time.sleep(1 * std.time.ns_per_s);
                    continue;
                },
                else => return err,
            }
        };
        break;
    }
    defer allocator.free(macaroon);

    const base64enc = std.base64.url_safe_no_pad.Encoder;
    var buf = try allocator.alloc(u8, base64enc.calcSize(macaroon.len));
    defer allocator.free(buf);
    const macaroon_b64 = base64enc.encode(buf, macaroon);
    const port: u16 = switch (typ) {
        .tor_rpc => 10009,
        .tor_http => 10010,
    };
    return std.fmt.allocPrint(allocator, "lndconnect://{[host]s}:{[port]d}?macaroon={[macaroon]s}", .{
        // TODO: return an error instead and propagate to the UI
        .host = self.static.lnd_tor_hostname orelse "<no-tor-hostname>.onion",
        .port = port,
        .macaroon = macaroon_b64,
    });
}

/// generates a random bytes sequence of the given size, dumps it into `LND_WALLETUNLOCK_PATH`
/// file, changing the ownership to `LND_OS_USER`, as well as into the buf in hex encoding.
/// the buffer must be at least twice the size.
/// returns the bytes printed to outbuf.
pub fn makeWalletUnlockFile(self: Config, outbuf: []u8, comptime raw_size: usize) ![]const u8 {
    const filepath = LND_WALLETUNLOCK_PATH;

    const allocator = self.arena.child_allocator;
    const opt = .{ .mode = 0o400 };
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), filepath, opt);
    defer file.destroy(); // frees resources; does NOT delete the file

    var raw_unlock_pwd: [raw_size]u8 = undefined;
    std.crypto.random.bytes(&raw_unlock_pwd);
    const hex = try std.fmt.bufPrint(outbuf, "{}", .{std.fmt.fmtSliceHexLower(&raw_unlock_pwd)});
    try file.writer().writeAll(hex);
    try file.finish();
    try self.chownLndUser(filepath);

    return hex;
}

/// options for genLndConfig.
pub const GenLndConfOpt = struct {
    autounlock: bool,
    path: ?[]const u8 = null, // defaults to LND_CONF_PATH
};

/// creates or overwrites existing lnd config file on disk.
pub fn genLndConfig(self: Config, opt: GenLndConfOpt) !void {
    const confpath = opt.path orelse LND_CONF_PATH;

    const allocator = self.arena.child_allocator;
    var conf = try lightning.LndConf.init(allocator);
    defer conf.deinit();
    var sec = try conf.appendDefaultSection();
    try sec.setPropStr("debuglevel", "info");
    try sec.setPropStr("maxpendingchannels", "10");
    try sec.setPropStr("maxlogfiles", "3");
    try sec.setPropStr("listen", "[::]:9735"); // or 0.0.0.0:9735
    try sec.setPropStr("rpclisten", "0.0.0.0:10009");
    try sec.setPropStr("restlisten", "0.0.0.0:10010");
    try sec.setPropStr("alias", "nakamochi"); // TODO: make alias configurable
    try sec.setPropStr("datadir", LND_DATA_DIR);
    try sec.setPropStr("logdir", LND_LOG_DIR);
    if (self.static.lnd_tor_hostname) |torhost| {
        try sec.setPropStr("tlsextradomain", torhost);
        try sec.setPropStr("externalhosts", torhost);
    }
    if (opt.autounlock) {
        try sec.setPropStr("wallet-unlock-password-file", LND_WALLETUNLOCK_PATH);
    }

    // bitcoin chain settings
    sec = try conf.appendSection("bitcoin");
    try sec.setPropFmt("bitcoin.chaindir", "{s}/chain/mainnet", .{LND_DATA_DIR});
    try sec.setPropStr("bitcoin.active", "true");
    try sec.setPropStr("bitcoin.mainnet", "true");
    try sec.setPropStr("bitcoin.testnet", "false");
    try sec.setPropStr("bitcoin.regtest", "false");
    try sec.setPropStr("bitcoin.simnet", "false");
    try sec.setPropStr("bitcoin.node", "bitcoind");
    sec = try conf.appendSection("bitcoind");
    try sec.setPropStr("bitcoind.zmqpubrawblock", "tcp://127.0.0.1:8331");
    try sec.setPropStr("bitcoind.zmqpubrawtx", "tcp://127.0.0.1:8330");
    try sec.setPropStr("bitcoind.rpchost", "127.0.0.1");
    try sec.setPropStr("bitcoind.rpcuser", "rpc");
    if (self.static.bitcoind_rpc_pass) |rpcpass| {
        try sec.setPropStr("bitcoind.rpcpass", rpcpass);
    } else {
        return error.GenLndConfigNoBitcoindRpcPass;
    }

    // other settings
    sec = try conf.appendSection("autopilot");
    try sec.setPropStr("autopilot.active", "false");
    sec = try conf.appendSection("tor");
    try sec.setPropStr("tor.active", "true");
    try sec.setPropStr("tor.skip-proxy-for-clearnet-targets", "true");

    // dump config into the file.
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), confpath, .{ .mode = 0o400 });
    defer file.destroy(); // frees resources; does NOT delete the file
    try conf.dumpWriter(file.writer());
    try file.finish(); // persist the file in the correct location

    // change file ownership to that of the lnd system user.
    try self.chownLndUser(confpath);
}

/// changes a file ownership to that of `LND_OS_USER`, if the user exists.
fn chownLndUser(self: Config, filepath: []const u8) !void {
    if (self.static.lnd_user) |user| {
        try chown(filepath, user);
    }
}

fn chown(filepath: []const u8, user: std.process.UserInfo) !void {
    const f = try std.fs.cwd().openFile(filepath, .{});
    defer f.close();
    try f.chown(user.uid, user.gid);
}

test "ndconfig: init existing" {
    const t = std.testing;
    const tt = @import("../test.zig");

    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();
    try tmp.dir.writeFile("conf.json",
        \\{
        \\"syschannel": "dev",
        \\"syscronscript": "/cron/sysupdates.sh",
        \\"sysrunscript": "/sysupdates/run.sh"
        \\}
    );
    const conf = try init(t.allocator, try tmp.join(&.{"conf.json"}));
    defer conf.deinit();
    try t.expectEqual(SysupdatesChannel.dev, conf.data.syschannel);
    try t.expectEqualStrings("/cron/sysupdates.sh", conf.data.syscronscript);
    try t.expectEqualStrings("/sysupdates/run.sh", conf.data.sysrunscript);
}

test "ndconfig: init null" {
    const t = std.testing;

    const conf = try init(t.allocator, "/non/existent/config/file");
    defer conf.deinit();
    try t.expectEqual(SysupdatesChannel.master, conf.data.syschannel);
    try t.expectEqualStrings(SYSUPDATES_CRON_SCRIPT_PATH, conf.data.syscronscript);
    try t.expectEqualStrings(SYSUPDATES_RUN_SCRIPT_PATH, conf.data.sysrunscript);
}

test "ndconfig: dump" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // the arena used only for the config instance.
    // purposefully skip arena deinit - expecting no mem leaks in conf usage here.
    var conf_arena = std.heap.ArenaAllocator.init(t.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    const confpath = try tmp.join(&.{"conf.json"});
    var conf = Config{
        .arena = &conf_arena,
        .confpath = confpath,
        .data = .{
            .syschannel = .master,
            .syscronscript = "cronscript.sh",
            .sysrunscript = "runscript.sh",
        },
        .static = undefined,
    };
    // purposefully skip conf.deinit() - expecting no leaking allocations in conf.dump.
    try conf.dump();

    const parsed = try testLoadConfigData(confpath);
    defer parsed.deinit();
    try t.expectEqual(SysupdatesChannel.master, parsed.value.syschannel);
    try t.expectEqualStrings("cronscript.sh", parsed.value.syscronscript);
    try t.expectEqualStrings("runscript.sh", parsed.value.sysrunscript);
}

test "ndconfig: switch sysupdates and infer" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // the arena used only for the config instance.
    // purposefully skip arena deinit - expecting no mem leaks in conf usage here.
    var conf_arena = std.heap.ArenaAllocator.init(t.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    try tmp.dir.writeFile("conf.json", "");
    const confpath = try tmp.join(&.{"conf.json"});
    const cronscript = try tmp.join(&.{"cronscript.sh"});
    var conf = Config{
        .arena = &conf_arena,
        .confpath = confpath,
        .data = .{
            .syschannel = .master,
            .syscronscript = cronscript,
            .sysrunscript = SYSUPDATES_RUN_SCRIPT_PATH,
        },
        .static = undefined,
    };
    // purposefully skip conf.deinit() - expecting no leaking allocations.

    try conf.switchSysupdates(.dev, .{ .run = false });
    const parsed = try testLoadConfigData(confpath);
    defer parsed.deinit();
    try t.expectEqual(SysupdatesChannel.dev, parsed.value.syschannel);
    try t.expectEqual(SysupdatesChannel.dev, inferSysupdatesChannel(cronscript));
}

test "ndconfig: switch sysupdates with .run=true" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // no arena deinit here: expecting Config to auto-deinit.
    var conf_arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    conf_arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    const runscript = "runscript.sh";
    try tmp.dir.writeFile(runscript,
        \\#!/bin/sh
        \\printf "$1" > "$(dirname "$0")/success"
    );
    {
        const file = try tmp.dir.openFile(runscript, .{});
        defer file.close();
        try file.chmod(0o755);
    }
    var conf = Config{
        .arena = conf_arena,
        .confpath = try tmp.join(&.{"conf.json"}),
        .data = .{
            .syschannel = .master,
            .syscronscript = try tmp.join(&.{"cronscript.sh"}),
            .sysrunscript = try tmp.join(&.{runscript}),
        },
        .static = undefined,
    };
    defer conf.deinit();

    try conf.switchSysupdates(.dev, .{ .run = true });
    var buf: [10]u8 = undefined;
    try t.expectEqualStrings("dev", try tmp.dir.readFile("success", &buf));
}

fn testLoadConfigData(path: []const u8) !std.json.Parsed(Data) {
    const allocator = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(bytes);
    const jopt = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    return try std.json.parseFromSlice(Data, allocator, bytes, jopt);
}

test "ndconfig: genLndConfig" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // Config auto-deinits the arena.
    var conf_arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    conf_arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    var conf = Config{
        .arena = conf_arena,
        .confpath = undefined, // unused
        .data = .{
            .syschannel = .master, // unused
            .syscronscript = undefined, // unused
            .sysrunscript = undefined, // unused
        },
        .static = .{
            .hostname = "testhost",
            .lnd_user = null,
            .lnd_tor_hostname = "test.onion",
            .bitcoind_rpc_pass = "test secret",
        },
    };
    defer conf.deinit();

    const confpath = try tmp.join(&.{"lndconf.ini"});
    try conf.genLndConfig(.{ .autounlock = false, .path = confpath });

    const bytes = try std.fs.cwd().readFileAlloc(t.allocator, confpath, 1 << 20);
    defer t.allocator.free(bytes);
    try tt.expectSubstring("tlsextradomain=test.onion\n", bytes);
    try tt.expectSubstring("externalhosts=test.onion\n", bytes);
    try tt.expectNoSubstring("wallet-unlock-password-file", bytes);
    try tt.expectSubstring("bitcoind.rpcpass=test secret\n", bytes);

    try conf.genLndConfig(.{ .autounlock = true, .path = confpath });
    const bytes2 = try std.fs.cwd().readFileAlloc(t.allocator, confpath, 1 << 20);
    defer t.allocator.free(bytes2);
    try tt.expectSubstring("wallet-unlock-password-file=", bytes2);

    const lndconf = try lightning.LndConf.load(t.allocator, confpath);
    defer lndconf.deinit();
    try t.expect(lndconf.mainSection() != null);
    try t.expect(lndconf.findSection("bitcoin") != null);
    try t.expect(lndconf.findSection("bitcoind") != null);
    try t.expect(lndconf.findSection("autopilot") != null);
    try t.expect(lndconf.findSection("tor") != null);
}

test "ndconfig: mutate LndConf" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // Config auto-deinits the arena.
    var conf_arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    conf_arena.* = std.heap.ArenaAllocator.init(t.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    var conf = Config{
        .arena = conf_arena,
        .confpath = undefined, // unused
        .data = undefined, // unused
        .static = .{
            .lnd_user = try types.getUserInfo("ignored"),
            .hostname = undefined,
            .lnd_tor_hostname = null,
            .bitcoind_rpc_pass = null,
        },
    };
    defer conf.deinit();
    const lndconf_path = try tmp.join(&.{"lndconf.ini"});
    try tmp.dir.writeFile(lndconf_path,
        \\[application options]
        \\alias=noname
        \\
    );
    var mut = try conf.beginMutateLndConf(.{ .filepath = lndconf_path });
    try mut.lndconf.setAlias("newalias");
    try mut.persist();
    mut.finish();

    const cont = try tmp.dir.readFileAlloc(t.allocator, lndconf_path, 1 << 10);
    defer t.allocator.free(cont);
    try t.expectEqualStrings(
        \\[application options]
        \\alias=newalias
        \\
    , cont);
}

test "ndconfig: screen lock" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // Config auto-deinits the arena.
    var conf_arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    conf_arena.* = std.heap.ArenaAllocator.init(t.allocator);
    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();

    // nonexistent config file
    {
        var conf = try init(t.allocator, "/nonexistent.json");
        defer conf.deinit();
        try t.expect(conf.data.slock == null);
        try conf.verifySlockPin("");
        try conf.verifySlockPin("any");
    }

    // conf file without slock field
    {
        const confpath = try tmp.join(&.{"conf.json"});
        try tmp.dir.writeFile(confpath,
            \\{
            \\"syschannel": "dev",
            \\"syscronscript": "/cron/sysupdates.sh",
            \\"sysrunscript": "/sysupdates/run.sh"
            \\}
        );
        var conf = try init(t.allocator, confpath);
        defer conf.deinit();
        try t.expect(conf.data.slock == null);
        try conf.verifySlockPin("");
        try conf.verifySlockPin("0000");
    }

    // conf file with null slock
    {
        const confpath = try tmp.join(&.{"conf.json"});
        try tmp.dir.writeFile(confpath,
            \\{
            \\"slock": null,
            \\"syschannel": "dev",
            \\"syscronscript": "/cron/sysupdates.sh",
            \\"sysrunscript": "/sysupdates/run.sh"
            \\}
        );
        var conf = try init(t.allocator, confpath);
        defer conf.deinit();
        try t.expect(conf.data.slock == null);
        try conf.verifySlockPin("");
        try conf.verifySlockPin("1111");
    }

    const newpinconf = try tmp.join(&.{"newconf.json"});
    {
        var conf = Config{
            .arena = conf_arena,
            .confpath = newpinconf,
            .data = .{
                .slock = null,
                .syschannel = .master, // unused
                .syscronscript = undefined, // unused
                .sysrunscript = undefined, // unused
            },
            .static = undefined, // unused
        };
        defer conf.deinit();

        // any pin should workd because slock is null
        try conf.verifySlockPin("");
        try conf.verifySlockPin("any");
        // set a new pin code
        try conf.setSlockPin("1357");
        try conf.verifySlockPin("1357");
        try t.expectError(error.IncorrectSlockPin, conf.verifySlockPin(""));
        try t.expectError(error.IncorrectSlockPin, conf.verifySlockPin("any"));
    }
    // load conf from file and check
    {
        var conf = try init(t.allocator, newpinconf);
        defer conf.deinit();
        try t.expect(conf.data.slock != null);
        try conf.setSlockPin("1357");
        try conf.verifySlockPin("1357");
        try t.expectError(error.IncorrectSlockPin, conf.verifySlockPin("any2"));
    }
}
