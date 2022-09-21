const build = @import("std").build;

pub fn addPkg(b: *build.Builder, obj: *build.LibExeObjStep, prefix: []const u8) void {
    obj.addPackagePath("nif", pkgPath(b, prefix));
}

pub fn pkgPath(b: *build.Builder, prefix: []const u8) []const u8 {
    return b.pathJoin(&.{prefix, "nif.zig"});
}

pub fn library(b: *build.Builder, prefix: []const u8) *build.LibExeObjStep {
    const lib = b.addStaticLibrary("nif", b.pathJoin(&.{prefix, "nif.zig"}));
    lib.addIncludePath(b.pathJoin(&.{prefix, "wpa_supplicant"}));
    lib.defineCMacro("CONFIG_CTRL_IFACE", null);
    lib.defineCMacro("CONFIG_CTRL_IFACE_UNIX", null);
    lib.addCSourceFiles(&.{
        b.pathJoin(&.{prefix, "wpa_supplicant/wpa_ctrl.c"}),
        b.pathJoin(&.{prefix, "wpa_supplicant/os_unix.c"}),
    }, &.{
        "-Wall",
        "-Wextra",
        "-Wshadow",
        "-Wundef",
        "-Wunused-parameter",
        "-Werror",
    });
    lib.linkLibC();
    return lib;
}
