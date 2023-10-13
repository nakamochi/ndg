//! ndg persistent configuration, loaded from and stored to disk in JSON format.
//! the structure is defined in `Data`.

const std = @import("std");

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

static: StaticData,
mu: std.Thread.RwLock = .{},
data: Data,

/// top struct stored on disk.
/// access with `safeReadOnly` or lock/unlock `mu`.
pub const Data = struct {
    syschannel: SysupdatesChannel,
    syscronscript: []const u8,
    sysrunscript: []const u8,
};

/// static data is always interred at init and never changes.
pub const StaticData = struct {
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
        .static = inferStaticData(arena.allocator()),
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

fn inferStaticData(allocator: std.mem.Allocator) StaticData {
    return .{
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
pub fn safeReadOnly(self: *Config, comptime F: anytype) @typeInfo(@TypeOf(F)).Fn.return_type.? {
    self.mu.lockShared();
    defer self.mu.unlockShared();
    return F(self.data);
}

/// stores current `Config.data` to disk, into `Config.confpath`.
pub fn dump(self: *Config) !void {
    self.mu.lock();
    defer self.mu.unlock();
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
    const lnduser = try std.process.getUserInfo(LND_OS_USER);

    const allocator = self.arena.child_allocator;
    const opt = .{ .mode = 0o400 };
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), filepath, opt);
    defer file.destroy(); // frees resources; does NOT delete the file

    var raw_unlock_pwd: [raw_size]u8 = undefined;
    std.crypto.random.bytes(&raw_unlock_pwd);
    const hex = try std.fmt.bufPrint(outbuf, "{}", .{std.fmt.fmtSliceHexLower(&raw_unlock_pwd)});
    try file.writer().writeAll(hex);
    try file.finish();

    const f = try std.fs.cwd().openFile(filepath, .{});
    defer f.close();
    try f.chown(lnduser.uid, lnduser.gid);

    return hex;
}

/// creates or overwrites existing lnd config file at `LND_CONF_PATH`.
pub fn genLndConfig(self: Config, opt: struct { autounlock: bool }) !void {
    const confpath = LND_CONF_PATH;
    const lnduser = try std.process.getUserInfo(LND_OS_USER);

    const allocator = self.arena.child_allocator;
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), confpath, .{ .mode = 0o400 });
    defer file.destroy(); // frees resources; does NOT delete the file
    const w = file.writer();

    // main app settings
    try w.writeAll("[Application Options]\n");
    try w.writeAll("debuglevel=info\n");
    try w.writeAll("maxpendingchannels=10\n");
    try w.writeAll("maxlogfiles=3\n");
    try w.writeAll("listen=[::]:9735\n"); // or 0.0.0.0:9735
    try w.writeAll("rpclisten=0.0.0.0:10009\n");
    try w.writeAll("restlisten=0.0.0.0:10010\n"); // TODO: replace with 127.0.0.1 and no-rest-tls=true?
    try std.fmt.format(w, "alias={s}\n", .{"nakamochi"}); // TODO: make alias configurable
    try std.fmt.format(w, "datadir={s}\n", .{LND_DATA_DIR});
    try std.fmt.format(w, "logdir={s}\n", .{LND_LOG_DIR});
    if (self.static.lnd_tor_hostname) |torhost| {
        try std.fmt.format(w, "tlsextradomain={s}\n", .{torhost});
        try std.fmt.format(w, "externalhosts={s}\n", .{torhost});
    }
    if (opt.autounlock) {
        try std.fmt.format(w, "wallet-unlock-password-file={s}\n", .{LND_WALLETUNLOCK_PATH});
    }

    // bitcoin chain settings
    try w.writeAll("\n[bitcoin]\n");
    try std.fmt.format(w, "bitcoin.chaindir={s}/chain/mainnet\n", .{LND_DATA_DIR});
    try w.writeAll("bitcoin.active=true\n");
    try w.writeAll("bitcoin.mainnet=True\n");
    try w.writeAll("bitcoin.testnet=False\n");
    try w.writeAll("bitcoin.regtest=False\n");
    try w.writeAll("bitcoin.simnet=False\n");
    try w.writeAll("bitcoin.node=bitcoind\n");
    try w.writeAll("\n[bitcoind]\n");
    try w.writeAll("bitcoind.zmqpubrawblock=tcp://127.0.0.1:8331\n");
    try w.writeAll("bitcoind.zmqpubrawtx=tcp://127.0.0.1:8330\n");
    try w.writeAll("bitcoind.rpchost=127.0.0.1\n");
    try w.writeAll("bitcoind.rpcuser=rpc\n");
    if (self.static.bitcoind_rpc_pass) |rpcpass| {
        try std.fmt.format(w, "bitcoind.rpcpass={s}\n", .{rpcpass});
    } else {
        return error.GenLndConfigNoBitcoindRpcPass;
    }

    // other settings
    try w.writeAll("\n[autopilot]\n");
    try w.writeAll("autopilot.active=false\n");
    try w.writeAll("\n[tor]\n");
    try w.writeAll("tor.active=true\n");
    try w.writeAll("tor.skip-proxy-for-clearnet-targets=true\n");

    // persist the file in the correct location.
    try file.finish();

    // change file ownership to that of the lnd system user.
    const f = try std.fs.cwd().openFile(confpath, .{});
    defer f.close();
    try f.chown(lnduser.uid, lnduser.gid);
}

test "init existing" {
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

test "init null" {
    const t = std.testing;

    const conf = try init(t.allocator, "/non/existent/config/file");
    defer conf.deinit();
    try t.expectEqual(SysupdatesChannel.master, conf.data.syschannel);
    try t.expectEqualStrings(SYSUPDATES_CRON_SCRIPT_PATH, conf.data.syscronscript);
    try t.expectEqualStrings(SYSUPDATES_RUN_SCRIPT_PATH, conf.data.sysrunscript);
}

test "dump" {
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

test "switch sysupdates and infer" {
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

test "switch sysupdates with .run=true" {
    const t = std.testing;
    const tt = @import("../test.zig");

    // no arena deinit: expecting Config to
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
