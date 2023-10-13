//! lightning main tab panel and other functionality.
//! all functions assume LVGL is init'ed and ui mutex is locked on entry.

const std = @import("std");

const comm = @import("../comm.zig");
const lvgl = @import("lvgl.zig");
const symbol = @import("symbol.zig");
const types = @import("../types.zig");
const xfmt = @import("../xfmt.zig");
const widget = @import("widget.zig");

const logger = std.log.scoped(.ui_lnd);

const appBitBanana = "BitBanana";
const appZeus = "Zeus";
const app_description = std.ComptimeStringMap([:0]const u8, .{
    .{
        appBitBanana,
        \\lightning node management for android.
        \\website: https://bitbanana.app
        \\
        \\follow the website instructions for 
        \\installing the app. once installed,
        \\scan the QR code using the app and 
        \\complete the setup process.
    },
    .{
        appZeus,
        \\available for android and iOS.
        \\website: https://zeusln.app
        \\
        \\follow the website instructions for
        \\installing the app. once installed,
        \\scan the QR code using the app and
        \\complete the setup process.
    },
});

/// label color mark start to make "label:" part of a "label: value"
/// in a different color.
const cmark = "#bbbbbb ";

/// a hack to prevent tabview from switching to the next tab
/// on a scroll event when deleting all children of tab.seed_setup.topwin.
/// defined in ui/c/ui.c
extern fn preserve_main_active_tab() void;

var tab: struct {
    allocator: std.mem.Allocator,

    info: struct {
        card: lvgl.Card, // parent
        alias: lvgl.Label,
        blockhash: lvgl.Label,
        currblock: lvgl.Label,
        npeers: lvgl.Label,
        pubkey: lvgl.Label,
        version: lvgl.Label,
    },
    balance: struct {
        card: lvgl.Card, // parent
        avail: lvgl.Bar, // local vs remote
        local: lvgl.Label,
        remote: lvgl.Label,
        unsettled: lvgl.Label,
        pending: lvgl.Label,
        fees: lvgl.Label, // day, week, month
    },
    channels: struct {
        card: lvgl.Card,
        cont: lvgl.FlexLayout,
    },
    pairing: lvgl.Card,
    reset: lvgl.Card,

    // elements visibile during lnd startup.
    startup: lvgl.FlexLayout,

    // TODO: support wallet manual unlock (LightningError.code.Locked)

    // elements when lnd wallet is uninitialized.
    // the actual seed init is in `seed_setup` field.
    nowallet: lvgl.FlexLayout,

    seed_setup: ?struct {
        topwin: lvgl.Window,
        arena: *std.heap.ArenaAllocator, // all non-UI elements are alloc'ed here
        mnemonic: ?types.StringList = null, // 24 words genseed result
        pairing: ?struct {
            // app_description key to connection URL.
            // keys are static, values are heap-alloc'ed in `setupPairing`.
            urlmap: std.StringArrayHashMap([]const u8),
            appsel: lvgl.Dropdown,
            appdesc: lvgl.Label,
            qr: lvgl.QrCode, // QR-encoded connection URL
            qrerr: lvgl.Label, // an error message when QR rendering fails
        } = null,
    } = null,

    fn initSetup(self: *@This(), topwin: lvgl.Window) !void {
        var arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(tab.allocator);
        self.seed_setup = .{ .arena = arena, .topwin = topwin };
    }

    fn destroySetup(self: *@This()) void {
        if (self.seed_setup == null) {
            return;
        }
        self.seed_setup.?.topwin.destroy();
        self.seed_setup.?.arena.deinit();
        self.allocator.destroy(self.seed_setup.?.arena);
        self.seed_setup = null;
        preserve_main_active_tab();
    }

    fn setMode(self: *@This(), m: enum { setup, startup, operational }) void {
        switch (m) {
            .setup => {
                self.nowallet.show();
                self.startup.hide();
                self.info.card.hide();
                self.balance.card.hide();
                self.channels.card.hide();
                self.pairing.hide();
                self.reset.hide();
            },
            .startup => {
                self.startup.show();
                self.nowallet.hide();
                self.info.card.hide();
                self.balance.card.hide();
                self.channels.card.hide();
                self.pairing.hide();
                self.reset.hide();
            },
            .operational => {
                self.info.card.show();
                self.balance.card.show();
                self.channels.card.show();
                self.pairing.show();
                self.reset.show();
                self.nowallet.hide();
                self.startup.hide();
            },
        }
    }
} = undefined;

