const buildopts = @import("build_options");
const std = @import("std");

const comm = @import("../comm.zig");
const drv = @import("drv.zig");
const lvgl = @import("lvgl.zig");
const symbol = @import("symbol.zig");
const widget = @import("widget.zig");

pub const bitcoin = @import("bitcoin.zig");
pub const lightning = @import("lightning.zig");
pub const poweroff = @import("poweroff.zig");
pub const settings = @import("settings.zig");

const logger = std.log.scoped(.ui);

// defined in src/ui/c/ui.c
// calls back into nm_create_xxx_panel functions defined here during init.
extern "c" fn nm_ui_init(disp: *lvgl.LvDisp) c_int;

// global allocator set on init.
// must be set before a call to nm_ui_init.
var allocator: std.mem.Allocator = undefined;

pub fn init(gpa: std.mem.Allocator) !void {
    allocator = gpa;
    settings.allocator = gpa;
    lvgl.init();
    const disp = try drv.initDisplay();
    drv.initInput() catch |err| {
        // TODO: or continue without the touchpad?
        // at the very least must disable screen blanking timeout in case of a failure.
        // otherwise, impossible to wake up the screen. */
        return err;
    };
    if (nm_ui_init(disp) != 0) {
        return error.UiInitFailure;
    }
}

export fn nm_create_info_panel(parent: *lvgl.LvObj) c_int {
    createInfoPanel(lvgl.Container{ .lvobj = parent }) catch |err| {
        logger.err("createInfoPanel: {any}", .{err});
        return -1;
    };
    return 0;
}

export fn nm_create_bitcoin_panel(parent: *lvgl.LvObj) c_int {
    bitcoin.initTabPanel(lvgl.Container{ .lvobj = parent }) catch |err| {
        logger.err("createBitcoinPanel: {any}", .{err});
        return -1;
    };
    return 0;
}

export fn nm_create_lightning_panel(parent: *lvgl.LvObj) c_int {
    lightning.initTabPanel(allocator, lvgl.Container{ .lvobj = parent }) catch |err| {
        logger.err("createLightningPanel: {any}", .{err});
        return -1;
    };
    return 0;
}

export fn nm_create_settings_nodename(parent: *lvgl.LvObj) ?*lvgl.LvObj {
    const card = settings.initNodenamePanel(lvgl.Container{ .lvobj = parent }) catch |err| {
        logger.err("initNodenamePanel: {any}", .{err});
        return null;
    };
    return card.lvobj;
}

export fn nm_create_settings_sysupdates(parent: *lvgl.LvObj) ?*lvgl.LvObj {
    const card = settings.initSysupdatesPanel(lvgl.Container{ .lvobj = parent }) catch |err| {
        logger.err("initSysupdatesPanel: {any}", .{err});
        return null;
    };
    return card.lvobj;
}

fn createInfoPanel(cont: lvgl.Container) !void {
    const flex = cont.flex(.column, .{});
    var buf: [100]u8 = undefined;
    _ = try lvgl.Label.newFmt(flex, &buf, "GUI version: {any}", .{buildopts.semver}, .{});
}
