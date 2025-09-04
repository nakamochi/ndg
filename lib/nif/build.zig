const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("nif", .{ .root_source_file = b.path("nif.zig") });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("nif.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "nif",
        .root_module = lib_mod,
    });
    lib.root_module.addCMacro("CONFIG_CTRL_IFACE", "");
    lib.root_module.addCMacro("CONFIG_CTRL_IFACE_UNIX", "");
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