/// creates the tab content with all elements.
/// must be called only once at UI init.
pub fn initTabPanel(allocator: std.mem.Allocator, cont: lvgl.Container) !void {
    tab.allocator = allocator;
    const parent = cont.flex(.column, .{});
    const recolor: lvgl.Label.Opt = .{ .recolor = true };

    // startup
    {
        tab.startup = try lvgl.FlexLayout.new(parent, .row, .{ .all = .center });
        tab.startup.resizeToMax();
        _ = try lvgl.Spinner.new(tab.startup);
        _ = try lvgl.Label.new(tab.startup, "STARTING UP ...", .{});
    }

    // uninitialized wallet state
    {
        tab.nowallet = try lvgl.FlexLayout.new(parent, .column, .{ .all = .center });
        tab.nowallet.resizeToMax();
        tab.nowallet.setPad(10, .row, .{});
        _ = try lvgl.Label.new(tab.nowallet, "lightning wallet is uninitialized.\ntap the button to start the setup process.", .{});
        const btn = try lvgl.TextButton.new(tab.nowallet, "SETUP NEW WALLET");
        btn.setWidth(lvgl.sizePercent(50));
        _ = btn.on(.click, nm_lnd_setup_click, null);
    }

    // regular operational mode

    // info section
    {
        tab.info.card = try lvgl.Card.new(parent, "INFO", .{});
        const row = try lvgl.FlexLayout.new(tab.info.card, .row, .{});
        row.setHeightToContent();
        row.setWidth(lvgl.sizePercent(100));
        row.clearFlag(.scrollable);
        // left column
        const left = try lvgl.FlexLayout.new(row, .column, .{});
        left.setHeightToContent();
        left.setWidth(lvgl.sizePercent(50));
        left.setPad(10, .row, .{});
        tab.info.alias = try lvgl.Label.new(left, "ALIAS\n", recolor);
        tab.info.pubkey = try lvgl.Label.new(left, "PUBKEY\n", recolor);
        tab.info.version = try lvgl.Label.new(left, "VERSION\n", recolor);
        // right column
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setHeightToContent();
        right.setWidth(lvgl.sizePercent(50));
        right.setPad(10, .row, .{});
        tab.info.currblock = try lvgl.Label.new(right, "HEIGHT\n", recolor);
        tab.info.blockhash = try lvgl.Label.new(right, "BLOCK HASH\n", recolor);
        tab.info.npeers = try lvgl.Label.new(right, "CONNECTED PEERS\n", recolor);
    }
    // balance section
    {
        tab.balance.card = try lvgl.Card.new(parent, "BALANCE", .{});
        const row = try lvgl.FlexLayout.new(tab.balance.card, .row, .{});
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
        tab.balance.local = try lvgl.Label.new(subrow, "LOCAL\n", recolor);
        tab.balance.remote = try lvgl.Label.new(subrow, "REMOTE\n", recolor);
        // right column
        const right = try lvgl.FlexLayout.new(row, .column, .{});
        right.setWidth(lvgl.sizePercent(50));
        right.setPad(10, .row, .{});
        tab.balance.pending = try lvgl.Label.new(right, "PENDING\n", recolor);
        tab.balance.unsettled = try lvgl.Label.new(right, "UNSETTLED\n", recolor);
        // bottom
        tab.balance.fees = try lvgl.Label.new(tab.balance.card, "ACCUMULATED FORWARDING FEES\n", recolor);
    }
    // channels section
    {
        tab.channels.card = try lvgl.Card.new(parent, "CHANNELS", .{});
        tab.channels.cont = try lvgl.FlexLayout.new(tab.channels.card, .column, .{});
        tab.channels.cont.setHeightToContent();
        tab.channels.cont.setWidth(lvgl.sizePercent(100));
        tab.channels.cont.clearFlag(.scrollable);
        tab.channels.cont.setPad(10, .row, .{});
    }
    // pairing section
    {
        tab.pairing = try lvgl.Card.new(parent, "PAIRING", .{});
        const row = try lvgl.FlexLayout.new(tab.pairing, .row, .{ .width = lvgl.sizePercent(100), .height = .content });
        const lb = try lvgl.Label.new(row, "tap the button on the right to start pairing with a phone.", .{});
        lb.flexGrow(1);
        const btn = try lvgl.TextButton.new(row, "PAIR");
        btn.flexGrow(1);
        _ = btn.on(.click, nm_lnd_pair_click, null);
    }
    // node reset section
    {
        tab.reset = try lvgl.Card.new(parent, symbol.Warning ++ " FACTORY RESET", .{});
        const row = try lvgl.FlexLayout.new(tab.reset, .row, .{ .width = lvgl.sizePercent(100), .height = .content });
        const lb = try lvgl.Label.new(row, "resetting the node restores its state to a factory setup.", .{});
        lb.flexGrow(1);
        const btn = try lvgl.TextButton.new(row, "RESET");
        btn.flexGrow(1);
        btn.addStyle(lvgl.nm_style_btn_red(), .{});
        _ = btn.on(.click, nm_lnd_reset_click, null);
    }

    tab.setMode(.startup);
}

