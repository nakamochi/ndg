//! lnd config parser and serializer based on github.com/jessevdk/go-flags,
//! specifically https://pkg.go.dev/github.com/jessevdk/go-flags#IniParser.Parse
//!
//! see https://docs.lightning.engineering/lightning-network-tools/lnd/lnd.conf
//! for lnd config docs.

const std = @import("std");
const ini = @import("ini");

const logger = std.log.scoped(.lndconf);

sections: std.ArrayList(Section),
// holds section allocations and their key/value pairs.
// initialized at `init` and dropped at `deinit`.
arena: *std.heap.ArenaAllocator,

// case-insensitive default group name according to source doc comments
// at github.com/jessevdk/go-flags
pub const MainSection = "application options";

// a section key/value pairs (properties) followed by its declaration
// in square brackets like "[section name]".
pub const Section = struct {
    name: []const u8, // section name without square brackets
    props: std.StringArrayHashMap(PropValue),

    /// holds all allocations throughout the lifetime of the section.
    /// initialized in `appendSection`.
    alloc: std.mem.Allocator,

    /// key and value are dup'ed by `Section.alloc`.
    /// if an existing property exist, it necessarily becomes an array and the
    /// new value is appended to the array.
    pub fn appendPropStr(self: *Section, key: []const u8, value: []const u8) !void {
        const vdup = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(vdup);

        var res = try self.props.getOrPut(try self.alloc.dupe(u8, key));
        if (!res.found_existing) {
            res.value_ptr.* = .{ .str = vdup };
            return;
        }

        switch (res.value_ptr.*) {
            .str => |s| {
                var list = try std.ArrayList([]const u8).initCapacity(self.alloc, 2);
                try list.append(s); // s is already owned by arena backing self.alloc
                try list.append(vdup);
                res.value_ptr.* = .{ .astr = try list.toOwnedSlice() };
            },
            .astr => |a| {
                var list = std.ArrayList([]const u8).fromOwnedSlice(self.alloc, a);
                try list.append(vdup);
                res.value_ptr.* = .{ .astr = try list.toOwnedSlice() };
            },
        }
    }

    /// replaces any existing property by the given key with the new value.
    /// value is duplicated in the owned memory.
    pub fn setPropStr(self: *Section, key: []const u8, value: []const u8) !void {
        const vdup = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(vdup);
        var res = try self.props.getOrPut(try self.alloc.dupe(u8, key));
        if (res.found_existing) {
            res.value_ptr.free(self.alloc);
        }
        res.value_ptr.* = .{ .str = vdup };
    }

    /// formats value using `std.fmt.format` and calls `setPropStr`.
    /// the resulting formatted value cannot exceed 512 characters.
    pub fn setPropFmt(self: *Section, key: []const u8, comptime fmt: []const u8, args: anytype) !void {
        var buf = [_]u8{0} ** 512;
        const val = try std.fmt.bufPrint(&buf, fmt, args);
        return self.setPropStr(key, val);
    }
};

/// the value part of a key/value pair.
pub const PropValue = union(enum) {
    str: []const u8, // a "string"
    astr: [][]const u8, // an array of strings, all values of repeated keys

    /// used internally when replacing an existing value in functions such as
    /// `Section.setPropStr`
    fn free(self: PropValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .str => |s| allocator.free(s),
            .astr => |a| {
                for (a) |s| allocator.free(s);
                allocator.free(a);
            },
        }
    }
};

const LndConf = @This();

/// creates a empty config, ready to be populated start with `appendSection`.
/// the object is serialized with `dumpWriter`. `deinit` when no long used.
/// to parse an existing config use `load` or `loadReader`.
pub fn init(allocator: std.mem.Allocator) !LndConf {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return .{
        .arena = arena,
        .sections = std.ArrayList(Section).init(arena.allocator()),
    };
}

// frees all resources used by the config object.
pub fn deinit(self: LndConf) void {
    const allocator = self.arena.child_allocator;
    self.arena.deinit();
    allocator.destroy(self.arena);
}

/// parses an existing config at the specified file path.
/// a thin wrapper around `loadReader` passing it a file reader.
pub fn load(allocator: std.mem.Allocator, filepath: []const u8) !LndConf {
    const f = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer f.close();
    return loadReader(allocator, f.reader());
}

