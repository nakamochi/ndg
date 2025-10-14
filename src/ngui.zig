const buildopts = @import("build_options");
const std = @import("std");
const posix = std.posix;
const time = std.time;

const comm = @import("comm.zig");
const types = @import("types.zig");
const ui = @import("ui/ui.zig");
const lvgl = @import("ui/lvgl.zig");
const screen = @import("ui/screen.zig");
const screenlock = @import("ui/screenlock.zig");
const symbol = @import("ui/symbol.zig");

const logger = std.log.scoped(.ngui);

// these are auto-closed as soon as main fn terminates.
const stderr = std.io.getStdErr().writer();

extern "c" fn ui_update_network_status(text: [*:0]const u8, wifi_list: ?[*:0]const u8) void;

/// global heap allocator used throughout the GUI program.
/// TODO: thread-safety?
var gpa: std.mem.Allocator = undefined;

/// the mutex must be held before any call reaching into lv_xxx functions.
/// all nm_xxx functions assume it is the case since they are invoked from lvgl c code.
var ui_mutex: std.Thread.Mutex = .{};

/// current state of the GUI.
/// guarded by `ui_mutex` since some `nm_xxx` funcs branch based off of the state.
var state: enum {
    active, // normal operational mode
    standby, // idling
    alert, // draw user attention; never go standby
} = .active;

var slock_status: enum {
    enabled,
    disabled,
} = undefined; // set in main after parsing cmd line flags

/// last report received from comm.
/// deinit'ed at program exit.
/// while deinit and replace handle concurrency, field access requires holding mu.
var last_report: struct {
    mu: std.Thread.Mutex = .{},
    network: ?comm.ParsedMessage = null, // NetworkReport
    onchain: ?comm.ParsedMessage = null, // OnchainReport
    lightning: ?comm.ParsedMessage = null, // LightningReport or LightningError

    fn deinit(self: *@This()) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.network) |v| {
            v.deinit();
            self.network = null;
        }
        if (self.onchain) |v| {
            v.deinit();
            self.onchain = null;
        }
        if (self.lightning) |v| {
            v.deinit();
            self.lightning = null;
        }
    }

    fn replace(self: *@This(), new: comm.ParsedMessage) void {
        self.mu.lock();
        defer self.mu.unlock();
        const tag: comm.MessageTag = new.value;
        switch (tag) {
            .network_report => {
                if (self.network) |old| {
                    old.deinit();
                }
                self.network = new;
            },
            .onchain_report => {
                if (self.onchain) |old| {
                    old.deinit();
                }
                self.onchain = new;
            },
            .lightning_report, .lightning_error => {
                if (self.lightning) |old| {
                    old.deinit();
                }
                self.lightning = new;
            },
            else => |t| logger.err("last_report: replace: unhandled tag {}", .{t}),
        }
    }
} = .{};

/// the program runs until sigquit is true.
/// set from sighandler or on unrecoverable comm failure with the daemon.
var sigquit: std.Thread.ResetEvent = .{};

/// by setting wakeup brings the screen back from sleep()'ing without waiting for user action.
/// can be used by comms when an alert is received from the daemon, to draw user attention.
/// safe for concurrent use except wakeup.reset() is UB during another thread
/// wakeup.wait()'ing or timedWait'ing.
var wakeup = std.Thread.ResetEvent{};

/// a monotonic clock for reporting elapsed ticks to LVGL.
/// the timer runs throughout the whole duration of the UI program.
var tick_timer: types.Timer = undefined;

/// reports elapsed time in ms since the program start, overflowing at u32 max.
/// it is defined as LVGL custom tick.
export fn nm_get_curr_tick() u32 {
    const ms = tick_timer.read() / time.ns_per_ms;
    const over = ms >> 32;
    if (over > 0) {
        return @truncate(over); // LVGL deals with overflow correctly
    }
    return @truncate(ms);
}

export fn nm_check_idle_time(_: *lvgl.LvTimer) void {
    const standby_idle_ms = 60000; // 60sec
    const idle_ms = lvgl.idleTime();
    if (idle_ms < standby_idle_ms) {
        return;
    }
    switch (state) {
        .alert, .standby => {},
        .active => state = .standby,
    }
}