/// updates the tab with new data from a `comm.Message` tagged with .lightning_xxx,
/// the tab must be inited first with initTabPanel.
pub fn updateTabPanel(msg: comm.Message) !void {
    return switch (msg) {
        .lightning_error => |lnerr| switch (lnerr.code) {
            .uninitialized => tab.setMode(.setup),
            // TODO: handle "wallet locked" and other errors
            else => tab.setMode(.startup),
        },
        .lightning_report => |rep| blk: {
            tab.setMode(.operational);
            break :blk updateReport(rep);
        },
        .lightning_genseed_result => |mnemonic| confirmSetupSeed(mnemonic),
        .lightning_ctrlconn => |conn| setupPairing(conn),
        else => error.UnsupportedMessage,
    };
}

export fn nm_lnd_setup_click(_: *lvgl.LvEvent) void {
    startSeedSetup() catch |err| logger.err("startSeedSetup: {any}", .{err});
}

export fn nm_lnd_pair_click(_: *lvgl.LvEvent) void {
    startPairing() catch |err| logger.err("startPairing: {any}", .{err});
}

export fn nm_lnd_reset_click(_: *lvgl.LvEvent) void {
    promptNodeReset() catch |err| logger.err("resetNode: {any}", .{err});
}

export fn nm_lnd_setup_finish(_: *lvgl.LvEvent) void {
    tab.destroySetup();
}

fn startSeedSetup() !void {
    const win = try lvgl.Window.newTop(60, " " ++ symbol.LightningBolt ++ " LIGHTNING SETUP");
    try tab.initSetup(win);
    errdefer tab.destroySetup(); // TODO: display an error instead
    const wincont = win.content().flex(.row, .{ .all = .center });
    _ = try lvgl.Spinner.new(wincont);
    _ = try lvgl.Label.new(wincont, "GENERATING SEED ...", .{});
    try comm.pipeWrite(.lightning_genseed);
}

/// similar to `startSeedSetup` but used when seed is already setup,
/// at any time later.
/// reuses tab.seed_setup elements for the same purpose.
fn startPairing() !void {
    const win = try lvgl.Window.newTop(60, " " ++ symbol.LightningBolt ++ " PAIRING SETUP");
    try tab.initSetup(win);
    errdefer tab.destroySetup(); // TODO: display an error instead
    const wincont = win.content().flex(.row, .{ .all = .center });
    _ = try lvgl.Spinner.new(wincont);
    _ = try lvgl.Label.new(wincont, "GATHERING CONNECTION DATA ...", .{});
    try comm.pipeWrite(.lightning_get_ctrlconn);
}

