//! settings main tab.
//! all functions assume LVGL is init'ed and ui mutex is locked on entry.
//!
//! TODO: at the moment, most of the code is still in C; need to port to zig from src/ui/c/ui.c

const std = @import("std");

const comm = @import("../comm.zig");
const lvgl = @import("lvgl.zig");
const symbol = @import("symbol.zig");

const logger = std.log.scoped(.ui);

/// label color mark start to make "label:" part of a "label: value"
/// in a different color.
const cmark = "#bbbbbb ";
/// button text
const textSwitch = "SWITCH";

/// the settings tab alive for the whole duration of the process.
var tab: struct {
    sysupdates: struct {
        card: lvgl.Card,
        chansel: lvgl.Dropdown,
        switchbtn: lvgl.TextButton,
        currchan: lvgl.Label,
    },
} = undefined;

/// holds last values received from the daemon.
var state: struct {
    curr_sysupdates_chan: ?comm.Message.SysupdatesChan = null,
} = .{};

/// creates a settings panel UI to control system updates channel.
/// must be called only once at program startup.
pub fn initSysupdatesPanel(cont: lvgl.Container) !lvgl.Card {
    tab.sysupdates.card = try lvgl.Card.new(cont, symbol.Loop ++ " SYSUPDATES", .{ .spinner = true });
    const l1 = try lvgl.Label.new(tab.sysupdates.card, "" //
    ++ "https://git.qcode.ch/nakamochi/sysupdates " // TODO: make this configurable?
    ++ "is the source of system updates.", .{});
    l1.setPad(15, .top, .{});
    l1.setWidth(lvgl.sizePercent(100));
    l1.setHeightToContent();

    const row = try lvgl.FlexLayout.new(tab.sysupdates.card, .row, .{});
    row.setWidth(lvgl.sizePercent(100));
    row.setHeightToContent();

    // left column
    const left = try lvgl.FlexLayout.new(row, .column, .{});
    left.flexGrow(1);
    left.setPad(10, .row, .{});
    left.setHeightToContent();
    tab.sysupdates.currchan = try lvgl.Label.new(left, cmark ++ "CURRENT CHANNEL:# unknown", .{ .recolor = true });
    tab.sysupdates.currchan.setHeightToContent();
    const lab = try lvgl.Label.new(left, "edge channel may contain some experimental and unstable features.", .{});
    lab.setWidth(lvgl.sizePercent(100));
    lab.setHeightToContent();

    // right column
    const right = try lvgl.FlexLayout.new(row, .column, .{});
    right.flexGrow(1);
    right.setPad(10, .row, .{});
    right.setHeightToContent();
    tab.sysupdates.chansel = try lvgl.Dropdown.newStatic(right, blk: {
        // items order must match that of the switch in update fn.
        break :blk @tagName(comm.Message.SysupdatesChan.stable) // index 0
        ++ "\n" ++ @tagName(comm.Message.SysupdatesChan.edge); // index 1
    });
    tab.sysupdates.chansel.setWidth(lvgl.sizePercent(100));
    tab.sysupdates.chansel.setText(""); // show no pre-selected value
    _ = tab.sysupdates.chansel.on(.value_changed, nm_sysupdates_chansel_changed, null);
    tab.sysupdates.switchbtn = try lvgl.TextButton.new(right, textSwitch);
    tab.sysupdates.switchbtn.setWidth(lvgl.sizePercent(100));
    // disable channel switch button 'till data received from the daemon
    // or user-selected value.
    tab.sysupdates.switchbtn.disable();
    _ = tab.sysupdates.switchbtn.on(.click, nm_sysupdates_switch_click, null);

    return tab.sysupdates.card;
}

/// updates the UI with the data from the provided settings arg.
pub fn update(sett: comm.Message.Settings) !void {
    var buf: [512]u8 = undefined;
    try tab.sysupdates.currchan.setTextFmt(&buf, cmark ++ "CURRENT CHANNEL:# {s}", .{@tagName(sett.sysupdates.channel)});
    state.curr_sysupdates_chan = sett.sysupdates.channel;
}

export fn nm_sysupdates_chansel_changed(_: *lvgl.LvEvent) void {
    var buf = [_]u8{0} ** 32;
    const name = tab.sysupdates.chansel.getSelectedStr(&buf);
    const chan = std.meta.stringToEnum(comm.Message.SysupdatesChan, name) orelse return;
    if (state.curr_sysupdates_chan) |curr_chan| {
        if (chan != curr_chan) {
            tab.sysupdates.switchbtn.enable();
            tab.sysupdates.chansel.clearText(); // show selected value
        } else {
            tab.sysupdates.switchbtn.disable();
            tab.sysupdates.chansel.setText(""); // hide selected value
        }
    } else {
        tab.sysupdates.switchbtn.enable();
        tab.sysupdates.chansel.clearText(); // show selected value
    }
}

export fn nm_sysupdates_switch_click(_: *lvgl.LvEvent) void {
    var buf = [_]u8{0} ** 32;
    const name = tab.sysupdates.chansel.getSelectedStr(&buf);
    switchSysupdates(name) catch |err| logger.err("switchSysupdates: {any}", .{err});
}

fn switchSysupdates(name: []const u8) !void {
    const chan = std.meta.stringToEnum(comm.Message.SysupdatesChan, name) orelse return error.InvalidSysupdateChannel;
    logger.debug("switching sysupdates to channel {}", .{chan});

    tab.sysupdates.switchbtn.disable();
    tab.sysupdates.switchbtn.label.setTextStatic("UPDATING ...");
    tab.sysupdates.chansel.disable();
    tab.sysupdates.card.spin(.on);
    errdefer {
        tab.sysupdates.card.spin(.off);
        tab.sysupdates.chansel.enable();
        tab.sysupdates.switchbtn.enable();
        tab.sysupdates.switchbtn.label.setTextStatic(textSwitch);
    }

    try comm.pipeWrite(.{ .switch_sysupdates = chan });
}