/// tells the daemon to initiate system shutdown leading to power off.
/// once all's done, the daemon will send a SIGTERM back to ngui.
export fn nm_sys_shutdown() void {
    const msg = comm.Message.poweroff;
    comm.pipeWrite(msg) catch |err| logger.err("nm_sys_shutdown: {any}", .{err});
    state = .alert; // prevent screen sleep
    wakeup.set(); // wake up from standby, if any
}

export fn nm_tab_settings_active() void {
    logger.info("starting wifi scan", .{});
    const msg = comm.Message{ .get_network_report = .{ .scan = true } };
    comm.pipeWrite(msg) catch |err| logger.err("nm_tab_settings_active: {any}", .{err});
}

export fn nm_request_network_status(t: *lvgl.LvTimer) void {
    t.destroy();
    const msg: comm.Message = .{ .get_network_report = .{ .scan = false } };
    comm.pipeWrite(msg) catch |err| logger.err("nm_request_network_status: {any}", .{err});
}

/// ssid and password args must not outlive this function.
export fn nm_wifi_start_connect(ssid: [*:0]const u8, password: [*:0]const u8) void {
    const msg = comm.Message{ .wifi_connect = .{
        .ssid = std.mem.span(ssid),
        .password = std.mem.span(password),
    } };
    logger.info("connect to wifi [{s}]", .{msg.wifi_connect.ssid});
    comm.pipeWrite(msg) catch |err| logger.err("nm_wifi_start_connect: {any}", .{err});
}

/// callers must hold ui mutex for the whole duration.
fn updateNetworkStatus(report: comm.Message.NetworkReport) !void {
    var wifi_list: ?[:0]const u8 = null;
    var wifi_list_ptr: ?[*:0]const u8 = null;
    if (report.wifi_scan_networks.len > 0) {
        wifi_list = try std.mem.joinZ(gpa, "\n", report.wifi_scan_networks);
        wifi_list_ptr = wifi_list.?.ptr;
    }
    defer if (wifi_list) |v| gpa.free(v);

    var status = std.ArrayList(u8).init(gpa); // free'd as owned slice below
    const w = status.writer();
    if (report.wifi_ssid) |ssid| {
        try w.writeAll(symbol.Ok);
        try w.print(" connected to {s}", .{ssid});
    } else {
        try w.writeAll(symbol.Warning);
        try w.print(" disconnected", .{});
    }

    if (report.ipaddrs.len > 0) {
        const ipaddrs = try std.mem.join(gpa, "\n", report.ipaddrs);
        defer gpa.free(ipaddrs);
        try w.print("\n\nIP addresses:\n{s}", .{ipaddrs});
    }

    const text = try status.toOwnedSliceSentinel(0);
    defer gpa.free(text);
    ui_update_network_status(text, wifi_list_ptr);

    // request network status again if we're connected but IP addr list is empty.
    // can happen with a fresh connection while dhcp is still in progress.
    if (report.wifi_ssid != null and report.ipaddrs.len == 0) {
        // TODO: sometimes this is too fast, not all ip addrs are avail (ipv4 vs ipv6)
        if (lvgl.LvTimer.new(nm_request_network_status, 1000, null)) |t| {
            t.setRepeatCount(1);
        } else |err| {
            logger.err("network status timer failed: {any}", .{err});
        }
    }
}

/// reads messages from nd.
/// loops indefinitely until program exit or comm returns EOS.
fn commThreadLoop() void {
    while (true) {
        commThreadLoopCycle() catch |err| {
            logger.err("commThreadLoopCycle: {any}", .{err});
            if (err == error.EndOfStream) {
                // pointless to continue running if comms is broken.
                // a parent/supervisor is expected to restart ngui.
                break;
            }
        };
        std.atomic.spinLoopHint();
        time.sleep(10 * time.ns_per_ms);
    }

    logger.info("exiting commThreadLoop", .{});
    sigquit.set();
}