fn confirmSetupSeed(mnemonic: []const []const u8) !void {
    errdefer tab.destroySetup(); // TODO: display an error instead
    if (tab.seed_setup == null) {
        return error.LightningSetupInactive;
    }
    if (mnemonic.len != 24) {
        return error.InvalidMnemonicLen;
    }
    tab.seed_setup.?.mnemonic = try types.StringList.fromUnowned(tab.seed_setup.?.arena.allocator(), mnemonic);

    const wincont = tab.seed_setup.?.topwin.content().flex(.column, .{});
    wincont.deleteChildren();
    preserve_main_active_tab();

    _ = try lvgl.Label.new(wincont,
        \\the seed below is the master key of this lightning node, allowing
        \\FULL CONTROL as well as recovery of funds in case of a device fatal failure.
    , .{});

    const seedcard = try lvgl.Card.new(wincont, "SEED", .{});
    const seedcols = try lvgl.FlexLayout.new(seedcard, .row, .{ .width = lvgl.sizePercent(100), .height = .content });
    const cols: [3]lvgl.FlexLayout = .{
        try lvgl.FlexLayout.new(seedcols, .column, .{ .width = lvgl.sizePercent(30), .height = .content }),
        try lvgl.FlexLayout.new(seedcols, .column, .{ .width = lvgl.sizePercent(30), .height = .content }),
        try lvgl.FlexLayout.new(seedcols, .column, .{ .width = lvgl.sizePercent(30), .height = .content }),
    };
    var buf: [32]u8 = undefined;
    for (tab.seed_setup.?.mnemonic.?.items(), 0..) |word, i| {
        _ = try lvgl.Label.newFmt(cols[i / 8], &buf, "{d: >2}. {s}", .{ i + 1, word }, .{});
    }

    _ = try lvgl.Label.new(wincont,
        \\it is DISPLAYED ONCE, this time only. the recommendation is to copy it
        \\over to a non-digital medium, away from easily accessible places.
        \\failure to secure the seed leads to UNRECOVERABLE LOSS of all funds.
    , .{});

    const btnrow = try lvgl.FlexLayout.new(wincont, .row, .{
        .width = lvgl.sizePercent(100),
        .height = .content,
        .main = .space_between,
    });
    const cancel_btn = try lvgl.TextButton.new(btnrow, "CANCEL");
    cancel_btn.setWidth(lvgl.sizePercent(30));
    cancel_btn.addStyle(lvgl.nm_style_btn_red(), .{});
    _ = cancel_btn.on(.click, nm_lnd_setup_finish, null);

    const proceed_btn = try lvgl.TextButton.new(btnrow, "PROCEED " ++ symbol.Right);
    proceed_btn.setWidth(lvgl.sizePercent(30));
    _ = proceed_btn.on(.click, nm_lnd_setup_commit_seed, null);
}

export fn nm_lnd_setup_commit_seed(_: *lvgl.LvEvent) void {
    setupCommitSeed() catch |err| logger.err("setupCommitSeed: {any}", .{err});
}

fn setupCommitSeed() !void {
    errdefer tab.destroySetup(); // TODO: display an error instead
    if (tab.seed_setup == null) {
        return error.LightningSetupInactive;
    }
    if (tab.seed_setup.?.mnemonic == null) {
        return error.LightningSetupNullMnemonic;
    }
    const wincont = tab.seed_setup.?.topwin.content().flex(.row, .{ .all = .center });
    wincont.deleteChildren();
    preserve_main_active_tab();
    _ = try lvgl.Spinner.new(wincont);
    _ = try lvgl.Label.new(wincont, "INITIALIZING WALLET ...", .{});
    try comm.pipeWrite(.{ .lightning_init_wallet = .{ .mnemonic = tab.seed_setup.?.mnemonic.?.items() } });
    try comm.pipeWrite(.lightning_get_ctrlconn);
}

