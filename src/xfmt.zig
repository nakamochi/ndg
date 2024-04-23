//! extra formatting utilities, missing from std.fmt.

const std = @import("std");

/// formats a unix timestamp in YYYY-MM-DD HH:MM:SS UTC.
/// if the sec value greater than u47, outputs raw digits.
pub fn unix(sec: u64) std.fmt.Formatter(formatUnix) {
    return .{ .data = sec };
}

/// returns a metric formatter, outputting the value with SI unit suffix.
pub fn imetric(val: i64) std.fmt.Formatter(formatMetricI) {
    return .{ .data = val };
}

/// returns a metric formatter, outputting the value with SI unit suffix.
pub fn umetric(val: u64) std.fmt.Formatter(formatMetricU) {
    return .{ .data = val };
}

fn formatUnix(sec: u64, comptime fmt: []const u8, opts: std.fmt.FormatOptions, w: anytype) !void {
    _ = fmt; // unused
    _ = opts;
    if (sec > std.math.maxInt(u47)) {
        // EpochSeconds.getEpochDay trucates to u47 which results in a "truncated bits"
        // panic for too big numbers. so, just print raw digits.
        return std.fmt.formatInt(sec, 10, .lower, .{}, w);
    }
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = sec };
    const daysec = epoch.getDaySeconds();
    const yearday = epoch.getEpochDay().calculateYearDay();
    const monthday = yearday.calculateMonthDay();
    return std.fmt.format(w, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        yearday.year,
        monthday.month.numeric(),
        monthday.day_index + 1,
        daysec.getHoursIntoDay(),
        daysec.getMinutesIntoHour(),
        daysec.getSecondsIntoMinute(),
    });
}

fn formatMetricI(value: i64, comptime fmt: []const u8, opts: std.fmt.FormatOptions, w: anytype) !void {
    const uval: u64 = @abs(value);
    const base: u64 = 1000;
    if (uval < base) {
        return std.fmt.formatIntValue(value, fmt, opts, w);
    }
    if (value < 0) {
        try w.writeByte('-');
    }
    return formatMetricU(uval, fmt, opts, w);
}

/// based on `std.fmt.fmtIntSizeDec`.
fn formatMetricU(value: u64, comptime fmt: []const u8, opts: std.fmt.FormatOptions, w: anytype) !void {
    const lossyCast = std.math.lossyCast;
    const base: u64 = 1000;
    if (value < base) {
        return std.fmt.formatIntValue(value, fmt, opts, w);
    }

    const mags_si = " kMGTPEZY";
    const log2 = std.math.log2(value);
    const m = @min(log2 / comptime std.math.log2(base), mags_si.len - 1);
    const suffix = mags_si[m];
    const newval: f64 = lossyCast(f64, value) / std.math.pow(f64, lossyCast(f64, base), lossyCast(f64, m));
    try std.fmt.formatType(newval, "d", opts, w, 0);
    try w.writeByte(suffix);
}

test "unix" {
    const t = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try std.fmt.format(fbs.writer(), "{}", .{unix(1136239445)});
    try t.expectEqualStrings("2006-01-02 22:04:05 UTC", fbs.getWritten());
}

test "imetric" {
    const t = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const table: []const struct { val: i64, str: []const u8 } = &.{
        .{ .val = 0, .str = "0" },
        .{ .val = -13, .str = "-13" },
        .{ .val = 1000, .str = "1k" },
        .{ .val = -1234, .str = "-1.234k" },
        .{ .val = 12340, .str = "12.34k" },
        .{ .val = -123400, .str = "-123.4k" },
        .{ .val = 1234000, .str = "1.234M" },
        .{ .val = -1234000000, .str = "-1.234G" },
    };
    for (table) |item| {
        fbs.reset();
        try std.fmt.format(fbs.writer(), "{}", .{imetric(item.val)});
        try t.expectEqualStrings(item.str, fbs.getWritten());
    }
}

test "umetric" {
    const t = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const table: []const struct { val: u64, str: []const u8 } = &.{
        .{ .val = 0, .str = "0" },
        .{ .val = 13, .str = "13" },
        .{ .val = 1000, .str = "1k" },
        .{ .val = 1234, .str = "1.234k" },
        .{ .val = 12340, .str = "12.34k" },
        .{ .val = 123400, .str = "123.4k" },
        .{ .val = 1234000, .str = "1.234M" },
        .{ .val = 1234000000, .str = "1.234G" },
    };
    for (table) |item| {
        fbs.reset();
        try std.fmt.format(fbs.writer(), "{}", .{umetric(item.val)});
        try t.expectEqualStrings(item.str, fbs.getWritten());
    }
}
