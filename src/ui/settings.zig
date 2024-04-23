//! settings main tab.
//! all functions assume LVGL is init'ed and ui mutex is locked on entry.
//!
//! TODO: at the moment, most of the code is still in C; need to port to zig from src/ui/c/ui.c

const std = @import("std");

const comm = @import("../comm.zig");
const types = @import("../types.zig");
const lvgl = @import("lvgl.zig");
const symbol = @import("symbol.zig");
const widget = @import("widget.zig");

const logger = std.log.scoped(.ui);

/// label color mark start to make "label:" part of a "label: value"
/// in a different color.
const cmark = "#bbbbbb ";
/// button labels and other text
const textSwitch = "SWITCH";
const textChange = "CHANGE";
const textDisable = "DISABLE";
const textSlockBtnEnable = "SET PIN CODE";
const textSlockDisabled = "screenlock is disabled\nset a pin code to activate";
const textSlockEnabled = "screenlock is enabled\nit activates once in standby mode";

// global allocator set in init.
// must be set before any call into pub funcs in this module.
pub var allocator: std.mem.Allocator = undefined;

/// the settings tab alive for the whole duration of the process.
var tab: struct {
    nodename: struct {
        card: lvgl.Card,
        currname: lvgl.Label,
        textarea: lvgl.TextArea,
        changebtn: lvgl.TextButton,
    },
    screenlock: struct {
        card: lvgl.Card,
        textlabel: lvgl.Label,
        enbtn: lvgl.TextButton,
        disbtn: lvgl.TextButton,

        setpin_win: lvgl.Window,
        setpin_label: lvgl.Label,
        setpin_input: lvgl.TextArea,

        fn beginSetPin(self: *@This()) !void {
            self.setpin_win = try lvgl.Window.newTop(60, "SET SCREENLOCK PIN CODE");
            const wincont = self.setpin_win.content().flex(.column, .{ .cross = .center, .track = .center });
            self.setpin_input = try lvgl.TextArea.new(wincont, .{ .password_mode = true });
            self.setpin_input.posAlign(.top_mid, 0, 20);
            _ = self.setpin_input.on(.ready, nm_screenlock_pincode_input, null);
            self.setpin_label = try lvgl.Label.new(wincont, null, .{});
            self.setpin_label.posAlignTo(self.setpin_input, .out_bottom_mid, 0, 10);
            self.setpin_label.setTextStatic("please enter a new pin code");
            const kb = try lvgl.Keyboard.new(self.setpin_win, .number);
            kb.attach(self.setpin_input);
        }

        fn endSetPin(self: @This()) void {
            self.setpin_win.destroy();
        }
    },
    sysupdates: struct {
        card: lvgl.Card,
        chansel: lvgl.Dropdown,
        switchbtn: lvgl.TextButton,
        currchan: lvgl.Label,
    },
} = undefined;

/// holds last values received from the daemon.
var state: struct {
    // node name
    nodename_change_inprogress: bool = false,
    curr_nodename: types.BufTrimString(std.posix.HOST_NAME_MAX) = .{},
    // screenlock
    slock_pin_input1: ?[]const u8 = null, // verified against a second time input
    // sysupdates channel
    curr_sysupdates_chan: ?comm.Message.SysupdatesChan = null,
} = .{};