/// runs one cycle of the commThreadLoop: read messages from stdin and update
/// the UI accordingly.
/// holds ui mutex for most of the duration.
fn commThreadLoopCycle() !void {
    const msg = try comm.pipeRead(); // blocking
    ui_mutex.lock(); // guards the state and all UI calls below
    defer ui_mutex.unlock();
    switch (msg.value) {
        .ping => {
            defer msg.deinit();
            try comm.pipeWrite(comm.Message.pong);
        },
        .poweroff_progress => |rep| {
            ui.poweroff.updateStatus(rep) catch |err| logger.err("poweroff.updateStatus: {any}", .{err});
            msg.deinit();
        },
        .network_report => |rep| {
            if (state != .standby) {
                updateNetworkStatus(rep) catch |err| logger.err("updateNetworkStatus: {any}", .{err});
            }
            last_report.replace(msg);
        },
        .onchain_report => |rep| {
            if (state != .standby) {
                ui.bitcoin.updateTabPanel(rep) catch |err| logger.err("bitcoin.updateTabPanel: {any}", .{err});
            }
            last_report.replace(msg);
        },
        .lightning_report, .lightning_error => {
            if (state != .standby) {
                ui.lightning.updateTabPanel(msg.value) catch |err| logger.err("lightning.updateTabPanel: {any}", .{err});
            }
            last_report.replace(msg);
        },
        .lightning_genseed_result,
        .lightning_ctrlconn,
        => {
            ui.lightning.updateTabPanel(msg.value) catch |err| logger.err("lightning.updateTabPanel: {any}", .{err});
            msg.deinit();
        },
        .settings => |sett| {
            ui.settings.update(sett) catch |err| logger.err("settings.update: {any}", .{err});
            slock_status = if (sett.slock_enabled) .enabled else .disabled;
            msg.deinit();
        },
        .screen_unlock_result => |unlock| {
            if (unlock.ok) {
                ui.screenlock.unlockSuccess();
            } else {
                var errmsg: [:0]const u8 = "invalid pin code";
                if (unlock.err) |s| {
                    errmsg = gpa.dupeZ(u8, s) catch errmsg;
                }
                ui.screenlock.unlockFailure(errmsg);
            }
        },
        else => {
            logger.warn("unhandled msg tag {s}", .{@tagName(msg.value)});
            msg.deinit();
        },
    }
}

/// UI thread: LVGL loop runs here.
/// must never block unless in idle/sleep mode.
fn uiThreadLoop() void {
    while (true) {
        ui_mutex.lock();
        const till_next_ms = lvgl.loopCycle(); // UI loop
        const do_state = state;
        ui_mutex.unlock();

        switch (do_state) {
            .active => {},
            .alert => {},
            .standby => {
                // go into a screen sleep mode due to no user activity
                wakeup.reset();
                comm.pipeWrite(comm.Message.standby) catch |err| logger.err("standby: {any}", .{err});
                if (slock_status == .enabled) {
                    screenlock.activate();
                }
                screen.sleep(&ui_mutex, &wakeup); // blocking

                // wake up due to touch screen activity or wakeup event is set
                logger.info("waking up from sleep", .{});
                ui_mutex.lock();
                defer ui_mutex.unlock();
                if (state == .standby) {
                    state = .active;
                    comm.pipeWrite(comm.Message.wakeup) catch |err| logger.err("wakeup: {any}", .{err});
                    lvgl.resetIdle();

                    last_report.mu.lock();
                    defer last_report.mu.unlock();
                    if (last_report.network) |msg| {
                        updateNetworkStatus(msg.value.network_report) catch |err| {
                            logger.err("updateNetworkStatus: {any}", .{err});
                        };
                    }
                    if (last_report.onchain) |msg| {
                        ui.bitcoin.updateTabPanel(msg.value.onchain_report) catch |err| {
                            logger.err("bitcoin.updateTabPanel: {any}", .{err});
                        };
                    }
                    if (last_report.lightning) |msg| {
                        ui.lightning.updateTabPanel(msg.value) catch |err| {
                            logger.err("lightning.updateTabPanel: {any}", .{err});
                        };
                    }
                }
                continue;
            },
        }

        std.atomic.spinLoopHint();
        time.sleep(@max(1, till_next_ms) * time.ns_per_ms); // sleep at least 1ms
    }

    logger.info("exiting UI thread loop", .{});
}

