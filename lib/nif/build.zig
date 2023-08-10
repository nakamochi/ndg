const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("nif", .{ .source_file = .{ .path = "nif.zig" } });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addStaticLibrary(.{
        .name = "nif",
        .root_source_file = .{ .path = "nif.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib.defineCMacro("CONFIG_CTRL_IFACE", null);
    lib.defineCMacro("CONFIG_CTRL_IFACE_UNIX", null);
    lib.addIncludePath(.{ .path = "wpa_supplicant" });
    lib.addCSourceFiles(&.{
        "wpa_supplicant/wpa_ctrl.c",
        "wpa_supplicant/os_unix.c",
    }, &.{
        "-Wall",
        "-Wextra",
        "-Wshadow",
        "-Wundef",
        "-Wunused-parameter",
        "-Werror",
    });
    b.installArtifact(lib);
}