/// creates a settings panel allowing to change hostname and lnd alias,
/// aka nodename.
pub fn initNodenamePanel(cont: lvgl.Container) !lvgl.Card {
    tab.nodename.card = try lvgl.Card.new(cont, symbol.Edit ++ " NODE NAME", .{ .spinner = true });

    const row = try lvgl.FlexLayout.new(tab.nodename.card, .row, .{});
    row.setWidth(lvgl.sizePercent(100));
    row.setHeightToContent();

    // left column
    const left = try lvgl.FlexLayout.new(row, .column, .{ .height = .content });
    left.flexGrow(1);
    left.setPad(10, .row, .{});

    tab.nodename.currname = try lvgl.Label.new(left, cmark ++ "CURRENT NAME:# unknown", .{ .recolor = true });
    tab.nodename.currname.setHeightToContent();

    const lab = try lvgl.Label.new(left, "the name is visible on a local network as well as lightning.", .{});
    lab.setWidth(lvgl.sizePercent(100));
    lab.setHeightToContent();
    lab.setPad(0, .right, .{});

    // right column
    const right = try lvgl.FlexLayout.new(row, .column, .{ .height = .content });
    right.flexGrow(1);
    right.setPad(10, .row, .{});
    right.setPad(0, .column, .{});

    tab.nodename.textarea = try lvgl.TextArea.new(right, .{
        .maxlen = std.posix.HOST_NAME_MAX,
        .oneline = true,
    });
    tab.nodename.textarea.setWidth(lvgl.sizePercent(100));
    _ = tab.nodename.textarea.on(.all, nm_nodename_textarea_input, null);

    tab.nodename.changebtn = try lvgl.TextButton.new(right, textChange);
    tab.nodename.changebtn.setWidth(lvgl.sizePercent(100));
    tab.nodename.changebtn.setPad(0, .left, .{});

    // disable name change 'till data received from the daemon.
    tab.nodename.textarea.disable();
    tab.nodename.changebtn.disable();
    _ = tab.nodename.changebtn.on(.click, nm_nodename_change_btn_click, null);

    return tab.nodename.card;
}

/// creates a settings panel for setting screenlock pin code.
pub fn initScreenlockPanel(cont: lvgl.Container) !lvgl.Card {
    tab.screenlock.card = try lvgl.Card.new(cont, symbol.EyeClose ++ " SCREENLOCK", .{ .spinner = true });

    const row = try lvgl.FlexLayout.new(tab.screenlock.card, .row, .{});
    row.setWidth(lvgl.sizePercent(100));
    row.setHeightToContent();

    // left column
    const left = try lvgl.FlexLayout.new(row, .column, .{ .height = .content });
    left.flexGrow(1);
    left.setPad(10, .row, .{});
    tab.screenlock.textlabel = try lvgl.Label.new(left, null, .{});
    tab.screenlock.textlabel.setTextStatic("no info available yet");

    // right column
    const right = try lvgl.FlexLayout.new(row, .column, .{ .height = .content });
    right.flexGrow(1);
    right.setPad(10, .row, .{});
    tab.screenlock.enbtn = try lvgl.TextButton.new(right, textSlockBtnEnable);
    tab.screenlock.enbtn.setWidth(lvgl.sizePercent(100));
    tab.screenlock.enbtn.hide();
    _ = tab.screenlock.enbtn.on(.click, nm_screenlock_enbtn_click, null);
    tab.screenlock.disbtn = try lvgl.TextButton.new(right, textDisable);
    tab.screenlock.disbtn.setWidth(lvgl.sizePercent(100));
    tab.screenlock.disbtn.addStyle(lvgl.nm_style_btn_red(), .{});
    tab.screenlock.disbtn.hide();
    _ = tab.screenlock.disbtn.on(.click, nm_screenlock_disbtn_click, null);

    return tab.screenlock.card;
}

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
    // sysupdates channel
    var buf: [512]u8 = undefined;
    try tab.sysupdates.currchan.setTextFmt(&buf, cmark ++ "CURRENT CHANNEL:# {s}", .{@tagName(sett.sysupdates.channel)});
    state.curr_sysupdates_chan = sett.sysupdates.channel;

    // nodename
    state.curr_nodename.set(sett.hostname);
    try tab.nodename.currname.setTextFmt(&buf, cmark ++ "CURRENT NAME:# {s}", .{state.curr_nodename.val()});
    if (state.nodename_change_inprogress) {
        const currname = tab.nodename.textarea.text();
        if (std.mem.eql(u8, sett.hostname, currname)) {
            state.nodename_change_inprogress = false;
            tab.nodename.textarea.setText("");
            tab.nodename.textarea.enable();
            tab.nodename.card.spin(.off);
        }
    } else {
        tab.nodename.textarea.enable();
        const currname = state.curr_nodename.val();
        const newname = tab.nodename.textarea.text();
        if (newname.len > 0 and !std.mem.eql(u8, newname, currname)) {
            tab.nodename.changebtn.enable();
        } else {
            tab.nodename.changebtn.disable();
        }
    }

    // screenlock
    tab.screenlock.card.spin(.off);
    if (sett.slock_enabled) {
        tab.screenlock.textlabel.setTextStatic(textSlockEnabled);
        tab.screenlock.enbtn.hide();
        tab.screenlock.disbtn.enable();
        tab.screenlock.disbtn.show();
    } else {
        tab.screenlock.textlabel.setTextStatic(textSlockDisabled);
        tab.screenlock.enbtn.enable();
        tab.screenlock.enbtn.show();
        tab.screenlock.disbtn.hide();
    }
}

