//! extra formatting utilities, missing from std.fmt.

const std = @import("std");

pub fn unix(sec: u64) std.fmt.Formatter(formatUnix) {
    return .{ .data = sec };
}

fn formatUnix(sec: u64, comptime fmt: []const u8, opts: std.fmt.FormatOptions, w: anytype) !void {
    _ = fmt; // unused
    _ = opts;
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
