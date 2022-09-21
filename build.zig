const std = @import("std");
const nifbuild = @import("lib/nif/build.zig");

pub fn build(b: *std.build.Builder) void {
    b.use_stage1 = true;

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const strip = b.option(bool, "strip", "strip output binary; default: false") orelse false;
    const drv = b.option(DriverTarget, "driver", "display and input drivers combo; default: sdl2") orelse .sdl2;
    const disp_horiz = b.option(u32, "horiz", "display horizontal pixels count; default: 800") orelse 800;
    const disp_vert = b.option(u32, "vert", "display vertical pixels count; default: 480") orelse 480;

    // gui build
    const ngui = b.addExecutable("ngui", "src/ngui.zig");
    ngui.setTarget(target);
    ngui.setBuildMode(mode);
    ngui.pie = true;
    ngui.strip = strip;

    ngui.addIncludePath("lib");
    ngui.addIncludePath("src/ui/c");
    ngui.linkLibC();

    const lvgl_flags = &.{
        "-std=c11",
        "-fstack-protector",
        "-Wall",
        "-Wextra",
        "-Wformat",
        "-Wformat-security",
        "-Wundef",
    };
    ngui.addCSourceFiles(lvgl_generic_src, lvgl_flags);

    const ngui_cflags: []const []const u8 = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Wshadow",
        "-Wundef",
        "-Wunused-parameter",
        "-Werror",
    };
    ngui.addCSourceFiles(&.{
        "src/ui/c/ui.c",
        "src/ui/c/lv_font_courierprimecode_14.c",
        //"src/ui/c/lv_font_courierprimecode_16.c",
        "src/ui/c/lv_font_courierprimecode_24.c",
    }, ngui_cflags);

    ngui.defineCMacroRaw(b.fmt("NM_DISP_HOR={}", .{disp_horiz}));
    ngui.defineCMacroRaw(b.fmt("NM_DISP_VER={}", .{disp_vert}));
    ngui.defineCMacro("LV_CONF_INCLUDE_SIMPLE", null);
    ngui.defineCMacro("LV_TICK_CUSTOM", "1");
    ngui.defineCMacro("LV_TICK_CUSTOM_INCLUDE", "\"ui.h\"");
    ngui.defineCMacro("LV_TICK_CUSTOM_SYS_TIME_EXPR", "(nm_get_curr_tick())");
    switch (drv) {
        .sdl2 => {
            ngui.addCSourceFiles(lvgl_sdl2_src, lvgl_flags);
            ngui.addCSourceFile("src/ui/c/drv_sdl2.c", ngui_cflags);
            ngui.defineCMacro("NM_DRV_SDL2", null);
            ngui.defineCMacro("USE_SDL", null);
            ngui.linkSystemLibrary("SDL2");
        },
        .fbev => {
            ngui.addCSourceFiles(lvgl_fbev_src, lvgl_flags);
            ngui.addCSourceFile("src/ui/c/drv_fbev.c", ngui_cflags);
            ngui.defineCMacro("NM_DRV_FBEV", null);
            ngui.defineCMacro("USE_FBDEV", null);
            ngui.defineCMacro("USE_EVDEV", null);
        },
    }

    const ngui_build_step = b.step("ngui", "build ngui (nakamochi gui)");
    ngui_build_step.dependOn(&b.addInstallArtifact(ngui).step);

    // daemon build
    const nd = b.addExecutable("nd", "src/nd.zig");
    nd.setTarget(target);
    nd.setBuildMode(mode);
    nd.pie = true;
    nd.strip = strip;

    nifbuild.addPkg(b, nd, "lib/nif");
    const niflib = nifbuild.library(b, "lib/nif");
    niflib.setTarget(target);
    niflib.setBuildMode(mode);
    nd.linkLibrary(niflib);

    const nd_build_step = b.step("nd", "build nd (nakamochi daemon)");
    nd_build_step.dependOn(&b.addInstallArtifact(nd).step);

    // default build
    const build_all_step = b.step("all", "build everything");
    build_all_step.dependOn(ngui_build_step);
    build_all_step.dependOn(nd_build_step);
    b.default_step.dependOn(build_all_step);

    {
        const tests = b.addTest("src/test.zig");
        tests.setTarget(target);
        tests.setBuildMode(mode);
        tests.linkLibC();
        if (b.args) |args| {
            for (args) |a, i| {
                if (std.mem.eql(u8, a, "--test-filter")) {
                    tests.setFilter(args[i + 1]); // don't care about OOB
                    break;
                }
            }
        }

        const test_step = b.step("test", "run tests");
        test_step.dependOn(&tests.step);
    }
}

const DriverTarget = enum {
    sdl2,
    fbev, // framebuffer + evdev
};