export fn nm_nodename_textarea_input(e: *lvgl.LvEvent) void {
    switch (e.code()) {
        .focus => widget.keyboardOn(tab.nodename.textarea),
        .defocus, .ready, .cancel => widget.keyboardOff(),
        .value_changed => {
            const currname = state.curr_nodename.val();
            const newname = tab.nodename.textarea.text();
            if (currname.len > 0 and newname.len > 0 and !std.mem.eql(u8, newname, currname)) {
                tab.nodename.changebtn.enable();
            } else {
                tab.nodename.changebtn.disable();
            }
        },
        else => {},
    }
}

export fn nm_nodename_change_btn_click(_: *lvgl.LvEvent) void {
    const newname = tab.nodename.textarea.text();
    comm.pipeWrite(.{ .set_nodename = newname }) catch |err| {
        logger.err("nodename change pipe write: {!}", .{err});
        return;
    };
    state.nodename_change_inprogress = true;
    tab.nodename.changebtn.disable();
    tab.nodename.textarea.disable();
    tab.nodename.card.spin(.on);
}

export fn nm_screenlock_enbtn_click(_: *lvgl.LvEvent) void {
    tab.screenlock.beginSetPin() catch |err| {
        logger.err("screenlock.beginSetPin: {!}", .{err});
    };
}

export fn nm_screenlock_pincode_input(_: *lvgl.LvEvent) void {
    // first time input; prompt user for second input to verify
    if (state.slock_pin_input1 == null) {
        state.slock_pin_input1 = allocator.dupe(u8, tab.screenlock.setpin_input.text()) catch |err| {
            logger.err("unable to continue setting screenlock pin code: {!}", .{err});
            tab.screenlock.endSetPin();
            return;
        };
        tab.screenlock.setpin_label.setTextStatic("please enter the pin once more to verify");
        tab.screenlock.setpin_input.setText("");
        return;
    }

    // ensure first and second time inputs match
    const pininput2 = tab.screenlock.setpin_input.text();
    if (!std.mem.eql(u8, pininput2, state.slock_pin_input1.?)) {
        allocator.free(state.slock_pin_input1.?);
        state.slock_pin_input1 = null;
        tab.screenlock.setpin_label.setTextStatic("pin codes mismatch, please try again");
        tab.screenlock.setpin_input.setText("");
        return;
    }

    // send the pin code to nd and return to the main settings screen
    defer {
        tab.screenlock.endSetPin();
        allocator.free(state.slock_pin_input1.?);
        state.slock_pin_input1 = null;
    }
    tab.screenlock.card.spin(.on);
    tab.screenlock.enbtn.disable();
    comm.pipeWrite(.{ .slock_set_pincode = pininput2 }) catch |err| {
        logger.err("comm slock_set_pincode: {!}", .{err});
        tab.screenlock.card.spin(.off);
        tab.screenlock.enbtn.enable();
    };
}

export fn nm_screenlock_disbtn_click(_: *lvgl.LvEvent) void {
    tab.screenlock.card.spin(.on);
    tab.screenlock.disbtn.disable();
    comm.pipeWrite(.{ .slock_set_pincode = null }) catch |err| {
        logger.err("comm slock_set_pincode(null): {!}", .{err});
        tab.screenlock.card.spin(.off);
        tab.screenlock.disbtn.enable();
    };
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