/// prints usage help text to stderr.
fn usage(prog: []const u8) !void {
    try stderr.print(
        \\usage: {s} [-v] [-slock]
        \\
        \\ngui is nakamochi GUI interface. it communicates with nd, nakamochi daemon,
        \\via stdio and is typically launched by the daemon as a child process.
        \\
        \\-slock makes the interface start up in a screenlocked mode.
    , .{prog});
}

const CmdFlags = struct {
    slock: bool, // whether to start the UI in screen locked mode
};

fn parseArgs(alloc: std.mem.Allocator) !CmdFlags {
    var flags = CmdFlags{ .slock = false };

    var args = try std.process.ArgIterator.initWithAllocator(alloc);
    defer args.deinit();
    const prog = args.next() orelse return error.NoProgName;

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "-help") or std.mem.eql(u8, a, "--help")) {
            usage(prog) catch {};
            std.process.exit(1);
        } else if (std.mem.eql(u8, a, "-v")) {
            try stderr.print("{any}\n", .{buildopts.semver});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "-slock")) {
            flags.slock = true;
        } else {
            logger.err("unknown arg name {s}", .{a});
            return error.UnknownArgName;
        }
    }
    return flags;
}

/// handles sig TERM and INT: makes the program exit.
fn sighandler(sig: c_int) callconv(.C) void {
    if (sigquit.isSet()) {
        return;
    }
    switch (sig) {
        posix.SIG.INT, posix.SIG.TERM => sigquit.set(),
        else => {},
    }
}

/// nakamochi UI program entry point.
pub fn main() anyerror!void {
    // main heap allocator used through the lifetime of nd
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit() == .leak) {
        logger.err("memory leaks detected", .{});
    };
    gpa = gpa_state.allocator();
    const flags = try parseArgs(gpa);
    logger.info("ndg version {any}", .{buildopts.semver});
    slock_status = if (flags.slock) .enabled else .disabled;

    // ensure timer is available on this platform before doing anything else;
    // the UI is unusable otherwise.
    tick_timer = try time.Timer.start();

    // initialize global nd/ngui pipe plumbing.
    comm.initPipe(gpa, .{ .r = std.io.getStdIn(), .w = std.io.getStdOut() });

    // initalizes display, input driver and finally creates the user interface.
    ui.init(.{ .allocator = gpa, .slock = flags.slock }) catch |err| {
        logger.err("ui.init: {any}", .{err});
        return err;
    };

    // run idle timer indefinitely.
    // continue on failure: screen standby won't work at the worst.
    _ = lvgl.LvTimer.new(nm_check_idle_time, 2000, null) catch |err| {
        logger.err("lvgl.LvTimer.new(idle check): {any}", .{err});
    };

    {
        // start the main UI thread.
        const th = try std.Thread.spawn(.{}, uiThreadLoop, .{});
        th.detach();
    }

    {
        // start comms with daemon in a seaparate thread.
        const th = try std.Thread.spawn(.{}, commThreadLoop, .{});
        th.detach();
    }

    // set up a sigterm handler for clean exit.
    const sa = posix.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    try posix.sigaction(posix.SIG.INT, &sa, null);
    try posix.sigaction(posix.SIG.TERM, &sa, null);
    sigquit.wait();
    logger.info("sigquit: terminating ...", .{});

    // assuming nd won't ever send any more messages,
    // so should be safe to touch last_report without a fence.
    last_report.deinit();

    // let the OS rip off UI and comm threads
}

test "tick" {
    const t = std.testing;

    tick_timer = types.Timer{ .value = 0 };
    try t.expectEqual(@as(u32, 0), nm_get_curr_tick());

    tick_timer.value = 1 * time.ns_per_ms;
    try t.expectEqual(@as(u32, 1), nm_get_curr_tick());

    tick_timer.value = 13 * time.ns_per_ms;
    try t.expectEqual(@as(u32, 13), nm_get_curr_tick());

    tick_timer.value = @as(u64, ~@as(u32, 0)) * time.ns_per_ms;
    try t.expectEqual(@as(u32, std.math.maxInt(u32)), nm_get_curr_tick());

    tick_timer.value = (1 << 32) * time.ns_per_ms;
    try t.expectEqual(@as(u32, 1), nm_get_curr_tick());
}
