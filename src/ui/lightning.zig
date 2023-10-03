//! lightning main tab panel and other functionality.
//! all functions assume LVGL is init'ed and ui mutex is locked on entry.

const std = @import("std");

const comm = @import("../comm.zig");
const lvgl = @import("lvgl.zig");
const xfmt = @import("../xfmt.zig");

const logger = std.log.scoped(.ui_lnd);
/// label color mark start to make "label:" part of a "label: value"
/// in a different color.
const cmark = "#bbbbbb ";

var tab: struct {
    info: struct {
        alias: lvgl.Label,
        blockhash: lvgl.Label,
        currblock: lvgl.Label,
        npeers: lvgl.Label,
        pubkey: lvgl.Label,
        version: lvgl.Label,
    },
    balance: struct {
        avail: lvgl.Bar, // local vs remote
        local: lvgl.Label,
        remote: lvgl.Label,
        unsettled: lvgl.Label,
        pending: lvgl.Label,
        fees: lvgl.Label, // day, week, month
    },
    channels_cont: lvgl.FlexLayout,
} = undefined;

/// creates the tab content with all elements.
/// must be called only once at UI init.
pub fn initTabPanel(cont: lvgl.Container) !void {
    const parent = cont.flex(.column, .{});

    // info section
    {
        const card = try lvgl.Card.new(parent, "INFO", .{});
        const row = try lvgl.FlexLayout.new(card, .row, .{});
        row.setHeightToContent();
        row.setWidth(lvgl.sizePercent(100));
        row.clearFlag(.scrollable);
        // left column
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setHeightToContent();
        left.setWidth(lvgl.sizePercent(50));
        left.setPad(10, .row, .{});
        tab.info.alias = try lvgl.Label.new(left, "ALIAS\n", .{ .recolor = true });
        tab.info.pubkey = try lvgl.Label.new(left, "PUBKEY\n", .{ .recolor = true });
        tab.info.version = try lvgl.Label.new(left, "VERSION\n", .{ .recolor = true });
        // right column
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setHeightToContent();
        right.setWidth(lvgl.sizePercent(50));
        right.setPad(10, .row, .{});
        tab.info.currblock = try lvgl.Label.new(right, "HEIGHT\n", .{ .recolor = true });
        tab.info.blockhash = try lvgl.Label.new(right, "BLOCK HASH\n", .{ .recolor = true });
        tab.info.npeers = try lvgl.Label.new(right, "CONNECTED PEERS\n", .{ .recolor = true });
    }
    // balance section
    {
        const card = try lvgl.Card.new(parent, "BALANCE", .{});
        const row = try lvgl.FlexLayout.new(card, .row, .{});
        row.setWidth(lvgl.sizePercent(100));
        row.clearFlag(.scrollable);
        // left column
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setWidth(lvgl.sizePercent(50));
        left.setPad(10, .row, .{});
        tab.balance.avail = try lvgl.Bar.new(left);
        tab.balance.avail.setWidth(lvgl.sizePercent(90));
        const subrow = try lvgl.FlexLayout.new(left, .row, .{ .main = .space_between });
        subrow.setWidth(lvgl.sizePercent(90));
        subrow.setHeightToContent();
        tab.balance.local = try lvgl.Label.new(subrow, "LOCAL\n", .{ .recolor = true });
        tab.balance.remote = try lvgl.Label.new(subrow, "REMOTE\n", .{ .recolor = true });
        // right column
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setWidth(lvgl.sizePercent(50));
        right.setPad(10, .row, .{});
        tab.balance.pending = try lvgl.Label.new(right, "PENDING\n", .{ .recolor = true });
        tab.balance.unsettled = try lvgl.Label.new(right, "UNSETTLED\n", .{ .recolor = true });
        // bottom
        tab.balance.fees = try lvgl.Label.new(card, "ACCUMULATED FORWARDING FEES\n", .{ .recolor = true });
    }
    // channels section
    {
        const card = try lvgl.Card.new(parent, "CHANNELS", .{});
        tab.channels_cont = try lvgl.FlexLayout.new(card, .column, .{});
        tab.channels_cont.setHeightToContent();
        tab.channels_cont.setWidth(lvgl.sizePercent(100));
        tab.channels_cont.clearFlag(.scrollable);
        tab.channels_cont.setPad(10, .row, .{});
    }
}

