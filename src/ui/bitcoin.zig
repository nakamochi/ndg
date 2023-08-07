//! bitcoin main tab panel.
//! all functions assume LVGL is init'ed and ui mutex is locked on entry.

const std = @import("std");
const fmt = std.fmt;

const lvgl = @import("lvgl.zig");
const comm = @import("../comm.zig");
const xfmt = @import("../xfmt.zig");

const logger = std.log.scoped(.ui);
/// label color mark start to make "label:" part of a "label: value"
/// in a different color.
const cmark = "#bbbbbb ";

var tab: struct {
    // blockchain section
    currblock: lvgl.Label,
    timestamp: lvgl.Label,
    blockhash: lvgl.Label,
    // usage section
    diskusage: lvgl.Label,
    conn_in: lvgl.Label,
    conn_out: lvgl.Label,
    // mempool section
    mempool: struct {
        txcount: lvgl.Label,
        totalfee: lvgl.Label,
        usage_bar: lvgl.Bar,
        usage_lab: lvgl.Label,
    },
} = undefined;

/// creates the tab content with all elements.
/// must be called only once at UI init.
pub fn initTabPanel(cont: lvgl.Container) !void {
    const parent = cont.flex(.column, .{});

    // blockchain section
    {
        const card = try lvgl.Card.new(parent, "BLOCKCHAIN");
        const row = try lvgl.FlexLayout.new(card, .row, .{});
        row.setWidth(lvgl.sizePercent(100));
        row.clearFlag(.scrollable);
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setWidth(lvgl.sizePercent(50));
        left.setPad(10, .row, .{});
        tab.currblock = try lvgl.Label.new(left, "HEIGHT\n", .{ .recolor = true });
        tab.timestamp = try lvgl.Label.new(left, "TIMESTAMP\n", .{ .recolor = true });
        tab.blockhash = try lvgl.Label.new(row, "BLOCK HASH\n", .{ .recolor = true });
        tab.blockhash.flexGrow(1);
    }

    // mempool section
    {
        const card = try lvgl.Card.new(parent, "MEMPOOL");
        const row = try lvgl.FlexLayout.new(card, .row, .{});
        row.setWidth(lvgl.sizePercent(100));
        row.clearFlag(.scrollable);
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setWidth(lvgl.sizePercent(50));
        left.setPad(8, .top, .{});
        left.setPad(10, .row, .{});
        tab.mempool.usage_bar = try lvgl.Bar.new(left);
        tab.mempool.usage_lab = try lvgl.Label.new(left, "0Mb out of 0Mb (0%)", .{ .recolor = true });
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setWidth(lvgl.sizePercent(50));
        right.setPad(10, .row, .{});
        tab.mempool.txcount = try lvgl.Label.new(right, "TRANSACTIONS COUNT\n", .{ .recolor = true });
        tab.mempool.totalfee = try lvgl.Label.new(right, "TOTAL FEES\n", .{ .recolor = true });
    }

    // usage section
    {
        const card = try lvgl.Card.new(parent, "USAGE");
        const row = try lvgl.FlexLayout.new(card, .row, .{});
        row.setWidth(lvgl.sizePercent(100));
        row.clearFlag(.scrollable);
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setWidth(lvgl.sizePercent(50));
        left.setPad(10, .row, .{});
        tab.diskusage = try lvgl.Label.new(left, "DISK USAGE\n", .{ .recolor = true });
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setWidth(lvgl.sizePercent(50));
        right.setPad(10, .row, .{});
        tab.conn_in = try lvgl.Label.new(right, "CONNECTIONS IN\n", .{ .recolor = true });
        tab.conn_out = try lvgl.Label.new(right, "CONNECTIONS OUT\n", .{ .recolor = true });
    }
}

/// updates the tab with new data from the report.
/// the tab must be inited first with initTabPanel.
pub fn updateTabPanel(rep: comm.Message.BitcoindReport) !void {
    var buf: [512]u8 = undefined;

    // blockchain section
    try tab.currblock.setTextFmt(&buf, cmark ++ "HEIGHT#\n{d}", .{rep.blocks});
    try tab.timestamp.setTextFmt(&buf, cmark ++ "TIMESTAMP#\n{}", .{xfmt.unix(rep.timestamp)});
    try tab.blockhash.setTextFmt(&buf, cmark ++ "BLOCK HASH#\n{s}\n{s}", .{ rep.hash[0..32], rep.hash[32..] });

    // mempool section
    const mempool_pct: f32 = pct: {
        if (rep.mempool.usage > rep.mempool.max) {
            break :pct 100;
        }
        if (rep.mempool.max == 0) {
            break :pct 0;
        }
        const v = @intToFloat(f64, rep.mempool.usage) / @intToFloat(f64, rep.mempool.max);
        break :pct @floatCast(f32, v * 100);
    };
    tab.mempool.usage_bar.setValue(@floatToInt(i32, @round(mempool_pct)));
    try tab.mempool.usage_lab.setTextFmt(&buf, "{:.1} " ++ cmark ++ "out of# {:.1} ({d:.1}%)", .{
        fmt.fmtIntSizeBin(rep.mempool.usage),
        fmt.fmtIntSizeBin(rep.mempool.max),
        mempool_pct,
    });
    try tab.mempool.txcount.setTextFmt(&buf, cmark ++ "TRANSACTIONS COUNT#\n{d}", .{rep.mempool.txcount});
    try tab.mempool.totalfee.setTextFmt(&buf, cmark ++ "TOTAL FEES#\n{d:10} BTC", .{rep.mempool.totalfee});

    // usage section
    try tab.diskusage.setTextFmt(&buf, cmark ++ "DISK USAGE#\n{:.1}", .{fmt.fmtIntSizeBin(rep.diskusage)});
    try tab.conn_in.setTextFmt(&buf, cmark ++ "CONNECTIONS IN#\n{d}", .{rep.conn_in});
    try tab.conn_out.setTextFmt(&buf, cmark ++ "CONNECTIONS OUT#\n{d}", .{rep.conn_out});
}