/// parses config contents from reader `r`.
/// makes no section deduplication: all sections are simply appended to `sections`
/// in the encountered order, with ascii characters of the name converted to lower case.
/// values of identical key names are grouped into `PropValue.astr`.
pub fn loadReader(allocator: std.mem.Allocator, r: anytype) !LndConf {
    var parser = ini.parse(allocator, r);
    defer parser.deinit();

    var conf = try LndConf.init(allocator);
    errdefer conf.deinit();

    var currsect: ?*Section = null;
    while (try parser.next()) |record| {
        switch (record) {
            .section => |name| currsect = try conf.appendSection(name),
            .property => |kv| {
                if (currsect == null) {
                    currsect = try conf.appendSection(MainSection);
                }
                try currsect.?.appendPropStr(kv.key, kv.value);
            },
            .enumeration => |v| logger.warn("ignoring key without value: {s}", .{v}),
        }
    }

    return conf;
}

/// serializes the config into writer `w`.
pub fn dumpWriter(self: LndConf, w: anytype) !void {
    for (self.sections.items, 0..) |*sec, i| {
        if (i > 0) {
            try w.writeByte('\n');
        }
        try w.print("[{s}]\n", .{sec.name});
        var it = sec.props.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            switch (kv.value_ptr.*) {
                .str => |s| try w.print("{s}={s}\n", .{ key, s }),
                .astr => |a| for (a) |s| try w.print("{s}={s}\n", .{ key, s }),
            }
        }
    }
}

/// makes no deduplication: callers must do it themselves.
pub fn appendDefaultSection(self: *LndConf) !*Section {
    return self.appendSection(MainSection);
}

/// creates a new confg section, owning a name copy dup'ed using the `arena` allocator.
/// the section name ascii is converted to lower case.
pub fn appendSection(self: *LndConf, name: []const u8) !*Section {
    const alloc = self.arena.allocator();
    var name_dup = try alloc.dupe(u8, name);
    toLower(name_dup);
    try self.sections.append(.{
        .name = name_dup,
        .props = std.StringArrayHashMap(PropValue).init(alloc),
        .alloc = alloc,
    });
    return &self.sections.items[self.sections.items.len - 1];
}

/// returns a section named `MainSection`, if any.
pub fn mainSection(self: LndConf) ?*Section {
    return self.findSection(MainSection);
}

/// O(n); name must be in lower case.
pub fn findSection(self: *const LndConf, name: []const u8) ?*Section {
    for (self.sections.items) |*sec| {
        if (std.mem.eql(u8, sec.name, name)) {
            return sec;
        }
    }
    return null;
}

fn toLower(s: []u8) void {
    for (s, 0..) |c, i| {
        switch (c) {
            'A'...'Z' => s[i] = c | 0b00100000,
            else => {},
        }
    }
}

test "lnd: conf load dump" {
    const t = std.testing;
    const tt = @import("../test.zig");

    var tmp = try tt.TempDir.create();
    defer tmp.cleanup();
    try tmp.dir.writeFile("conf.ini",
        \\; top comment
        \\[application options]
        \\foo = bar
        \\; line comment
        \\baz = quix1 ; inline comment
        \\baz = quix2
        \\
        \\[AutopiloT]
        \\autopilot.active=false
    );
    const clean_conf =
        \\[application options]
        \\foo=bar
        \\baz=quix1
        \\baz=quix2
        \\
        \\[autopilot]
        \\autopilot.active=false
        \\
    ;

    const conf = try LndConf.load(t.allocator, try tmp.join(&.{"conf.ini"}));
    defer conf.deinit();

    var dump = std.ArrayList(u8).init(t.allocator);
    defer dump.deinit();
    try conf.dumpWriter(dump.writer());
    try t.expectEqualStrings(clean_conf, dump.items);

    const sec = conf.mainSection().?;
    try t.expectEqualStrings("bar", sec.props.get("foo").?.str);
    const bazval: []const []const u8 = &.{ "quix1", "quix2" };
    try tt.expectDeepEqual(bazval, sec.props.get("baz").?.astr);
}

test "lnd: conf append and dump" {
    const t = std.testing;

    var conf = try LndConf.init(t.allocator);
    defer conf.deinit();
    var sec = try conf.appendSection(MainSection);
    try sec.appendPropStr("foo", "bar");

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    try conf.dumpWriter(buf.writer());
    try t.expectEqualStrings("[application options]\nfoo=bar\n", buf.items);

    try sec.setPropStr("foo", "baz");
    var sec2 = try conf.appendSection("test");
    try sec2.setPropStr("bar", "quix1");
    try sec2.appendPropStr("bar", "quix2");

    buf.clearAndFree();
    try conf.dumpWriter(buf.writer());
    const want_conf =
        \\[application options]
        \\foo=baz
        \\
        \\[test]
        \\bar=quix1
        \\bar=quix2
        \\
    ;
    try t.expectEqualStrings(want_conf, buf.items);
}
