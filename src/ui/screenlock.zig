const std = @import("std");

const comm = @import("../comm.zig");
const lvgl = @import("lvgl.zig");

const logger = std.log.scoped(.ui_screenlock);
const infoTextInit = "please enter pin code to unlock the screen";

var main_screen: lvgl.Screen = undefined;
var locked_screen: lvgl.Screen = undefined;

var pincode: lvgl.TextArea = undefined;
var info: lvgl.Label = undefined;
var spinner: lvgl.Spinner = undefined;
var keyboard: lvgl.Keyboard = undefined;

var is_active: bool = false;

pub fn init(main_scr: lvgl.Screen) !void {
    main_screen = main_scr;
    locked_screen = try lvgl.Screen.new();

    pincode = try lvgl.TextArea.new(locked_screen, .{ .password_mode = true });
    pincode.posAlign(.top_mid, 0, 20);
    _ = pincode.on(.ready, nm_pincode_input, null);

    info = try lvgl.Label.new(locked_screen, null, .{});
    info.setTextStatic(infoTextInit);
    info.posAlignTo(pincode, .out_bottom_mid, 0, 10);

    spinner = try lvgl.Spinner.new(locked_screen);
    spinner.center();
    spinner.hide();

    keyboard = try lvgl.Keyboard.new(locked_screen, .number);
    keyboard.attach(pincode);
}

pub fn activate() void {
    if (is_active) {
        logger.info("screenlock already active", .{});
        return;
    }
    is_active = true;
    locked_screen.load();
    spinner.hide();
    pincode.enable();
    pincode.setText("");
    info.setTextStatic(infoTextInit);
    info.posAlignTo(pincode, .out_bottom_mid, 0, 10);
    keyboard.show();
    logger.info("screenlock active", .{});
}

/// msg lifetime is only until function return.
pub fn unlockFailure(msg: [:0]const u8) void {
    info.setText(msg);
    info.posAlignTo(pincode, .out_bottom_mid, 0, 10);
    spinner.hide();
    pincode.setText("");
    pincode.enable();
    keyboard.show();
}

pub fn unlockSuccess() void {
    logger.info("deactivating screenlock", .{});
    pincode.setText("");
    main_screen.load();
    is_active = false;
}

export fn nm_pincode_input(e: *lvgl.LvEvent) void {
    switch (e.code()) {
        .ready => {
            keyboard.hide();
            pincode.disable();
            spinner.show();
            comm.pipeWrite(.{ .unlock_screen = pincode.text() }) catch |err| {
                logger.err("unlock_screen pipe write: {!}", .{err});
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "internal error: {!}", .{err}) catch {
                    unlockFailure("internal error");
                    return;
                };
                unlockFailure(msg);
            };
        },
        else => {},
    }
}
