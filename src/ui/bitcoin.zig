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
    diskusage: lvgl.Label,
    conn_in: lvgl.Label,
    conn_out: lvgl.Label,
    balance: struct {
        avail_bar: lvgl.Bar,
        avail_pct: lvgl.Label,
        total: lvgl.Label,
        unconf: lvgl.Label,
        locked: lvgl.Label,
        reserved: lvgl.Label,
    },
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
        row.setHeightToContent();
        row.clearFlag(.scrollable);
        // left column
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setWidth(lvgl.sizePercent(50));
        left.setHeightToContent();
        left.setPad(10, .row, .{});
        tab.currblock = try lvgl.Label.new(left, "HEIGHT\n", .{ .recolor = true });
        tab.timestamp = try lvgl.Label.new(left, "TIMESTAMP\n", .{ .recolor = true });
        tab.blockhash = try lvgl.Label.new(left, "BLOCK HASH\n", .{ .recolor = true });
        // right column
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setWidth(lvgl.sizePercent(50));
        right.setHeightToContent();
        right.setPad(10, .row, .{});
        tab.diskusage = try lvgl.Label.new(right, "DISK USAGE\n", .{ .recolor = true });
        tab.conn_in = try lvgl.Label.new(right, "CONNECTIONS IN\n", .{ .recolor = true });
        tab.conn_out = try lvgl.Label.new(right, "CONNECTIONS OUT\n", .{ .recolor = true });
    }
    // balance section
    {
        const card = try lvgl.Card.new(parent, "ON-CHAIN BALANCE");
        const row = try lvgl.FlexLayout.new(card, .row, .{});
        row.setWidth(lvgl.sizePercent(100));
        row.setHeightToContent();
        row.clearFlag(.scrollable);
        // left column
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setWidth(lvgl.sizePercent(50));
        left.setPad(8, .top, .{});
        left.setPad(10, .row, .{});
        tab.balance.avail_bar = try lvgl.Bar.new(left);
        tab.balance.avail_pct = try lvgl.Label.new(left, "AVAILABLE\n", .{ .recolor = true });
        tab.balance.total = try lvgl.Label.new(left, "TOTAL\n", .{ .recolor = true });
        // right column
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setWidth(lvgl.sizePercent(50));
        right.setHeightToContent();
        right.setPad(10, .row, .{});
        tab.balance.locked = try lvgl.Label.new(right, "LOCKED\n", .{ .recolor = true });
        tab.balance.reserved = try lvgl.Label.new(right, "RESERVED\n", .{ .recolor = true });
        tab.balance.unconf = try lvgl.Label.new(right, "UNCONFIRMED\n", .{ .recolor = true });
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
}

/// updates the tab with new data from the report.
/// the tab must be inited first with initTabPanel.
pub fn updateTabPanel(rep: comm.Message.BitcoinReport) !void {
    var buf: [512]u8 = undefined;

    // blockchain section
    try tab.currblock.setTextFmt(&buf, cmark ++ "HEIGHT#\n{d}", .{rep.blocks});
    try tab.timestamp.setTextFmt(&buf, cmark ++ "TIMESTAMP#\n{}", .{xfmt.unix(rep.timestamp)});
    try tab.blockhash.setTextFmt(&buf, cmark ++ "BLOCK HASH#\n{s}\n{s}", .{ rep.hash[0..32], rep.hash[32..] });
    try tab.diskusage.setTextFmt(&buf, cmark ++ "DISK USAGE#\n{:.1}", .{fmt.fmtIntSizeBin(rep.diskusage)});
    try tab.conn_in.setTextFmt(&buf, cmark ++ "CONNECTIONS IN#\n{d}", .{rep.conn_in});
    try tab.conn_out.setTextFmt(&buf, cmark ++ "CONNECTIONS OUT#\n{d}", .{rep.conn_out});

    // balance section
    if (rep.balance) |bal| {
        const confpct: f32 = pct: {
            if (bal.confirmed > bal.total) {
                break :pct 100;
            }
            if (bal.total == 0) {
                break :pct 0;
            }
            const v = @as(f64, @floatFromInt(bal.confirmed)) / @as(f64, @floatFromInt(bal.total));
            break :pct @floatCast(v * 100);
        };
        tab.balance.avail_bar.setValue(@as(i32, @intFromFloat(@round(confpct))));
        try tab.balance.avail_pct.setTextFmt(&buf, cmark ++ "AVAILABLE#\n{} sat ({d:.1}%)", .{
            xfmt.imetric(bal.confirmed),
            confpct,
        });
        try tab.balance.total.setTextFmt(&buf, cmark ++ "TOTAL#\n{} sat", .{xfmt.imetric(bal.total)});
        try tab.balance.unconf.setTextFmt(&buf, cmark ++ "UNCONFIRMED#\n{} sat", .{xfmt.imetric(bal.unconfirmed)});
        try tab.balance.locked.setTextFmt(&buf, cmark ++ "LOCKED#\n{} sat", .{xfmt.imetric(bal.locked)});
        try tab.balance.reserved.setTextFmt(&buf, cmark ++ "RESERVED#\n{} sat", .{xfmt.imetric(bal.reserved)});
    }

    // mempool section
    const mempool_pct: f32 = pct: {
        if (rep.mempool.usage > rep.mempool.max) {
            break :pct 100;
        }
        if (rep.mempool.max == 0) {
            break :pct 0;
        }
        const v = @as(f64, @floatFromInt(rep.mempool.usage)) / @as(f64, @floatFromInt(rep.mempool.max));
        break :pct @floatCast(v * 100);
    };
    tab.mempool.usage_bar.setValue(@as(i32, @intFromFloat(@round(mempool_pct))));
    try tab.mempool.usage_lab.setTextFmt(&buf, "{:.1} " ++ cmark ++ "out of# {:.1} ({d:.1}%)", .{
        fmt.fmtIntSizeBin(rep.mempool.usage),
        fmt.fmtIntSizeBin(rep.mempool.max),
        mempool_pct,
    });
    try tab.mempool.txcount.setTextFmt(&buf, cmark ++ "TRANSACTIONS COUNT#\n{d}", .{rep.mempool.txcount});
    try tab.mempool.totalfee.setTextFmt(&buf, cmark ++ "TOTAL FEES#\n{d:10} BTC", .{rep.mempool.totalfee});
}
