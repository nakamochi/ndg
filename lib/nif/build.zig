const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("nif", .{ .root_source_file = b.path("nif.zig") });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addStaticLibrary(.{
        .name = "nif",
        .root_source_file = b.path("nif.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib.defineCMacro("CONFIG_CTRL_IFACE", null);
    lib.defineCMacro("CONFIG_CTRL_IFACE_UNIX", null);
    lib.addIncludePath(b.path("wpa_supplicant"));
    lib.addCSourceFiles(.{
        .files = &.{
            "wpa_supplicant/wpa_ctrl.c",
            "wpa_supplicant/os_unix.c",
        },
        .flags = &.{
            "-Wall",
            "-Wextra",
            "-Wshadow",
            "-Wundef",
            "-Wunused-parameter",
            "-Werror",
        },
    });
    b.installArtifact(lib);
}
