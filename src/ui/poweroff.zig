//! poweroff workflow.
//! all functions assume ui_mutex is always locked.
const std = @import("std");

const comm = @import("../comm.zig");
const lvgl = @import("lvgl.zig");
const symbol = @import("symbol.zig");
const widget = @import("widget.zig");

const logger = std.log.scoped(.ui);

/// initiates system shutdown leading to power off.
/// defined in ngui.zig.
extern fn nm_sys_shutdown() void;

/// called when "power off" button is pressed.
export fn nm_poweroff_btn_callback(_: *lvgl.LvEvent) void {
    const proceed: [*:0]const u8 = "PROCEED";
    const abort: [*:0]const u8 = "CANCEL";
    const title = " " ++ symbol.Power ++ " SHUTDOWN";
    const text =
        \\ARE YOU SURE?
        \\
        \\once shut down,
        \\payments cannot go through via bitcoin or lightning networks
        \\until the node is powered back on.
    ;
    widget.modal(title, text, &.{ proceed, abort }, poweroffModalCallback) catch |err| {
        logger.err("shutdown btn: modal: {any}", .{err});
    };
}

/// poweroff confirmation screen callback.
fn poweroffModalCallback(btn_idx: usize) void {
    // proceed = 0, cancel = 1
    if (btn_idx != 0) {
        return;
    }
    defer nm_sys_shutdown(); // initiate shutdown even if next lines fail
    global_progress_win = ProgressWin.create() catch |err| {
        logger.err("ProgressWin.create: {any}", .{err});
        return;
    };
}

var global_progress_win: ?ProgressWin = null;

/// updates the global poweroff process window with the status report.
/// the report is normally sent to GUI by the daemon.
pub fn updateStatus(report: comm.Message.PoweroffProgress) !void {
    if (global_progress_win) |win| {
        var all_stopped = true;
        win.resetSvContainer();
        for (report.services) |sv| {
            try win.addServiceStatus(sv.name, sv.stopped, sv.err);
            all_stopped = all_stopped and sv.stopped;
        }
        if (all_stopped) {
            win.status.setLabelText("powering off ...");
        }
    } else {
        return error.NoProgressWindow;
    }
}

/// represents a modal window in which the poweroff progress is reported until
/// the device turns off.
const ProgressWin = struct {
    win: lvgl.Window,
    status: *lvgl.LvObj, // text status label
    svcont: *lvgl.LvObj, // services container

    /// symbol width next to the service name. this aligns all service names vertically.
    /// has to be wide enough to accomodate the spinner, but not too wide
    /// so that the service name is still close to the symbol.
    const sym_width = 20;

    fn create() !ProgressWin {
        const win = try lvgl.createWindow(null, 60, " " ++ symbol.Power ++ " SHUTDOWN");
        errdefer win.winobj.destroy(); // also deletes all children created below
        const wincont = win.content();
        wincont.flexFlow(.column);

        // initial status message
        const status = try lvgl.createLabel(wincont, "shutting down services. it may take up to a few minutes.", .{});
        status.setWidth(lvgl.sizePercent(100));
        // prepare a container for services status
        const svcont = try lvgl.createObject(wincont);
        svcont.removeBackgroundStyle();
        svcont.flexFlow(.column);
        svcont.flexGrow(1);
        svcont.padColumnDefault();
        svcont.setWidth(lvgl.sizePercent(100));

        return .{
            .win = win,
            .status = status,
            .svcont = svcont,
        };
    }

    fn resetSvContainer(self: ProgressWin) void {
        self.svcont.deleteChildren();
    }

    fn addServiceStatus(self: ProgressWin, name: []const u8, stopped: bool, err: ?[]const u8) !void {
        const row = try lvgl.createObject(self.svcont);
        row.removeBackgroundStyle();
        row.flexFlow(.row);
        row.flexAlign(.center, .center, .center);
        row.padColumnDefault();
        row.setPad(10, .all, .{});
        row.setWidth(lvgl.sizePercent(100));
        row.setHeightToContent();

        var buf: [100]u8 = undefined;
        if (err) |e| {
            const sym = try lvgl.createLabelFmt(row, &buf, symbol.Warning, .{}, .{ .long_mode = .clip });
            sym.setWidth(sym_width);
            sym.setTextColor(lvgl.paletteMain(.red), .{});
            const lb = try lvgl.createLabelFmt(row, &buf, "{s}: {s}", .{ name, e }, .{ .long_mode = .dot });
            lb.setTextColor(lvgl.paletteMain(.red), .{});
            lb.flexGrow(1);
        } else if (stopped) {
            const sym = try lvgl.createLabelFmt(row, &buf, symbol.Ok, .{}, .{ .long_mode = .clip });
            sym.setWidth(sym_width);
            const lb = try lvgl.createLabelFmt(row, &buf, "{s}", .{name}, .{ .long_mode = .dot });
            lb.flexGrow(1);
        } else {
            const spin = try lvgl.createSpinner(row);
            spin.setWidth(sym_width);
            const lb = try lvgl.createLabelFmt(row, &buf, "{s}", .{name}, .{ .long_mode = .dot });
            lb.flexGrow(1);
        }
    }
};