const lvgl_sdl2_src: []const []const u8 = &.{
    "lib/lv_drivers/sdl/sdl.c",
    "lib/lv_drivers/sdl/sdl_common.c",
};

const lvgl_fbev_src: []const []const u8 = &.{
    "lib/lv_drivers/display/fbdev.c",
    "lib/lv_drivers/indev/evdev.c",
};

const lvgl_generic_src: []const []const u8 = &.{
    "lib/lvgl/src/core/lv_disp.c",
    "lib/lvgl/src/core/lv_event.c",
    "lib/lvgl/src/core/lv_group.c",
    "lib/lvgl/src/core/lv_indev.c",
    "lib/lvgl/src/core/lv_indev_scroll.c",
    "lib/lvgl/src/core/lv_obj.c",
    "lib/lvgl/src/core/lv_obj_class.c",
    "lib/lvgl/src/core/lv_obj_draw.c",
    "lib/lvgl/src/core/lv_obj_pos.c",
    "lib/lvgl/src/core/lv_obj_scroll.c",
    "lib/lvgl/src/core/lv_obj_style.c",
    "lib/lvgl/src/core/lv_obj_style_gen.c",
    "lib/lvgl/src/core/lv_obj_tree.c",
    "lib/lvgl/src/core/lv_refr.c",
    "lib/lvgl/src/core/lv_theme.c",
    "lib/lvgl/src/draw/arm2d/lv_gpu_arm2d.c",
    "lib/lvgl/src/draw/lv_draw.c",
    "lib/lvgl/src/draw/lv_draw_arc.c",
    "lib/lvgl/src/draw/lv_draw_img.c",
    "lib/lvgl/src/draw/lv_draw_label.c",
    "lib/lvgl/src/draw/lv_draw_layer.c",
    "lib/lvgl/src/draw/lv_draw_line.c",
    "lib/lvgl/src/draw/lv_draw_mask.c",
    "lib/lvgl/src/draw/lv_draw_rect.c",
    "lib/lvgl/src/draw/lv_draw_transform.c",
    "lib/lvgl/src/draw/lv_draw_triangle.c",
    "lib/lvgl/src/draw/lv_img_buf.c",
    "lib/lvgl/src/draw/lv_img_cache.c",
    "lib/lvgl/src/draw/lv_img_decoder.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_arc.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_bg.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_composite.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_img.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_label.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_layer.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_line.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_mask.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_polygon.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_rect.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_stack_blur.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_texture_cache.c",
    "lib/lvgl/src/draw/sdl/lv_draw_sdl_utils.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_arc.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_blend.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_dither.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_gradient.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_img.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_layer.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_letter.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_line.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_polygon.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_rect.c",
    "lib/lvgl/src/draw/sw/lv_draw_sw_transform.c",
    "lib/lvgl/src/extra/layouts/flex/lv_flex.c",
    "lib/lvgl/src/extra/layouts/grid/lv_grid.c",
    "lib/lvgl/src/extra/libs/bmp/lv_bmp.c",
    "lib/lvgl/src/extra/libs/ffmpeg/lv_ffmpeg.c",
    "lib/lvgl/src/extra/libs/freetype/lv_freetype.c",
    "lib/lvgl/src/extra/libs/fsdrv/lv_fs_fatfs.c",
    "lib/lvgl/src/extra/libs/fsdrv/lv_fs_posix.c",
    "lib/lvgl/src/extra/libs/fsdrv/lv_fs_stdio.c",
    "lib/lvgl/src/extra/libs/fsdrv/lv_fs_win32.c",
    "lib/lvgl/src/extra/libs/gif/gifdec.c",
    "lib/lvgl/src/extra/libs/gif/lv_gif.c",
    "lib/lvgl/src/extra/libs/png/lodepng.c",
    "lib/lvgl/src/extra/libs/png/lv_png.c",
    "lib/lvgl/src/extra/libs/qrcode/lv_qrcode.c",
    "lib/lvgl/src/extra/libs/qrcode/qrcodegen.c",
    "lib/lvgl/src/extra/libs/rlottie/lv_rlottie.c",
    "lib/lvgl/src/extra/libs/sjpg/lv_sjpg.c",
    "lib/lvgl/src/extra/libs/sjpg/tjpgd.c",
    "lib/lvgl/src/extra/lv_extra.c",
    "lib/lvgl/src/extra/others/fragment/lv_fragment.c",
    "lib/lvgl/src/extra/others/fragment/lv_fragment_manager.c",
    "lib/lvgl/src/extra/others/gridnav/lv_gridnav.c",
    "lib/lvgl/src/extra/others/ime/lv_ime_pinyin.c",
    "lib/lvgl/src/extra/others/imgfont/lv_imgfont.c",
    "lib/lvgl/src/extra/others/monkey/lv_monkey.c",
    "lib/lvgl/src/extra/others/msg/lv_msg.c",
    "lib/lvgl/src/extra/others/snapshot/lv_snapshot.c",
    "lib/lvgl/src/extra/themes/basic/lv_theme_basic.c",
    "lib/lvgl/src/extra/themes/default/lv_theme_default.c",
    "lib/lvgl/src/extra/themes/mono/lv_theme_mono.c",
    "lib/lvgl/src/extra/widgets/animimg/lv_animimg.c",
    "lib/lvgl/src/extra/widgets/calendar/lv_calendar.c",
    "lib/lvgl/src/extra/widgets/calendar/lv_calendar_header_arrow.c",
    "lib/lvgl/src/extra/widgets/calendar/lv_calendar_header_dropdown.c",
    "lib/lvgl/src/extra/widgets/chart/lv_chart.c",
    "lib/lvgl/src/extra/widgets/colorwheel/lv_colorwheel.c",
    "lib/lvgl/src/extra/widgets/imgbtn/lv_imgbtn.c",
    "lib/lvgl/src/extra/widgets/keyboard/lv_keyboard.c",
    "lib/lvgl/src/extra/widgets/led/lv_led.c",
    "lib/lvgl/src/extra/widgets/list/lv_list.c",
    "lib/lvgl/src/extra/widgets/menu/lv_menu.c",
    "lib/lvgl/src/extra/widgets/meter/lv_meter.c",
    "lib/lvgl/src/extra/widgets/msgbox/lv_msgbox.c",
    "lib/lvgl/src/extra/widgets/span/lv_span.c",
    "lib/lvgl/src/extra/widgets/spinbox/lv_spinbox.c",
    "lib/lvgl/src/extra/widgets/spinner/lv_spinner.c",
    "lib/lvgl/src/extra/widgets/tabview/lv_tabview.c",
    "lib/lvgl/src/extra/widgets/tileview/lv_tileview.c",
    "lib/lvgl/src/extra/widgets/win/lv_win.c",
    "lib/lvgl/src/font/lv_font.c",
    "lib/lvgl/src/font/lv_font_fmt_txt.c",
    "lib/lvgl/src/font/lv_font_loader.c",
    "lib/lvgl/src/hal/lv_hal_disp.c",
    "lib/lvgl/src/hal/lv_hal_indev.c",
    "lib/lvgl/src/hal/lv_hal_tick.c",
    "lib/lvgl/src/misc/lv_anim.c",
    "lib/lvgl/src/misc/lv_anim_timeline.c",
    "lib/lvgl/src/misc/lv_area.c",
    "lib/lvgl/src/misc/lv_async.c",
    "lib/lvgl/src/misc/lv_bidi.c",
    "lib/lvgl/src/misc/lv_color.c",
    "lib/lvgl/src/misc/lv_fs.c",
    "lib/lvgl/src/misc/lv_gc.c",
    "lib/lvgl/src/misc/lv_ll.c",
    "lib/lvgl/src/misc/lv_log.c",
    "lib/lvgl/src/misc/lv_lru.c",
    "lib/lvgl/src/misc/lv_math.c",
    "lib/lvgl/src/misc/lv_mem.c",
    "lib/lvgl/src/misc/lv_printf.c",
    "lib/lvgl/src/misc/lv_style.c",
    "lib/lvgl/src/misc/lv_style_gen.c",
    "lib/lvgl/src/misc/lv_templ.c",
    "lib/lvgl/src/misc/lv_timer.c",
    "lib/lvgl/src/misc/lv_tlsf.c",
    "lib/lvgl/src/misc/lv_txt.c",
    "lib/lvgl/src/misc/lv_txt_ap.c",
    "lib/lvgl/src/misc/lv_utils.c",
    "lib/lvgl/src/widgets/lv_arc.c",
    "lib/lvgl/src/widgets/lv_bar.c",
    "lib/lvgl/src/widgets/lv_btn.c",
    "lib/lvgl/src/widgets/lv_btnmatrix.c",
    "lib/lvgl/src/widgets/lv_canvas.c",
    "lib/lvgl/src/widgets/lv_checkbox.c",
    "lib/lvgl/src/widgets/lv_dropdown.c",
    "lib/lvgl/src/widgets/lv_img.c",
    "lib/lvgl/src/widgets/lv_label.c",
    "lib/lvgl/src/widgets/lv_line.c",
    "lib/lvgl/src/widgets/lv_objx_templ.c",
    "lib/lvgl/src/widgets/lv_roller.c",
    "lib/lvgl/src/widgets/lv_slider.c",
    "lib/lvgl/src/widgets/lv_switch.c",
    "lib/lvgl/src/widgets/lv_table.c",
    "lib/lvgl/src/widgets/lv_textarea.c",
};