/// updates the tab with new data from the report.
/// the tab must be inited first with initTabPanel.
pub fn updateTabPanel(rep: comm.Message.LightningReport) !void {
    var buf: [512]u8 = undefined;

    // info section
    try tab.info.alias.setTextFmt(&buf, cmark ++ "ALIAS#\n{s}", .{rep.alias});
    try tab.info.pubkey.setTextFmt(&buf, cmark ++ "PUBKEY#\n{s}\n{s}", .{ rep.pubkey[0..33], rep.pubkey[33..] });
    try tab.info.version.setTextFmt(&buf, cmark ++ "VERSION#\n{s}", .{rep.version});
    try tab.info.currblock.setTextFmt(&buf, cmark ++ "HEIGHT#\n{d}", .{rep.height});
    try tab.info.blockhash.setTextFmt(&buf, cmark ++ "BLOCK HASH#\n{s}\n{s}", .{ rep.hash[0..32], rep.hash[32..] });
    try tab.info.npeers.setTextFmt(&buf, cmark ++ "CONNECTED PEERS#\n{d}", .{rep.npeers});

    // balance section
    const local_pct: i32 = pct: {
        const total = rep.totalbalance.local + rep.totalbalance.remote;
        if (total == 0) {
            break :pct 0;
        }
        const v = @as(f64, @floatFromInt(rep.totalbalance.local)) / @as(f64, @floatFromInt(total));
        break :pct @intFromFloat(v * 100);
    };
    tab.balance.avail.setValue(local_pct);
    try tab.balance.local.setTextFmt(&buf, cmark ++ "LOCAL#\n{} sat", .{xfmt.imetric(rep.totalbalance.local)});
    try tab.balance.remote.setTextFmt(&buf, cmark ++ "REMOTE#\n{} sat", .{xfmt.imetric(rep.totalbalance.remote)});
    try tab.balance.pending.setTextFmt(&buf, cmark ++ "PENDING#\n{} sat", .{xfmt.imetric(rep.totalbalance.pending)});
    try tab.balance.unsettled.setTextFmt(&buf, cmark ++ "UNSETTLED#\n{}", .{xfmt.imetric(rep.totalbalance.unsettled)});
    try tab.balance.fees.setTextFmt(&buf, cmark ++ "ACCUMULATED FORWARDING FEES#\nDAY: {} sat  WEEK: {} sat  MONTH: {} sat", .{
        xfmt.umetric(rep.totalfees.day),
        xfmt.umetric(rep.totalfees.week),
        xfmt.umetric(rep.totalfees.month),
    });

    // channels section
    tab.channels_cont.deleteChildren();
    for (rep.channels) |ch| {
        const chbox = (try lvgl.Container.new(tab.channels_cont)).flex(.column, .{});
        chbox.setWidth(lvgl.sizePercent(100));
        chbox.setHeightToContent();
        _ = try switch (ch.state) {
            // TODO: sanitize peer_alias?
            .active => lvgl.Label.newFmt(chbox, &buf, "{s}", .{ch.peer_alias}, .{}),
            .inactive => lvgl.Label.newFmt(chbox, &buf, "#ff0000 [INACTIVE]# {s}", .{ch.peer_alias}, .{ .recolor = true }),
            .pending_open => lvgl.Label.new(chbox, "#00ff00 [PENDING OPEN]#", .{ .recolor = true }),
            .pending_close => lvgl.Label.new(chbox, "#ffff00 [PENDING CLOSE]#", .{ .recolor = true }),
        };
        const row = try lvgl.FlexLayout.new(chbox, .row, .{});
        row.setWidth(lvgl.sizePercent(100));
        row.clearFlag(.scrollable);
        row.setHeightToContent();

        // left column
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setWidth(lvgl.sizePercent(46));
        left.setHeightToContent();
        left.setPad(10, .row, .{});
        const bbar = try lvgl.Bar.new(left);
        bbar.setWidth(lvgl.sizePercent(100));
        const chan_local_pct: i32 = pct: {
            const total = ch.balance.local + ch.balance.remote;
            if (total == 0) {
                break :pct 0;
            }
            const v = @as(f64, @floatFromInt(ch.balance.local)) / @as(f64, @floatFromInt(total));
            break :pct @intFromFloat(v * 100);
        };
        bbar.setValue(chan_local_pct);
        const subrow = try lvgl.FlexLayout.new(left, .row, .{ .main = .space_between });
        subrow.setWidth(lvgl.sizePercent(100));
        subrow.setHeightToContent();
        const subcol1 = try lvgl.FlexLayout.new(subrow, .column, .{});
        subcol1.setPad(10, .row, .{});
        subcol1.setHeightToContent();
        const subcol2 = try lvgl.FlexLayout.new(subrow, .column, .{});
        subcol2.setPad(10, .row, .{});
        _ = try lvgl.Label.newFmt(subcol1, &buf, cmark ++ "LOCAL#\n{} sat", .{xfmt.imetric(ch.balance.local)}, .{ .recolor = true });
        _ = try lvgl.Label.newFmt(subcol1, &buf, cmark ++ "RECEIVED#\n{} sat", .{xfmt.imetric(ch.totalsats.received)}, .{ .recolor = true });
        if (ch.state == .active or ch.state == .inactive) {
            _ = try lvgl.Label.newFmt(subcol1, &buf, cmark ++ "BASE FEE#\n{} msat", .{xfmt.imetric(ch.fees.base)}, .{ .recolor = true });
            _ = try lvgl.Label.newFmt(subcol1, &buf, cmark ++ "FEE PPM#\n{d}", .{ch.fees.ppm}, .{ .recolor = true });
        }
        _ = try lvgl.Label.newFmt(subcol2, &buf, cmark ++ "REMOTE#\n{} sat", .{xfmt.imetric(ch.balance.remote)}, .{ .recolor = true });
        _ = try lvgl.Label.newFmt(subcol2, &buf, cmark ++ "SENT#\n{} sat", .{xfmt.imetric(ch.totalsats.sent)}, .{ .recolor = true });

        // right column
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setWidth(lvgl.sizePercent(54));
        right.setHeightToContent();
        right.setPad(10, .row, .{});
        if (ch.id) |id| {
            _ = try lvgl.Label.newFmt(right, &buf, cmark ++ "ID#\n{s}", .{id}, .{ .recolor = true });
        }
        _ = try lvgl.Label.newFmt(right, &buf, cmark ++ "FUNDING TX#\n{s}\n{s}", .{ ch.point[0..32], ch.point[32..] }, .{ .recolor = true });
        if (ch.closetxid) |tx| {
            _ = try lvgl.Label.newFmt(right, &buf, cmark ++ "CLOSING TX#\n{s}\n{s}", .{ tx[0..32], tx[32..] }, .{ .recolor = true });
        }
    }
}
