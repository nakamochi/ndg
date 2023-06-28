const buildopts = @import("build_options");
const std = @import("std");
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

const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const logger = std.log.scoped(.ngui);

extern "c" fn ui_update_network_status(text: [*:0]const u8, wifi_list: ?[*:0]const u8) void;

/// global heap allocator used throughout the gui program.
/// TODO: thread-safety?
var gpa: std.mem.Allocator = undefined;

/// the mutex must be held before any call reaching into lv_xxx functions.
/// all nm_xxx functions assume it is the case since they are invoked from lvgl c code.
var ui_mutex: std.Thread.Mutex = .{};
/// the program runs until quit is true.
var quit: bool = false;
var state: enum {
    active, // normal operational mode
    standby, // idling
    alert, // draw user attention; never go standby
} = .active;

/// setting wakeup brings the screen back from sleep()'ing without waiting
/// for user action.
/// can be used by comms when an alert is received from the daemon, to draw
/// user attention.
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

/// initiate system shutdown leading to power off.
export fn nm_sys_shutdown() void {
    logger.info("initiating system shutdown", .{});
    const msg = comm.Message.poweroff;
    comm.write(gpa, stdout, msg) catch |err| logger.err("nm_sys_shutdown: {any}", .{err});
    quit = true;
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

/// reads messages from nd; loops indefinitely until program exit
fn commThread() void {
    while (true) {
        commThreadLoopCycle() catch |err| logger.err("commThreadLoopCycle: {any}", .{err});
        ui_mutex.lock();
        const do_quit = quit;
        ui_mutex.unlock();
        if (do_quit) {
            return;
        }
    }
}

fn commThreadLoopCycle() !void {
    const msg = comm.read(gpa, stdin) catch |err| {
        if (err == error.EndOfStream) {
            // pointless to continue running if comms is broken.
            // a parent/supervisor is expected to restart ngui.
            ui_mutex.lock();
            quit = true;
            ui_mutex.unlock();
        }
        return err;
    };
    defer comm.free(gpa, msg);
    logger.debug("got msg tagged {s}", .{@tagName(msg)});
    switch (msg) {
        .ping => try comm.write(gpa, stdout, comm.Message.pong),
        .network_report => |report| {
            updateNetworkStatus(report) catch |err| logger.err("updateNetworkStatus: {any}", .{err});
        },
        else => logger.warn("unhandled msg tag {s}", .{@tagName(msg)}),
    }
}

/// prints messages in the same way std.fmt.format does and exits the process
/// with a non-zero code.
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    if (fmt[fmt.len - 1] != '\n') {
        stderr.writeByte('\n') catch {};
    }
    std.process.exit(1);
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
            fatal("unknown arg name {s}", .{a});
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
        std.process.exit(1);
    };

    // start comms with daemon in a seaparate thread.
    const th = try std.Thread.spawn(.{}, commThread, .{});
    th.detach();

    // run idle timer indefinitely
    _ = lvgl.createTimer(nm_check_idle_time, 2000, null) catch |err| {
        logger.err("idle timer: lvgl.CreateTimer failed: {any}", .{err});
    };

    // main UI thread; must never block unless in idle/sleep mode
    // TODO: handle sigterm
    while (true) {
        ui_mutex.lock();
        var till_next_ms = lvgl.loopCycle();
        const do_quit = quit;
        const do_state = state;
        ui_mutex.unlock();
        if (do_quit) {
            return;
        }
        if (do_state == .standby) {
            // go into a screen sleep mode due to no user activity
            wakeup.reset();
            comm.write(gpa, stdout, comm.Message.standby) catch |err| {
                logger.err("comm.write standby: {any}", .{err});
            };
            screen.sleep(&wakeup);
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
        }
        std.atomic.spinLoopHint();
        // sleep at least 1ms
        time.sleep(@max(1, till_next_ms) * time.ns_per_ms);
    }
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
