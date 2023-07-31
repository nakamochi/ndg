//! bitcoin main tab panel.
//! all functions assume LVGL is init'ed and ui mutex is locked on entry.

const std = @import("std");
const fmt = std.fmt;

const lvgl = @import("lvgl.zig");
const comm = @import("../comm.zig");
const xfmt = @import("../xfmt.zig");

const logger = std.log.scoped(.ui);

var tab: struct {
    // blockchain
    currblock: *lvgl.LvObj, // label
    timestamp: *lvgl.LvObj, // label
    blockhash: *lvgl.LvObj, // label
    // usage
    diskusage: *lvgl.LvObj, // label
    conn_in: *lvgl.LvObj, // label
    conn_out: *lvgl.LvObj, // label
} = undefined;

pub fn initTabPanel(parent: *lvgl.LvObj) !void {
    parent.flexFlow(.column);

    const box1 = try lvgl.createFlexObject(parent, .column);
    box1.setHeightToContent();
    box1.setWidth(lvgl.sizePercent(100));
    const l1 = try lvgl.createLabel(box1, "BLOCKCHAIN", .{});
    l1.addStyle(lvgl.nm_style_title(), .{});

    tab.currblock = try lvgl.createLabel(box1, "current height: 0", .{});
    tab.timestamp = try lvgl.createLabel(box1, "timestamp:", .{});
    tab.blockhash = try lvgl.createLabel(box1, "block hash:", .{});

    const box2 = try lvgl.createFlexObject(parent, .column);
    box2.setHeightToContent();
    box2.setWidth(lvgl.sizePercent(100));
    const l2 = try lvgl.createLabel(box2, "USAGE", .{});
    l2.addStyle(lvgl.nm_style_title(), .{});

    tab.diskusage = try lvgl.createLabel(box2, "disk usage:", .{});
    tab.conn_in = try lvgl.createLabel(box2, "connections in:", .{});
    tab.conn_out = try lvgl.createLabel(box2, "connections out:", .{});
}

pub fn updateTabPanel(rep: comm.Message.BitcoindReport) !void {
    var buf: [512]u8 = undefined;
    var s = try fmt.bufPrintZ(&buf, "height: {d}", .{rep.blocks});
    tab.currblock.setLabelText(s);
    s = try fmt.bufPrintZ(&buf, "timestamp: {}", .{xfmt.unix(rep.timestamp)});
    //s = try fmt.bufPrintZ(&buf, "timestamp: {}", .{rep.timestamp});
    tab.timestamp.setLabelText(s);
    s = try fmt.bufPrintZ(&buf, "block hash: {s}", .{rep.hash});
    tab.blockhash.setLabelText(s);

    s = try fmt.bufPrintZ(&buf, "disk usage: {.1}", .{fmt.fmtIntSizeBin(rep.diskusage)});
    tab.diskusage.setLabelText(s);
    s = try fmt.bufPrintZ(&buf, "connections in: {d}", .{rep.conn_in});
    tab.conn_in.setLabelText(s);
    s = try fmt.bufPrintZ(&buf, "connections out: {d}", .{rep.conn_out});
    tab.conn_out.setLabelText(s);
}