fn setupPairing(conn: comm.Message.LightningCtrlConn) !void {
    errdefer tab.destroySetup(); // TODO: display an error instead
    if (tab.seed_setup == null) {
        return error.LightningSetupInactive;
    }

    const alloc = tab.seed_setup.?.arena.allocator();
    var urlmap = std.StringArrayHashMap([]const u8).init(alloc);
    for (conn) |ctrl| {
        if (ctrl.perm != .admin) {
            continue;
        }
        // TODO: tor vs i2p vs clearnet vs nebula
        switch (ctrl.typ) {
            .lnd_rpc => try urlmap.put(appBitBanana, try alloc.dupe(u8, ctrl.url)),
            .lnd_http => try urlmap.put(appZeus, try alloc.dupe(u8, ctrl.url)),
        }
    }
    const appsel_options = try std.mem.joinZ(alloc, "\n", urlmap.keys());

    const wincont = tab.seed_setup.?.topwin.content().flex(.row, .{ .width = lvgl.sizePercent(100), .height = .content });
    wincont.deleteChildren();
    preserve_main_active_tab();

    const colopt = lvgl.FlexLayout.AlignOpt{
        .width = lvgl.sizePercent(50),
        .height = .{ .fixed = lvgl.sizePercent(95) },
    };
    const leftcol = try lvgl.FlexLayout.new(wincont, .column, colopt);
    leftcol.setPad(10, .row, .{});
    const appsel = try lvgl.Dropdown.new(leftcol, appsel_options);
    appsel.setWidth(lvgl.sizePercent(100));
    _ = appsel.on(.value_changed, nm_lnd_setup_appsel_changed, null);
    const appdesc = try lvgl.Label.new(leftcol, "", .{});
    appdesc.flexGrow(1);
    const donebtn = try lvgl.TextButton.new(leftcol, "DONE");
    donebtn.setWidth(lvgl.sizePercent(100));
    _ = donebtn.on(.click, nm_lnd_setup_finish, null);

    const rightcol = try lvgl.FlexLayout.new(wincont, .column, colopt);
    // QR code widget requires fixed size value. assuming two flex columns split the screen
    // at 50%, the appsel dropdown's content on the left should be the same as the desired
    // QR code size on the right.
    wincont.recalculateLayout(); // ensure contentWidth returns correct value
    const qr = try lvgl.QrCode.new(rightcol, appsel.contentWidth(), null);
    const qrerr = try lvgl.Label.new(rightcol, "QR data too large to display", .{});
    qrerr.hide();

    // pairing struct must be set last, past all try/catch err.
    // otherwise, errdefer will double free urlmap: once in here, second in tab.destroySetup.
    tab.seed_setup.?.pairing = .{
        .urlmap = urlmap,
        .appsel = appsel,
        .appdesc = appdesc,
        .qr = qr,
        .qrerr = qrerr,
    };
    updatePairingApp();
}

export fn nm_lnd_setup_appsel_changed(_: *lvgl.LvEvent) void {
    updatePairingApp();
}

fn updatePairingApp() void {
    const pairing = tab.seed_setup.?.pairing.?;
    var buf: [128]u8 = undefined;
    const appname = pairing.appsel.getSelectedStr(&buf);
    if (app_description.get(appname)) |appdesc| {
        pairing.appdesc.setTextStatic(appdesc);
        pairing.qr.show();
        pairing.qrerr.hide();
        pairing.qr.setQrData(pairing.urlmap.get(appname).?) catch |err| {
            logger.err("updatePairingApp: setQrData: {!}", .{err});
            pairing.qr.hide();
            pairing.qrerr.show();
        };
    } else {
        logger.err("updatePairingApp: unknown app name [{s}]", .{appname});
    }
}

fn promptNodeReset() !void {
    const proceed: [*:0]const u8 = "PROCEED"; // btn idx 0
    const abort: [*:0]const u8 = "CANCEL"; // btn idx 1
    const title = " " ++ symbol.Warning ++ " LIGHTNING NODE RESET";
    const text =
        \\ARE YOU SURE?
        \\
        \\once reset, all funds managed by this node become
        \\permanently inaccessible unless a copy of the seed
        \\is available.
        \\
        \\the mnemonic seed allows restoring access to the
        \\on-chain portion of the funds.
    ;
    widget.modal(title, text, &.{ proceed, abort }, nodeResetModalCallback) catch |err| {
        logger.err("promptNodeReset: modal: {any}", .{err});
    };
}

fn nodeResetModalCallback(btn_idx: usize) align(@alignOf(widget.ModalButtonCallbackFn)) void {
    defer preserve_main_active_tab();
    // proceed = 0, cancel = 1
    if (btn_idx != 0) {
        return;
    }
    comm.pipeWrite(.lightning_reset) catch |err| {
        logger.err("nodeResetModalCallback: failed to request node reset: {!}", .{err});
        return;
    };
    tab.setMode(.startup);
}

/// updates the tab when in regular operational mode.
fn updateReport(rep: comm.Message.LightningReport) !void {
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
    tab.channels.cont.deleteChildren();
    for (rep.channels) |ch| {
        const chbox = (try lvgl.Container.new(tab.channels.cont)).flex(.column, .{});
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
