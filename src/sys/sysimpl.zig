//! real implementation of the sys module for production code.

const std = @import("std");
const types = @import("../types.zig");

/// caller owns memory; must dealloc using `allocator`.
pub fn hostname(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = try std.posix.gethostname(&buf);
    return allocator.dupe(u8, name);
}

/// a variable for tests; must not mutate at runtime otherwise.
var hostname_filepath: []const u8 = "/etc/hostname";

/// removes all non-alphanumeric ascii and utf8 codepoints when setting hostname,
/// as well as leading digits.
pub fn setHostname(allocator: std.mem.Allocator, name: []const u8) !void {
    // sanitize the new input.
    var sanitized = try std.ArrayList(u8).initCapacity(allocator, name.len);
    defer sanitized.deinit();
    var it = (try std.unicode.Utf8View.init(name)).iterator();
    while (it.nextCodepointSlice()) |s| {
        if (s.len != 1) continue;
        switch (s[0]) {
            'A'...'Z', 'a'...'z' => |c| try sanitized.append(c),
            '0'...'9' => |c| {
                if (sanitized.items.len == 0) {
                    // ignore leading digits
                    continue;
                }
                try sanitized.append(c);
            },
            else => {}, // ignore non-alphanumeric
        }
    }
    if (sanitized.items.len == 0) {
        return error.SetHostnameEmptyName;
    }
    const newname = sanitized.items;

    // need not continue if current name matches the new one.
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const currname = try std.posix.gethostname(&buf);
    if (std.mem.eql(u8, currname, newname)) {
        return;
    }

    // make persistent change first
    const opt = .{ .mode = 0o644 };
    const file = try std.io.BufferedAtomicFile.create(allocator, std.fs.cwd(), hostname_filepath, opt);
    defer file.destroy(); // releases resources; does NOT deletes the file
    try file.writer().writeAll(newname);
    try file.finish();

    // rename hostname on the running system
    var proc = types.ChildProcess.init(&.{ "hostname", newname }, allocator);
    switch (try proc.spawnAndWait()) {
        .Exited => |code| if (code != 0) return error.SetHostnameBadExitCode,
        else => return error.SetHostnameBadTerm,
    }
}

test "setHostname" {
    const t = std.testing;
    const tt = @import("../test.zig");
    // need to manual free resources because no way to deinit the child process spawn in setHostname.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();
    hostname_filepath = try tmp.join(&.{"hostname"});
    try tmp.dir.writeFile(hostname_filepath, "dummy");

    try setHostname(arena, "123_-newhostname$%/3-4hello5\xef\x83\xa7end");

    var buf: [128]u8 = undefined;
    const cont = try tmp.dir.readFile(hostname_filepath, &buf);
    try t.expectEqualStrings("newhostname34hello5end", cont);
}
