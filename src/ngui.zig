const buildopts = @import("build_options");
const std = @import("std");
const os = std.os;
const time = std.time;

const comm = @import("comm.zig");
const types = @import("types.zig");
const ui = @import("ui/ui.zig");
const lvgl = @import("ui/lvgl.zig");
const screen = @import("ui/screen.zig");
const symbol = @import("ui/symbol.zig");

/// SIGPIPE is triggered when a process attempts to write to a broken pipe.
/// by default, SIGPIPE terminates the process without invoking a panic handler.
/// this declaration makes such writes result in EPIPE (error.BrokenPipe) to let
/// the program can handle it.
pub const keep_sigpipe = true;

const logger = std.log.scoped(.ngui);

// these are auto-closed as soon as main fn terminates.
const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

extern "c" fn ui_update_network_status(text: [*:0]const u8, wifi_list: ?[*:0]const u8) void;

/// global heap allocator used throughout the GUI program.
/// TODO: thread-safety?
var gpa: std.mem.Allocator = undefined;

/// the mutex must be held before any call reaching into lv_xxx functions.
/// all nm_xxx functions assume it is the case since they are invoked from lvgl c code.
var ui_mutex: std.Thread.Mutex = .{};

var state: enum {
    active, // normal operational mode
    standby, // idling
    alert, // draw user attention; never go standby
} = .active;

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
        return @truncate(u32, over); // LVGL deals with overflow correctly
    }
    return @truncate(u32, ms);
}

export fn nm_check_idle_time(_: *lvgl.LvTimer) void {
    const standby_idle_ms = 60000; // 60sec
    const idle_ms = lvgl.idleTime();
    if (idle_ms > standby_idle_ms and state != .alert) {
        state = .standby;
    }
}

/// tells the daemon to initiate system shutdown leading to power off.
/// once all's done, the daemon will send a SIGTERM back to ngui.
export fn nm_sys_shutdown() void {
    const msg = comm.Message.poweroff;
    comm.write(gpa, stdout, msg) catch |err| logger.err("nm_sys_shutdown: {any}", .{err});
    state = .alert; // prevent screen sleep
    wakeup.set(); // wake up from standby, if any
}

export fn nm_tab_settings_active() void {
    logger.info("starting wifi scan", .{});
    const msg = comm.Message{ .get_network_report = .{ .scan = true } };
    comm.write(gpa, stdout, msg) catch |err| logger.err("nm_tab_settings_active: {any}", .{err});
}

export fn nm_request_network_status(t: *lvgl.LvTimer) void {
    t.destroy();
    const msg: comm.Message = .{ .get_network_report = .{ .scan = false } };
    comm.write(gpa, stdout, msg) catch |err| logger.err("nm_request_network_status: {any}", .{err});
}

/// ssid and password args must not outlive this function.
export fn nm_wifi_start_connect(ssid: [*:0]const u8, password: [*:0]const u8) void {
    const msg = comm.Message{ .wifi_connect = .{
        .ssid = std.mem.span(ssid),
        .password = std.mem.span(password),
    } };
    logger.info("connect to wifi [{s}]", .{msg.wifi_connect.ssid});
    comm.write(gpa, stdout, msg) catch |err| {
        logger.err("comm.write: {any}", .{err});
    };
}

fn updateNetworkStatus(report: comm.Message.NetworkReport) !void {
    ui_mutex.lock();
    defer ui_mutex.unlock();

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
        if (lvgl.createTimer(nm_request_network_status, 1000, null)) |t| {
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
fn commThreadLoopCycle() !void {
    const msg = try comm.read(gpa, stdin);
    defer comm.free(gpa, msg);
    logger.debug("got msg: {s}", .{@tagName(msg)});
    switch (msg) {
        .ping => try comm.write(gpa, stdout, comm.Message.pong),
        .network_report => |report| {
            updateNetworkStatus(report) catch |err| logger.err("updateNetworkStatus: {any}", .{err});
        },
        .poweroff_progress => |report| {
            ui_mutex.lock();
            defer ui_mutex.unlock();
            ui.poweroff.updateStatus(report) catch |err| logger.err("poweroff.updateStatus: {any}", .{err});
        },
        .bitcoind_report => |rep| {
            ui_mutex.lock();
            defer ui_mutex.unlock();
            ui.bitcoin.updateTabPanel(rep) catch |err| logger.err("bitcoin.updateTabPanel: {any}", .{err});
        },
        else => logger.warn("unhandled msg tag {s}", .{@tagName(msg)}),
    }
}

/// UI thread: LVGL loop runs here.
/// must never block unless in idle/sleep mode.
fn uiThreadLoop() void {
    while (true) {
        ui_mutex.lock();
        var till_next_ms = lvgl.loopCycle(); // UI loop
        const do_state = state;
        ui_mutex.unlock();

        switch (do_state) {
            .active => {},
            .alert => {},
            .standby => {
                // go into a screen sleep mode due to no user activity
                wakeup.reset();
                comm.write(gpa, stdout, comm.Message.standby) catch |err| {
                    logger.err("comm.write standby: {any}", .{err});
                };
                screen.sleep(&wakeup); // blocking

                // wake up due to touch screen activity or wakeup event is set
                logger.info("waking up from sleep", .{});
                ui_mutex.lock();
                if (state == .standby) {
                    state = .active;
                    comm.write(gpa, stdout, comm.Message.wakeup) catch |err| {
                        logger.err("comm.write wakeup: {any}", .{err});
                    };
                    lvgl.resetIdle();
                }
                ui_mutex.unlock();
                continue;
            },
        }

        std.atomic.spinLoopHint();
        time.sleep(@max(1, till_next_ms) * time.ns_per_ms); // sleep at least 1ms
    }

    logger.info("exiting UI thread loop", .{});
}

fn parseArgs(alloc: std.mem.Allocator) !void {
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
        } else {
            logger.err("unknown arg name {s}", .{a});
            return error.UnknownArgName;
        }
    }
}

/// prints usage help text to stderr.
fn usage(prog: []const u8) !void {
    try stderr.print(
        \\usage: {s} [-v]
        \\
        \\ngui is nakamochi GUI interface. it communicates with nd, nakamochi daemon,
        \\via stdio and is typically launched by the daemon as a child process.
        \\
    , .{prog});
}

/// handles sig TERM and INT: makes the program exit.
fn sighandler(sig: c_int) callconv(.C) void {
    logger.info("received signal {}", .{sig});
    switch (sig) {
        os.SIG.INT, os.SIG.TERM => sigquit.set(),
        else => {},
    }
}

/// nakamochi UI program entry point.
pub fn main() anyerror!void {
    // main heap allocator used through the lifetime of nd
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit()) {
        logger.err("memory leaks detected", .{});
    };
    gpa = gpa_state.allocator();
    try parseArgs(gpa);
    logger.info("ndg version {any}", .{buildopts.semver});

    // ensure timer is available on this platform before doing anything else;
    // the UI is unusable otherwise.
    tick_timer = try time.Timer.start();

    // initalizes display, input driver and finally creates the user interface.
    ui.init() catch |err| {
        logger.err("ui.init: {any}", .{err});
        return err;
    };

    // run idle timer indefinitely.
    // continue on failure: screen standby won't work at the worst.
    _ = lvgl.createTimer(nm_check_idle_time, 2000, null) catch |err| {
        logger.err("lvgl.CreateTimer(idle check): {any}", .{err});
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
    const sa = os.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    try os.sigaction(os.SIG.INT, &sa, null);
    try os.sigaction(os.SIG.TERM, &sa, null);
    sigquit.wait();

    logger.info("main terminated", .{});
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
