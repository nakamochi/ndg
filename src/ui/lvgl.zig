//! LVGL types in zig.
//!
//! lv_xxx functions are directly linked against LVGL lib.
//! other functions, without the lv_ prefix are defined in zig and provide type safety
//! and extra functionality, sometimes composed of multiple calls to lv_xxx.
//!
//! nm_xxx functions defined here are exported with "c" convention to allow
//! calls from C code.
//!
//! the module usage must be started with a call to init.

const std = @import("std");
const c = @cImport({
    @cInclude("lvgl/lvgl.h");
});

// logs LV_LOG_xxx messages from LVGL lib.
const logger = std.log.scoped(.lvgl);

/// initalizes LVGL internals. must be called before any other UI functionality
/// is invoked, typically at program startup.
pub fn init() void {
    init_once.call();
}

var init_once = std.once(lvglInit);

fn lvglInit() void {
    lv_log_register_print_cb(nm_lvgl_log);
    lv_init();
}

/// logs messages from LVGL logging facilities; always with the same std.log level .info.
export fn nm_lvgl_log(msg: [*:0]const u8) void {
    const s = std.mem.span(msg);
    // info level log messages are by default printed only in Debug
    // and ReleaseSafe build modes.
    logger.info("{s}", .{std.mem.trimRight(u8, s, "\n")});
}

/// the busy-wait loop cycle wrapper for LVGL.
/// a program main loop must call this periodically.
/// returns the period after which it is to be called again, in ms.
pub fn loopCycle() u32 {
    return lv_timer_handler();
}

/// represents lv_timer_t in C.
pub const LvTimer = opaque {
    /// timer callback signature.
    pub const Callback = *const fn (timer: *LvTimer) callconv(.C) void;

    /// creates a new timer with indefinite repeat count.
    pub fn new(f: Callback, period_ms: u32, userdata: ?*anyopaque) !*LvTimer {
        return lv_timer_create(f, period_ms, userdata) orelse error.OutOfMemory;
    }

    pub fn destroy(self: *LvTimer) void {
        lv_timer_del(self);
    }

    /// after the repeat count is reached, the timer is destroy'ed automatically.
    /// to run the timer indefinitely, use -1 for repeat count.
    pub fn setRepeatCount(self: *LvTimer, n: i32) void {
        lv_timer_set_repeat_count(self, n);
    }
};

/// represents lv_indev_t in C, an input device such as touchscreen or a keyboard.
pub const LvIndev = opaque {
    pub fn first() ?*LvIndev {
        return lv_indev_get_next(null);
    }

    pub fn next(self: *LvIndev) ?*LvIndev {
        return lv_indev_get_next(self);
    }

    pub fn destroy(self: *LvIndev) void {
        lv_indev_delete(self);
    }
};

/// represents lv_event_t in C, required by all event callbacks.
pub const LvEvent = opaque {
    /// event callback, equivalent of lv_event_cb_t.
    pub const Callback = *const fn (e: *LvEvent) callconv(.C) void;

    /// event descriptor returned from a callback setup.
    pub const Descriptor = opaque {};

    /// all possible codes for an event to trigger a function call,
    /// equivalent to lv_event_code_t.
    pub const Code = enum(c.lv_event_code_t) {
        all = c.LV_EVENT_ALL,

        /// input device events
        press = c.LV_EVENT_PRESSED, // the object has been pressed
        pressing = c.LV_EVENT_PRESSING, // the object is being pressed (called continuously while pressing)
        press_lost = c.LV_EVENT_PRESS_LOST, // the object is still being pressed but slid cursor/finger off of the object
        short_click = c.LV_EVENT_SHORT_CLICKED, // the object was pressed for a short period of time, then released it. not called if scrolled.
        long_press = c.LV_EVENT_LONG_PRESSED, // object has been pressed for at least `long_press_time`.  not called if scrolled.
        long_press_repeat = c.LV_EVENT_LONG_PRESSED_REPEAT, // called after `long_press_time` in every `long_press_repeat_time` ms.  not called if scrolled.
        click = c.LV_EVENT_CLICKED, // called on release if not scrolled (regardless to long press)
        release = c.LV_EVENT_RELEASED, // called in every cases when the object has been released
        scroll_begin = c.LV_EVENT_SCROLL_BEGIN, // scrolling begins. the event parameter is a pointer to the animation of the scroll. can be modified
        scroll_end = c.LV_EVENT_SCROLL_END, // scrolling ends
        scroll = c.LV_EVENT_SCROLL, // scrolling
        gesture = c.LV_EVENT_GESTURE, // a gesture is detected. get the gesture with lv_indev_get_gesture_dir(lv_indev_get_act())
        key = c.LV_EVENT_KEY, // a key is sent to the object. get the key with lv_indev_get_key(lv_indev_get_act())
        focus = c.LV_EVENT_FOCUSED, // the object is focused
        defocus = c.LV_EVENT_DEFOCUSED, // the object is defocused
        leave = c.LV_EVENT_LEAVE, // the object is defocused but still selected
        hit_test = c.LV_EVENT_HIT_TEST, // perform advanced hit-testing

        /// drawing events
        cover_check = c.LV_EVENT_COVER_CHECK, // check if the object fully covers an area. the event parameter is lv_cover_check_info_t *
        refr_ext_draw_size = c.LV_EVENT_REFR_EXT_DRAW_SIZE, // get the required extra draw area around the object (e.g. for shadow). the event parameter is lv_coord_t * to store the size.
        draw_main_begin = c.LV_EVENT_DRAW_MAIN_BEGIN, // starting the main drawing phase
        draw_main = c.LV_EVENT_DRAW_MAIN, // perform the main drawing
        draw_main_end = c.LV_EVENT_DRAW_MAIN_END, // finishing the main drawing phase
        draw_post_begin = c.LV_EVENT_DRAW_POST_BEGIN, // starting the post draw phase (when all children are drawn)
        draw_post = c.LV_EVENT_DRAW_POST, // perform the post draw phase (when all children are drawn)
        draw_post_end = c.LV_EVENT_DRAW_POST_END, // finishing the post draw phase (when all children are drawn)
        draw_part_begin = c.LV_EVENT_DRAW_PART_BEGIN, // starting to draw a part. the event parameter is lv_obj_draw_dsc_t *
        draw_part_end = c.LV_EVENT_DRAW_PART_END, // finishing to draw a part. the event parameter is lv_obj_draw_dsc_t *

        /// special events
        value_changed = c.LV_EVENT_VALUE_CHANGED, // the object's value has changed (i.e. slider moved)
        insert = c.LV_EVENT_INSERT, // a text is inserted to the object. the event data is char * being inserted.
        refresh = c.LV_EVENT_REFRESH, // notify the object to refresh something on it (for the user)
        ready = c.LV_EVENT_READY, // a process has finished
        cancel = c.LV_EVENT_CANCEL, // a process has been cancelled

        /// other events
        delete = c.LV_EVENT_DELETE, // object is being deleted
        child_changed = c.LV_EVENT_CHILD_CHANGED, // child was removed, added, or its size, position were changed
        child_created = c.LV_EVENT_CHILD_CREATED, // child was created, always bubbles up to all parents
        child_deleted = c.LV_EVENT_CHILD_DELETED, // child was deleted, always bubbles up to all parents
        screen_unload_start = c.LV_EVENT_SCREEN_UNLOAD_START, // a screen unload started, fired immediately when scr_load is called
        screen_load_start = c.LV_EVENT_SCREEN_LOAD_START, // a screen load started, fired when the screen change delay is expired
        screen_loaded = c.LV_EVENT_SCREEN_LOADED, // a screen was loaded
        screen_unloaded = c.LV_EVENT_SCREEN_UNLOADED, // a screen was unloaded
        size_changed = c.LV_EVENT_SIZE_CHANGED, // object coordinates/size have changed
        style_changed = c.LV_EVENT_STYLE_CHANGED, // object's style has changed
        layout_changed = c.LV_EVENT_LAYOUT_CHANGED, // the children position has changed due to a layout recalculation
        get_self_size = c.LV_EVENT_GET_SELF_SIZE, // get the internal size of a widget
    };

    /// returns the code of the triggered event.
    pub fn code(self: *LvEvent) Code {
        return lv_event_get_code(self);
    }

    /// returns the original event target irrespective of ObjFlag.event_bubble flag
    /// on the object which generated the event.
    pub fn target(self: *LvEvent) *LvObj {
        return lv_event_get_target(self);
    }

    /// returns user data provided at the time of a callback setup, for example LvObj.on.
    pub fn userdata(self: *LvEvent) ?*anyopaque {
        return lv_event_get_user_data(self);
    }

    pub fn stopBubbling(self: *LvEvent) void {
        lv_event_stop_bubbling(self);
    }
};

/// represents lv_disp_t in C.
pub const LvDisp = opaque {
    /// returns display horizontal resolution.
    /// the display must be already initialized.
    pub fn horiz() Coord {
        return lv_disp_get_hor_res(null);
    }

    /// returns display vertical resolution.
    /// the display must be already initialized.
    pub fn vert() Coord {
        return lv_disp_get_ver_res(null);
    }
};

/// forces redraw of dirty areas.
pub fn redraw() void {
    lv_refr_now(null);
}

/// resets user incativity time, as if a UI interaction happened "now".
pub fn resetIdle() void {
    lv_disp_trig_activity(null);
}

/// returns user inactivity time in ms.
/// inactivity is the time elapsed since the last UI action.
pub fn idleTime() u32 {
    return lv_disp_get_inactive_time(null);
}

/// represents lv_style_t in C.
pub const LvStyle = opaque {
    /// indicates which parts and in which states to apply a style to an object.
    pub const Selector = struct {
        part: Part = .main,
        state: State = .default,

        /// produces an int value suitable for lv_xxx functions.
        fn value(self: Selector) c.lv_style_selector_t {
            return @intFromEnum(self.part) | @intFromEnum(self.state);
        }
    };
};

/// represents lv_font_t in C.
pub const LvFont = opaque {};

/// a simplified color type compatible with LVGL which defines lv_color_t
/// as a union containing an bit-fields struct unsupported in zig cImport.
pub const Color = u16; // originally c.lv_color_t; TODO: comptime switch for u32

//typedef union {
//    struct {
//#if LV_COLOR_16_SWAP == 0
//        uint16_t blue : 5;
//        uint16_t green : 6;
//        uint16_t red : 5;
//#else
//        uint16_t green_h : 3;
//        uint16_t red : 5;
//        uint16_t blue : 5;
//        uint16_t green_l : 3;
//#endif
//    } ch;
//    uint16_t full;
//} lv_color16_t;
//
//# define LV_COLOR_MAKE16(r8, g8, b8) {{(uint8_t)((b8 >> 3) & 0x1FU), (uint8_t)((g8 >> 2) & 0x3FU), (uint8_t)((r8 >> 3) & 0x1FU)}}
//
// TODO: RGB32
//typedef union {
//    struct {
//        uint8_t blue;
//        uint8_t green;
//        uint8_t red;
//        uint8_t alpha;
//    } ch;
//    uint32_t full;
//} lv_color32_t;
const RGB16 = packed struct {
    b: u5,
    g: u6,
    r: u5,
};

/// rgb produces a Color value base on the red, green and blue components.
pub inline fn rgb(r: u8, g: u8, b: u8) Color {
    const c16 = RGB16{
        .b = @truncate(b >> 3),
        .g = @truncate(g >> 2),
        .r = @truncate(r >> 3),
    };
    return @bitCast(c16);
}

/// black color
pub const Black = rgb(0, 0, 0);
/// white color
pub const White = rgb(0xff, 0xff, 0xff);

/// Palette defines a set of colors, typically used in a theme.
pub const Palette = enum(c.lv_palette_t) {
    red = c.LV_PALETTE_RED,
    pink = c.LV_PALETTE_PINK,
    purple = c.LV_PALETTE_PURPLE,
    deep_purple = c.LV_PALETTE_DEEP_PURPLE,
    indigo = c.LV_PALETTE_INDIGO,
    blue = c.LV_PALETTE_BLUE,
    light_blue = c.LV_PALETTE_LIGHT_BLUE,
    cyan = c.LV_PALETTE_CYAN,
    teal = c.LV_PALETTE_TEAL,
    green = c.LV_PALETTE_GREEN,
    light_green = c.LV_PALETTE_LIGHT_GREEN,
    lime = c.LV_PALETTE_LIME,
    yellow = c.LV_PALETTE_YELLOW,
    amber = c.LV_PALETTE_AMBER,
    orange = c.LV_PALETTE_ORANGE,
    deep_orange = c.LV_PALETTE_DEEP_ORANGE,
    brown = c.LV_PALETTE_BROWN,
    blue_grey = c.LV_PALETTE_BLUE_GREY,
    grey = c.LV_PALETTE_GREY,
    none = c.LV_PALETTE_NONE,

    /// lightening or darkening levels of the main palette colors.
    pub const ModLevel = enum(u8) {
        level1 = 1,
        level2 = 2,
        level3 = 3,
        level4 = 4,
        level5 = 5,
    };

    /// returns main color from the predefined palette.
    pub inline fn main(p: Palette) Color {
        return lv_palette_main(@intFromEnum(p));
    }

    /// makes the main color from the predefined palette lighter according to the
    /// specified level.
    pub inline fn lighten(p: Palette, l: ModLevel) Color {
        return lv_palette_lighten(@intFromEnum(p), @intFromEnum(l));
    }

    /// makes the main color from the predefined palette darker according to the
    /// specified level.
    pub inline fn darken(p: Palette, l: ModLevel) Color {
        return lv_palette_darken(@intFromEnum(p), @intFromEnum(l));
    }
};

/// a set of methods applicable to every kind of lv_xxx object.
pub const BaseObjMethods = struct {
    /// deallocates all resources used by the object, including its children.
    /// user data pointers are untouched.
    pub fn destroy(self: anytype) void {
        lv_obj_del(self.lvobj);
    }

    /// deallocates all resources used by the object's children.
    pub fn deleteChildren(self: anytype) void {
        lv_obj_clean(self.lvobj);
    }

    /// sets or clears an object flag.
    pub fn setFlag(self: anytype, v: LvObj.Flag) void {
        lv_obj_add_flag(self.lvobj, @intFromEnum(v));
    }

    pub fn clearFlag(self: anytype, v: LvObj.Flag) void {
        lv_obj_clear_flag(self.lvobj, @intFromEnum(v));
    }

    /// reports whether the object has v flag set.
    pub fn hasFlag(self: anytype, v: LvObj.Flag) bool {
        return lv_obj_has_flag(self.lvobj, @intFromEnum(v));
    }

    /// returns a user data pointer associated with the object.
    pub fn userdata(self: anytype) ?*anyopaque {
        return nm_obj_userdata(self.lvobj);
    }

    /// associates an arbitrary data with the object.
    /// the pointer can be accessed using LvObj.userdata fn.
    pub fn setUserdata(self: anytype, data: ?*const anyopaque) void {
        nm_obj_set_userdata(self.lvobj, data);
    }

    /// updates layout of all children so that functions like `WidgetMethods.contentWidth`
    /// return correct results, when done in a single LVGL loop iteration.
    pub fn recalculateLayout(self: anytype) void {
        lv_obj_update_layout(self.lvobj);
    }

    /// creates a new event handler where cb is called upon event with the filter code.
    /// to make cb called on any event, use EventCode.all filter.
    /// multiple event handlers are called in the same order as they were added.
    /// the user data pointer udata is available in a handler using LvEvent.userdata fn.
    pub fn on(self: anytype, filter: LvEvent.Code, cb: LvEvent.Callback, udata: ?*anyopaque) *LvEvent.Descriptor {
        return lv_obj_add_event_cb(self.lvobj, cb, filter, udata);
    }
};

/// methods applicable to visible objects like labels, buttons and containers.
pub const WidgetMethods = struct {
    pub fn contentWidth(self: anytype) Coord {
        return lv_obj_get_content_width(self.lvobj);
    }

    /// sets object horizontal length.
    pub fn setWidth(self: anytype, val: Coord) void {
        lv_obj_set_width(self.lvobj, val);
    }

    /// sets object vertical length.
    pub fn setHeight(self: anytype, val: Coord) void {
        lv_obj_set_height(self.lvobj, val);
    }

    /// sets object height to its child contents.
    pub fn setHeightToContent(self: anytype) void {
        lv_obj_set_height(self.lvobj, sizeContent);
    }

    /// sets both width and height to 100%.
    pub fn resizeToMax(self: anytype) void {
        lv_obj_set_size(self.lvobj, sizePercent(100), sizePercent(100));
    }

    /// selects which side to pad in setPad func.
    pub const PadSelector = enum { all, left, right, top, bottom, row, column };

    /// adds a padding style to the object.
    pub fn setPad(self: anytype, v: Coord, p: PadSelector, sel: LvStyle.Selector) void {
        switch (p) {
            .all => {
                const vsel = sel.value();
                lv_obj_set_style_pad_left(self.lvobj, v, vsel);
                lv_obj_set_style_pad_right(self.lvobj, v, vsel);
                lv_obj_set_style_pad_top(self.lvobj, v, vsel);
                lv_obj_set_style_pad_bottom(self.lvobj, v, vsel);
            },
            .left => lv_obj_set_style_pad_left(self.lvobj, v, sel.value()),
            .right => lv_obj_set_style_pad_right(self.lvobj, v, sel.value()),
            .top => lv_obj_set_style_pad_top(self.lvobj, v, sel.value()),
            .bottom => lv_obj_set_style_pad_bottom(self.lvobj, v, sel.value()),
            .row => lv_obj_set_style_pad_row(self.lvobj, v, sel.value()),
            .column => lv_obj_set_style_pad_column(self.lvobj, v, sel.value()),
        }
    }

    /// aligns object to the center of its parent.
    pub fn center(self: anytype) void {
        self.posAlign(.center, 0, 0);
    }

    /// aligns object position. the offset is relative to the specified alignment a.
    pub fn posAlign(self: anytype, a: PosAlign, xoffset: Coord, yoffset: Coord) void {
        lv_obj_align(self.lvobj, @intFromEnum(a), xoffset, yoffset);
    }

    /// similar to `posAlign` but the alignment is in relation to another object `rel`.
    pub fn posAlignTo(self: anytype, rel: anytype, a: PosAlign, xoffset: Coord, yoffset: Coord) void {
        lv_obj_align_to(self.lvobj, rel.lvobj, @intFromEnum(a), xoffset, yoffset);
    }

    /// sets flex layout growth property; same meaning as in CSS flex.
    pub fn flexGrow(self: anytype, val: u8) void {
        lv_obj_set_flex_grow(self.lvobj, val);
    }

    /// adds a style to the object or one of its parts/states based on the selector.
    pub fn addStyle(self: anytype, v: *LvStyle, sel: LvStyle.Selector) void {
        lv_obj_add_style(self.lvobj, v, sel.value());
    }

    /// removes all styles from the object.
    pub fn removeAllStyle(self: anytype) void {
        const sel = LvStyle.Selector{ .part = .any, .state = .any };
        lv_obj_remove_style(self.lvobj, null, sel.value());
    }

    /// removes only the background styles from the object.
    pub fn removeBackgroundStyle(self: anytype) void {
        const sel = LvStyle.Selector{ .part = .main, .state = .any };
        lv_obj_remove_style(self.lvobj, null, sel.value());
    }

    /// sets a desired background color to objects parts/states.
    pub fn setBackgroundColor(self: anytype, v: Color, sel: LvStyle.Selector) void {
        lv_obj_set_style_bg_color(self.lvobj, v, sel.value());
    }

    pub fn show(self: anytype) void {
        self.clearFlag(.hidden);
    }

    pub fn hide(self: anytype) void {
        self.setFlag(.hidden);
    }
};

pub const InteractiveMethods = struct {
    pub fn enable(self: anytype) void {
        lv_obj_clear_state(self.lvobj, c.LV_STATE_DISABLED);
    }

    pub fn disable(self: anytype) void {
        lv_obj_add_state(self.lvobj, c.LV_STATE_DISABLED);
    }
};

/// a base layer object which all the other UI elements are placed onto.
/// there can be only one active screen at a time on a display.
pub const Screen = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;

    /// creates a new screen on default display.
    /// the display must be already initialized.
    pub fn new() !Screen {
        const o = lv_obj_create(null) orelse return error.OutOfMemory;
        return .{ .lvobj = o };
    }

    /// returns active screen of the default display.
    pub fn active() !Screen {
        const o = lv_disp_get_scr_act(null) orelse return error.NoDisplay;
        return .{ .lvobj = o };
    }

    /// makes a screen active.
    pub fn load(scr: Screen) void {
        lv_disp_load_scr(scr.lvobj);
    }
};

/// used as a base parent for many other elements.
pub const Container = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    pub fn new(parent: anytype) !Container {
        const o = lv_obj_create(parent.lvobj) orelse return error.OutOfMemory;
        return .{ .lvobj = o };
    }

    /// creates a new container on the top level, above all others.
    /// suitable for widgets like a popup window.
    pub fn newTop() !Container {
        const toplayer = lv_disp_get_layer_top(null);
        const o = lv_obj_create(toplayer) orelse return error.OutOfMemory;
        return .{ .lvobj = o };
    }

    /// applies flex layout to the container.
    pub fn flex(self: Container, flow: FlexLayout.Flow, opt: FlexLayout.AlignOpt) FlexLayout {
        return FlexLayout.adopt(self.lvobj, flow, opt);
    }
};

/// same as Container but with flex layout of its children.
pub const FlexLayout = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    /// layout flow variations.
    pub const Flow = enum(c.lv_flex_flow_t) {
        row = c.LV_FLEX_FLOW_ROW,
        column = c.LV_FLEX_FLOW_COLUMN,
        row_wrap = c.LV_FLEX_FLOW_ROW_WRAP,
        row_reverse = c.LV_FLEX_FLOW_ROW_REVERSE,
        row_wrap_reverse = c.LV_FLEX_FLOW_ROW_WRAP_REVERSE,
        column_wrap = c.LV_FLEX_FLOW_COLUMN_WRAP,
        column_reverse = c.LV_FLEX_FLOW_COLUMN_REVERSE,
        column_wrap_reverse = c.LV_FLEX_FLOW_COLUMN_WRAP_REVERSE,
    };

    /// flex layout alignments.
    pub const Align = enum(c.lv_flex_align_t) {
        start = c.LV_FLEX_ALIGN_START,
        end = c.LV_FLEX_ALIGN_END,
        center = c.LV_FLEX_ALIGN_CENTER,
        space_evenly = c.LV_FLEX_ALIGN_SPACE_EVENLY,
        space_around = c.LV_FLEX_ALIGN_SPACE_AROUND,
        space_between = c.LV_FLEX_ALIGN_SPACE_BETWEEN,
    };

    /// cross-direction alignment.
    pub const AlignCross = enum(c.lv_flex_align_t) {
        start = c.LV_FLEX_ALIGN_START,
        end = c.LV_FLEX_ALIGN_END,
        center = c.LV_FLEX_ALIGN_CENTER,
    };

    /// main, cross and track are similar to CSS flex concepts.
    pub const AlignOpt = struct {
        main: Align = .start,
        cross: AlignCross = .start,
        track: Align = .start,
        all: ?Align = null, // overrides all 3 above
        width: ?Coord = null,
        height: ?union(enum) { fixed: Coord, content } = null,
    };

    /// creates a new object with flex layout and some default padding.
    pub fn new(parent: anytype, flow: Flow, opt: AlignOpt) !FlexLayout {
        const obj = lv_obj_create(parent.lvobj) orelse return error.OutOfMemory;
        // remove background style first. otherwise, it'll also remove flex.
        const bgsel = LvStyle.Selector{ .part = .main, .state = .any };
        lv_obj_remove_style(obj, null, bgsel.value());
        const flex = adopt(obj, flow, opt);
        flex.padColumnDefault();
        if (opt.width) |w| {
            flex.setWidth(w);
        }
        if (opt.height) |h| {
            switch (h) {
                .content => flex.setHeightToContent(),
                .fixed => |v| flex.setHeight(v),
            }
        }
        return flex;
    }

    fn adopt(obj: *LvObj, flow: Flow, opt: AlignOpt) FlexLayout {
        lv_obj_set_flex_flow(obj, @intFromEnum(flow));
        if (opt.all) |a| {
            const v = @intFromEnum(a);
            lv_obj_set_flex_align(obj, v, v, v);
        } else {
            lv_obj_set_flex_align(obj, @intFromEnum(opt.main), @intFromEnum(opt.cross), @intFromEnum(opt.track));
        }
        return .{ .lvobj = obj };
    }

    /// sets flex layout flow on the object.
    pub fn setFlow(self: FlexLayout, ff: Flow) void {
        lv_obj_set_flex_flow(self.lvobj, @intFromEnum(ff));
    }

    /// sets flex layout alignments.
    pub fn setAlign(self: FlexLayout, main: Align, cross: AlignCross, track: Align) void {
        lv_obj_set_flex_align(self.lvobj, @intFromEnum(main), @intFromEnum(cross), @intFromEnum(track));
    }

    /// same as setPad .column but using a default constant to make flex layouts consistent.
    pub fn padColumnDefault(self: FlexLayout) void {
        self.setPad(20, .column, .{});
    }
};

pub const Window = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    pub fn new(parent: anytype, header_height: i16, title: [*:0]const u8) !Window {
        const lv_win = lv_win_create(parent.lvobj, header_height) orelse return error.OutOfMemory;
        if (lv_win_add_title(lv_win, title) == null) {
            return error.OutOfMemory;
        }
        return .{ .lvobj = lv_win };
    }

    /// creates a new window on top of all other elements.
    pub fn newTop(header_height: i16, title: [*:0]const u8) !Window {
        return new(try Screen.active(), header_height, title);
    }

    /// returns content part of the window, i.e. the main part below title.
    pub fn content(self: Window) Container {
        return .{ .lvobj = lv_win_get_content(self.lvobj) };
    }
};

/// a custom element consisting of a flex container with a title-sized label
/// on top.
pub const Card = struct {
    lvobj: *LvObj,
    title: Label,
    spinner: ?Spinner = null,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    pub const Opt = struct {
        /// embeds a spinner in the top-right corner; control with spin fn.
        spinner: bool = false,
    };

    pub fn new(parent: anytype, title: [*:0]const u8, opt: Opt) !Card {
        const flex = (try Container.new(parent)).flex(.column, .{});
        flex.setHeightToContent();
        flex.setWidth(sizePercent(100));
        var card: Card = .{ .lvobj = flex.lvobj, .title = undefined };

        if (opt.spinner) {
            const row = try FlexLayout.new(flex, .row, .{});
            row.setWidth(sizePercent(100));
            row.setHeightToContent();
            card.title = try Label.new(row, title, .{});
            card.title.flexGrow(1);
            card.spinner = try Spinner.new(row);
            card.spinner.?.flexGrow(0);
            card.spin(.off);
        } else {
            card.title = try Label.new(flex, title, .{});
        }
        card.title.addStyle(nm_style_title(), .{});

        return card;
    }

    pub fn spin(self: Card, onoff: enum { on, off }) void {
        if (self.spinner) |p| switch (onoff) {
            .on => p.show(),
            .off => p.hide(),
        };
    }
};

/// represents lv_label_t in C, a text label.
pub const Label = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    pub const Opt = struct {
        // LVGL defaults to .wrap
        long_mode: ?enum(c.lv_label_long_mode_t) {
            wrap = c.LV_LABEL_LONG_WRAP, // keep the object width, wrap the too long lines and expand the object height
            dot = c.LV_LABEL_LONG_DOT, // keep the size and write dots at the end if the text is too long
            scroll = c.LV_LABEL_LONG_SCROLL, // keep the size and roll the text back and forth
            scroll_circular = c.LV_LABEL_LONG_SCROLL_CIRCULAR, // keep the size and roll the text circularly
            clip = c.LV_LABEL_LONG_CLIP, // keep the size and clip the text out of it
        } = null,
        pos: ?PosAlign = null,
        recolor: bool = false,
    };

    /// the text value is copied into a heap-allocated alloc.
    pub fn new(parent: anytype, text: ?[*:0]const u8, opt: Opt) !Label {
        const lv_label = lv_label_create(parent.lvobj) orelse return error.OutOfMemory;
        if (text) |s| {
            lv_label_set_text(lv_label, s);
        }
        //lv_obj_set_height(lb, sizeContent); // default
        if (opt.long_mode) |m| {
            lv_label_set_long_mode(lv_label, @intFromEnum(m));
        }
        if (opt.pos) |p| {
            lv_obj_align(lv_label, @intFromEnum(p), 0, 0);
        }
        if (opt.recolor) {
            lv_label_set_recolor(lv_label, true);
        }
        return .{ .lvobj = lv_label };
    }

    /// formats label text using std.fmt.format and the provided buffer.
    /// the text is heap-dup'ed so no need to retain the buf.
    pub fn newFmt(parent: anytype, buf: []u8, comptime format: []const u8, args: anytype, opt: Opt) !Label {
        const text = try std.fmt.bufPrintZ(buf, format, args);
        return new(parent, text, opt);
    }

    /// sets label text to a new value.
    /// previous value is dealloc'ed.
    pub fn setText(self: Label, text: [:0]const u8) void {
        lv_label_set_text(self.lvobj, text.ptr);
    }

    /// sets label text without heap alloc but assumes text outlives the label obj.
    pub fn setTextStatic(self: Label, text: [*:0]const u8) void {
        lv_label_set_text_static(self.lvobj, text);
    }

    /// formats a new label text and passes it on to `setText`.
    /// the buffer can be dropped once the function returns.
    pub fn setTextFmt(self: Label, buf: []u8, comptime format: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrintZ(buf, format, args);
        self.setText(s);
    }

    /// sets label text color.
    pub fn setColor(self: Label, v: Color, sel: LvStyle.Selector) void {
        lv_obj_set_style_text_color(self.lvobj, v, sel.value());
    }
};

/// a button with a child Label.
pub const TextButton = struct {
    lvobj: *LvObj,
    label: Label,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;
    pub usingnamespace InteractiveMethods;

    pub fn new(parent: anytype, text: [*:0]const u8) !TextButton {
        const btn = lv_btn_create(parent.lvobj) orelse return error.OutOfMemory;
        const label = try Label.new(Container{ .lvobj = btn }, text, .{ .long_mode = .dot, .pos = .center });
        return .{ .lvobj = btn, .label = label };
    }
};

pub const TextArea = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;
    pub usingnamespace InteractiveMethods;

    pub const Opt = struct {
        oneline: bool = true,
        password_mode: bool = false,
        maxlen: ?u32 = null,
    };

    pub fn new(parent: anytype, opt: Opt) !TextArea {
        const obj = lv_textarea_create(parent.lvobj) orelse return error.OutOfMemory;
        const ta: TextArea = .{ .lvobj = obj };
        ta.setOpt(opt);
        return ta;
    }

    pub fn setOpt(self: TextArea, opt: Opt) void {
        lv_textarea_set_one_line(self.lvobj, opt.oneline);
        lv_textarea_set_password_mode(self.lvobj, opt.password_mode);
        if (opt.maxlen) |n| {
            lv_textarea_set_max_length(self.lvobj, n);
        }
    }

    /// `text` arg is heap-duplicated by LVGL's alloc and owned by this text area object.
    pub fn setText(self: TextArea, txt: [:0]const u8) void {
        lv_textarea_set_text(self.lvobj, txt.ptr);
    }

    /// returned value is still owned by `TextArea`.
    pub fn text(self: TextArea) []const u8 {
        const buf = lv_textarea_get_text(self.lvobj) orelse return "";
        //const slice: [:0]const u8 = std.mem.span(buf);
        //return slice;
        return std.mem.span(buf);
    }
};

pub const Spinner = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    pub fn new(parent: anytype) !Spinner {
        const spin = lv_spinner_create(parent.lvobj, 1000, 60) orelse return error.OutOfMemory;
        lv_obj_set_size(spin, 20, 20);
        const ind: LvStyle.Selector = .{ .part = .indicator };
        lv_obj_set_style_arc_width(spin, 4, ind.value());
        return .{ .lvobj = spin };
    }
};

/// represents lv_bar_t in C.
/// see https://docs.lvgl.io/8.3/widgets/core/bar.html for details.
pub const Bar = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    /// creates a horizontal bar with the default 0-100 range.
    pub fn new(parent: anytype) !Bar {
        const lv_bar = lv_bar_create(parent.lvobj) orelse return error.OutOfMemory;
        lv_obj_set_size(lv_bar, 200, 20);
        return .{ .lvobj = lv_bar };
    }

    /// sets a new value of a bar current position.
    pub fn setValue(self: Bar, val: i32) void {
        lv_bar_set_value(self.lvobj, val, c.LV_ANIM_OFF);
    }

    /// sets minimum and max values of the bar range.
    pub fn setRange(self: Bar, min: i32, max: i32) void {
        lv_bar_set_range(self.lvobj, min, max);
    }
};

pub const Dropdown = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;
    pub usingnamespace InteractiveMethods;

    /// creates a new dropdown with the options provided in ostr, a '\n' delimited list.
    /// the options are alloc-duped by LVGL and free'd when the dropdown is destroy'ed.
    /// LVGL's lv_dropdown drawing supports up to 128 chars.
    pub fn new(parent: anytype, ostr: [*:0]const u8) !Dropdown {
        const o = lv_dropdown_create(parent.lvobj) orelse return error.OutOfMemory;
        lv_dropdown_set_options(o, ostr);
        return .{ .lvobj = o };
    }

    /// same as new except options are not alloc-duplicated. the ostr must live at least
    /// as long as the dropdown object.
    pub fn newStatic(parent: anytype, ostr: [*:0]const u8) !Dropdown {
        const o = lv_dropdown_create(parent.lvobj) orelse return error.OutOfMemory;
        lv_dropdown_set_options_static(o, ostr);
        return .{ .lvobj = o };
    }

    /// once set, the text is shown regardless of the selected option until removed
    /// with `clearText`. the text must outlive the dropdown object.
    pub fn setText(self: Dropdown, text: [*:0]const u8) void {
        lv_dropdown_set_text(self.lvobj, text);
    }

    /// deletes the text set with `setText`.
    pub fn clearText(self: Dropdown) void {
        lv_dropdown_set_text(self.lvobj, null);
    }

    /// the options are alloc-duped by LVGL and free'd when the dropdown is destroy'ed.
    /// LVGL's lv_dropdown drawing supports up to 128 chars.
    pub fn setOptions(self: Dropdown, opts: [*:0]const u8) void {
        lv_dropdown_set_options(self.lvobj, opts);
    }

    pub fn clearOptions(self: Dropdown) void {
        lv_dropdown_clear_options(self.lvobj);
    }

    pub fn addOption(self: Dropdown, opt: [*:0]const u8, pos: u32) void {
        lv_dropdown_add_option(self.lvobj, opt, pos);
    }

    /// idx is 0-based index of the option item provided to new or newStatic.
    pub fn setSelected(self: Dropdown, idx: u16) void {
        lv_dropdown_set_selected(self.lvobj, idx);
    }

    pub fn getSelected(self: Dropdown) u16 {
        return lv_dropdown_get_selected(self.lvobj);
    }

    /// returns selected option as a slice of the buf.
    /// LVGL's lv_dropdown supports up to 128 chars.
    pub fn getSelectedStr(self: Dropdown, buf: []u8) [:0]const u8 {
        const buflen: u32 = @min(buf.len, std.math.maxInt(u32));
        lv_dropdown_get_selected_str(self.lvobj, buf.ptr, buflen);
        buf[buf.len - 1] = 0;
        const cbuf: [*c]u8 = buf.ptr;
        const name: [:0]const u8 = std.mem.span(cbuf);
        return name;
    }
};

pub const QrCode = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    pub fn new(parent: anytype, size: Coord, data: ?[]const u8) !QrCode {
        const o = lv_qrcode_create(parent.lvobj, size, Black, White) orelse return error.OutOfMemory;
        const q = QrCode{ .lvobj = o };
        errdefer q.destroy();
        if (data) |d| {
            try q.setQrData(d);
        }
        return q;
    }

    pub fn setQrData(self: QrCode, data: []const u8) !void {
        if (data.len > std.math.maxInt(u32)) {
            return error.QrCodeDataTooLarge;
        }
        const len: u32 = @truncate(data.len);
        const res = lv_qrcode_update(self.lvobj, data.ptr, len);
        if (res != c.LV_RES_OK) {
            return error.QrCodeSetData;
        }
    }
};

pub const Keyboard = struct {
    lvobj: *LvObj,

    pub usingnamespace BaseObjMethods;
    pub usingnamespace WidgetMethods;

    const Mode = enum(c.lv_keyboard_mode_t) {
        lower = c.LV_KEYBOARD_MODE_TEXT_LOWER,
        upper = c.LV_KEYBOARD_MODE_TEXT_UPPER,
        special = c.LV_KEYBOARD_MODE_SPECIAL,
        number = c.LV_KEYBOARD_MODE_NUMBER,
        user1 = c.LV_KEYBOARD_MODE_USER_1,
        user2 = c.LV_KEYBOARD_MODE_USER_2,
        user3 = c.LV_KEYBOARD_MODE_USER_3,
        user4 = c.LV_KEYBOARD_MODE_USER_4,
    };

    pub fn new(parent: anytype, mode: Mode) !Keyboard {
        const kb = lv_keyboard_create(parent.lvobj) orelse return error.OutOfMemory;
        lv_keyboard_set_mode(kb, @intFromEnum(mode));
        const sel = LvStyle.Selector{ .part = .item };
        lv_obj_set_style_text_font(kb, nm_font_large(), sel.value());
        return .{ .lvobj = kb };
    }

    pub fn attach(self: Keyboard, ta: TextArea) void {
        lv_keyboard_set_textarea(self.lvobj, ta.lvobj);
    }

    pub fn setMode(self: Keyboard, m: Mode) void {
        lv_keyboard_set_mode(self.lvobj, m);
    }
};

/// represents lv_obj_t type in C.
pub const LvObj = opaque {
    /// feature-flags controlling object's behavior.
    /// OR'ed values are possible.
    pub const Flag = enum(c.lv_obj_flag_t) {
        hidden = c.LV_OBJ_FLAG_HIDDEN, // make the object hidden, like it wasn't there at all
        clickable = c.LV_OBJ_FLAG_CLICKABLE, // make the object clickable by the input devices
        focusable = c.LV_OBJ_FLAG_CLICK_FOCUSABLE, // add focused state to the object when clicked
        checkable = c.LV_OBJ_FLAG_CHECKABLE, // toggle checked state when the object is clicked
        scrollable = c.LV_OBJ_FLAG_SCROLLABLE, // make the object scrollable
        scroll_elastic = c.LV_OBJ_FLAG_SCROLL_ELASTIC, // allow scrolling inside but with slower speed
        scroll_momentum = c.LV_OBJ_FLAG_SCROLL_MOMENTUM, // make the object scroll further when "thrown"
        scroll_one = c.LV_OBJ_FLAG_SCROLL_ONE, // allow scrolling only one snappable children
        scroll_chain_hor = c.LV_OBJ_FLAG_SCROLL_CHAIN_HOR, // allow propagating the horizontal scroll to a parent
        scroll_chain_ver = c.LV_OBJ_FLAG_SCROLL_CHAIN_VER, // allow propagating the vertical scroll to a parent
        scroll_chain = c.LV_OBJ_FLAG_SCROLL_CHAIN,
        scroll_on_focus = c.LV_OBJ_FLAG_SCROLL_ON_FOCUS, // automatically scroll object to make it visible when focused
        scroll_with_arrow = c.LV_OBJ_FLAG_SCROLL_WITH_ARROW, // allow scrolling the focused object with arrow keys
        snappable = c.LV_OBJ_FLAG_SNAPPABLE, // if scroll snap is enabled on the parent it can snap to this object
        press_lock = c.LV_OBJ_FLAG_PRESS_LOCK, // keep the object pressed even if the press slid from the object
        event_bubble = c.LV_OBJ_FLAG_EVENT_BUBBLE, // propagate the events to the parent too
        gesture_bubble = c.LV_OBJ_FLAG_GESTURE_BUBBLE, // propagate the gestures to the parent
        ignore_layout = c.LV_OBJ_FLAG_IGNORE_LAYOUT, // make the object position-able by the layouts
        floating = c.LV_OBJ_FLAG_FLOATING, // do not scroll the object when the parent scrolls and ignore layout
        overflow_visible = c.LV_OBJ_FLAG_OVERFLOW_VISIBLE, // do not clip the children's content to the parent's boundary

        user1 = c.LV_OBJ_FLAG_USER_1, // custom flag, free to use by user
        user2 = c.LV_OBJ_FLAG_USER_2, // custom flag, free to use by user
        user3 = c.LV_OBJ_FLAG_USER_3, // custom flag, free to use by user
        user4 = c.LV_OBJ_FLAG_USER_4, // custom flag, free to use by user
    };
};

/// possible states of a widget, equivalent to lv_state_t in C.
/// OR'ed values are possible.
pub const State = enum(c.lv_state_t) {
    default = c.LV_STATE_DEFAULT,
    checked = c.LV_STATE_CHECKED,
    focused = c.LV_STATE_FOCUSED,
    focuse_key = c.LV_STATE_FOCUS_KEY,
    edited = c.LV_STATE_EDITED,
    hovered = c.LV_STATE_HOVERED,
    pressed = c.LV_STATE_PRESSED,
    scrolled = c.LV_STATE_SCROLLED,
    disabled = c.LV_STATE_DISABLED,

    user1 = c.LV_STATE_USER_1,
    user2 = c.LV_STATE_USER_2,
    user3 = c.LV_STATE_USER_3,
    user4 = c.LV_STATE_USER_4,

    any = c.LV_STATE_ANY, // special value can be used in some functions to target all states
};

/// possible parts of a widget, equivalent to lv_part_t in C.
/// a part is an internal building block of a widget. for example, a slider
/// consists of background, an indicator and a knob.
pub const Part = enum(c.lv_part_t) {
    main = c.LV_PART_MAIN, // a background like rectangle
    scrollbar = c.LV_PART_SCROLLBAR,
    indicator = c.LV_PART_INDICATOR, // an indicator for slider, bar, switch, or the tick box of the checkbox
    knob = c.LV_PART_KNOB, // like a handle to grab to adjust the value
    selected = c.LV_PART_SELECTED, // the currently selected option or section
    item = c.LV_PART_ITEMS, // used when the widget has multiple similar elements like table cells
    ticks = c.LV_PART_TICKS, // ticks on a scale like in a chart or a meter
    cursor = c.LV_PART_CURSOR, // a specific place in text areas or a chart

    custom1 = c.LV_PART_CUSTOM_FIRST, // extension point for custom widgets

    any = c.LV_PART_ANY, // special value can be used in some functions to target all parts
};

/// Coord is a pixel unit for all x/y coordinates and dimensions.
pub const Coord = c.lv_coord_t;

/// converts a percentage value between 0 and 1000 to a regular unit.
/// equivalent to LV_PCT in C.
pub inline fn sizePercent(v: Coord) Coord {
    return if (v < 0) LV_COORD_SET_SPEC(1000 - v) else LV_COORD_SET_SPEC(v);
}

/// a special constant setting a [part of] widget to its contents.
/// equivalent to LV_SIZE_CONTENT in C.
pub const sizeContent = LV_COORD_SET_SPEC(2001);

// from lv_area.h
//#if LV_USE_LARGE_COORD
//#define _LV_COORD_TYPE_SHIFT    (29U)
//#else
//#define _LV_COORD_TYPE_SHIFT    (13U)
//#endif
const _LV_COORD_TYPE_SHIFT = 13; // TODO: comptime switch between 13 and 29?
const _LV_COORD_TYPE_SPEC = 1 << _LV_COORD_TYPE_SHIFT;

inline fn LV_COORD_SET_SPEC(x: Coord) Coord {
    return x | _LV_COORD_TYPE_SPEC;
}

/// object position alignments.
pub const PosAlign = enum(c.lv_align_t) {
    default = c.LV_ALIGN_DEFAULT,
    top_left = c.LV_ALIGN_TOP_LEFT,
    top_mid = c.LV_ALIGN_TOP_MID,
    top_right = c.LV_ALIGN_TOP_RIGHT,
    bottom_left = c.LV_ALIGN_BOTTOM_LEFT,
    bottom_mid = c.LV_ALIGN_BOTTOM_MID,
    bottom_right = c.LV_ALIGN_BOTTOM_RIGHT,
    left_mid = c.LV_ALIGN_LEFT_MID,
    right_mid = c.LV_ALIGN_RIGHT_MID,
    center = c.LV_ALIGN_CENTER,

    out_top_left = c.LV_ALIGN_OUT_TOP_LEFT,
    out_top_mid = c.LV_ALIGN_OUT_TOP_MID,
    out_top_right = c.LV_ALIGN_OUT_TOP_RIGHT,
    out_bottom_left = c.LV_ALIGN_OUT_BOTTOM_LEFT,
    out_bottom_mid = c.LV_ALIGN_OUT_BOTTOM_MID,
    out_bottom_right = c.LV_ALIGN_OUT_BOTTOM_RIGHT,
    out_left_top = c.LV_ALIGN_OUT_LEFT_TOP,
    out_left_mid = c.LV_ALIGN_OUT_LEFT_MID,
    out_left_bottom = c.LV_ALIGN_OUT_LEFT_BOTTOM,
    out_right_top = c.LV_ALIGN_OUT_RIGHT_TOP,
    out_right_mid = c.LV_ALIGN_OUT_RIGHT_MID,
    out_right_bottom = c.LV_ALIGN_OUT_RIGHT_BOTTOM,
};

// ==========================================================================
// imports from nakamochi custom C code that extends LVGL
// ==========================================================================

/// returns a red button style.
pub extern fn nm_style_btn_red() *LvStyle; // TODO: make it private
/// returns a title style with a larger font.
pub extern fn nm_style_title() *LvStyle; // TODO: make it private
/// returns default font of large size.
pub extern fn nm_font_large() *const LvFont; // TODO: make it private

// the "native" lv_obj_set/get user_data are static inline, so make our own funcs.
extern "c" fn nm_obj_userdata(obj: *LvObj) ?*anyopaque;
extern "c" fn nm_obj_set_userdata(obj: *LvObj, data: ?*const anyopaque) void;

// ==========================================================================
// imports from LVGL C code
// ==========================================================================

extern fn lv_init() void;
extern fn lv_log_register_print_cb(*const fn (msg: [*:0]const u8) callconv(.C) void) void;

// input devices ------------------------------------------------------------

/// deallocate and delete an input device from LVGL registry.
extern fn lv_indev_delete(indev: *LvIndev) void;
/// return next device in the list or head if indev is null.
extern fn lv_indev_get_next(indev: ?*LvIndev) ?*LvIndev;

// timers -------------------------------------------------------------------

/// timer handler is the busy-wait loop in LVGL.
/// returns period after which it is to be run again, in ms.
extern fn lv_timer_handler() u32;
extern fn lv_timer_create(callback: LvTimer.Callback, period_ms: u32, userdata: ?*anyopaque) ?*LvTimer;
extern fn lv_timer_del(timer: *LvTimer) void;
extern fn lv_timer_set_repeat_count(timer: *LvTimer, n: i32) void;

// events --------------------------------------------------------------------

extern fn lv_event_get_code(e: *LvEvent) LvEvent.Code;
extern fn lv_event_get_current_target(e: *LvEvent) *LvObj;
extern fn lv_event_get_target(e: *LvEvent) *LvObj;
extern fn lv_event_get_user_data(e: *LvEvent) ?*anyopaque;
extern fn lv_event_stop_bubbling(e: *LvEvent) void;
extern fn lv_obj_add_event_cb(obj: *LvObj, cb: LvEvent.Callback, filter: LvEvent.Code, userdata: ?*anyopaque) *LvEvent.Descriptor;

// display and screen functions ----------------------------------------------

/// returns pointer to the default display.
extern fn lv_disp_get_default() *LvDisp;
/// returns elapsed time since last user activity on a specific display or any if disp is null.
extern fn lv_disp_get_inactive_time(disp: ?*LvDisp) u32;
/// makes it so as if a user activity happened.
/// this resets an internal counter in lv_disp_get_inactive_time.
extern fn lv_disp_trig_activity(disp: ?*LvDisp) void;
/// forces redraw of dirty areas.
extern fn lv_refr_now(disp: ?*LvDisp) void;

extern fn lv_disp_get_hor_res(disp: ?*LvDisp) c.lv_coord_t;
extern fn lv_disp_get_ver_res(disp: ?*LvDisp) c.lv_coord_t;

/// returns a pointer to the active screen on a given display
/// or default if null. if no display is registered, returns null.
extern fn lv_disp_get_scr_act(disp: ?*LvDisp) ?*LvObj;
/// returns the top layer on a given display or default if null.
/// top layer is the same on every screen, above the normal screen layer.
extern fn lv_disp_get_layer_top(disp: ?*LvDisp) *LvObj;
/// makes a screen active without animation.
extern fn lv_disp_load_scr(scr: *LvObj) void;

// styling and colors --------------------------------------------------------

/// initalizes a style struct. must be called only once per style.
extern fn lv_style_init(style: *LvStyle) void;
extern fn lv_style_set_bg_color(style: *LvStyle, color: Color) void;

extern fn lv_obj_add_style(obj: *LvObj, style: *LvStyle, sel: c.lv_style_selector_t) void;
extern fn lv_obj_remove_style(obj: *LvObj, style: ?*LvStyle, sel: c.lv_style_selector_t) void;
extern fn lv_obj_remove_style_all(obj: *LvObj) void;
extern fn lv_obj_set_style_bg_color(obj: *LvObj, val: Color, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_text_color(obj: *LvObj, val: Color, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_text_font(obj: *LvObj, font: *const LvFont, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_pad_left(obj: *LvObj, val: c.lv_coord_t, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_pad_right(obj: *LvObj, val: c.lv_coord_t, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_pad_top(obj: *LvObj, val: c.lv_coord_t, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_pad_bottom(obj: *LvObj, val: c.lv_coord_t, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_pad_row(obj: *LvObj, val: c.lv_coord_t, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_pad_column(obj: *LvObj, val: c.lv_coord_t, sel: c.lv_style_selector_t) void;
extern fn lv_obj_set_style_arc_width(obj: *LvObj, val: c.lv_coord_t, sel: c.lv_style_selector_t) void;

// TODO: port these to zig
extern fn lv_palette_main(c.lv_palette_t) Color;
extern fn lv_palette_lighten(c.lv_palette_t, level: u8) Color;
extern fn lv_palette_darken(c.lv_palette_t, level: u8) Color;

// objects and widgets -------------------------------------------------------

/// creates a new base object at the specific parent or a new screen if the parent is null.
extern fn lv_obj_create(parent: ?*LvObj) ?*LvObj;
/// deletes and deallocates an object and all its children from UI tree.
extern fn lv_obj_del(obj: *LvObj) void;
/// deletes children of the obj.
extern fn lv_obj_clean(obj: *LvObj) void;
/// recalculates an object layout based on all its children.
pub extern fn lv_obj_update_layout(obj: *const LvObj) void;

extern fn lv_obj_add_state(obj: *LvObj, c.lv_state_t) void;
extern fn lv_obj_clear_state(obj: *LvObj, c.lv_state_t) void;
extern fn lv_obj_add_flag(obj: *LvObj, v: c.lv_obj_flag_t) void;
extern fn lv_obj_clear_flag(obj: *LvObj, v: c.lv_obj_flag_t) void;
extern fn lv_obj_has_flag(obj: *LvObj, v: c.lv_obj_flag_t) bool;

extern fn lv_obj_align(obj: *LvObj, a: c.lv_align_t, x: c.lv_coord_t, y: c.lv_coord_t) void;
extern fn lv_obj_align_to(obj: *LvObj, rel: *LvObj, a: c.lv_align_t, x: c.lv_coord_t, y: c.lv_coord_t) void;
extern fn lv_obj_set_height(obj: *LvObj, h: c.lv_coord_t) void;
extern fn lv_obj_set_width(obj: *LvObj, w: c.lv_coord_t) void;
extern fn lv_obj_set_size(obj: *LvObj, w: c.lv_coord_t, h: c.lv_coord_t) void;
extern fn lv_obj_get_content_width(obj: *const LvObj) c.lv_coord_t;

extern fn lv_obj_set_flex_flow(obj: *LvObj, flow: c.lv_flex_flow_t) void;
extern fn lv_obj_set_flex_grow(obj: *LvObj, val: u8) void;
extern fn lv_obj_set_flex_align(obj: *LvObj, main: c.lv_flex_align_t, cross: c.lv_flex_align_t, track: c.lv_flex_align_t) void;

extern fn lv_btn_create(parent: *LvObj) ?*LvObj;

extern fn lv_btnmatrix_create(parent: *LvObj) ?*LvObj;
extern fn lv_btnmatrix_set_selected_btn(obj: *LvObj, id: u16) void;
extern fn lv_btnmatrix_set_map(obj: *LvObj, map: [*]const [*:0]const u8) void;
extern fn lv_btnmatrix_set_btn_ctrl(obj: *LvObj, id: u16, ctrl: c.lv_btnmatrix_ctrl_t) void;
extern fn lv_btnmatrix_set_btn_ctrl_all(obj: *LvObj, ctrl: c.lv_btnmatrix_ctrl_t) void;

extern fn lv_label_create(parent: *LvObj) ?*LvObj;
extern fn lv_label_set_text(label: *LvObj, text: [*:0]const u8) void;
extern fn lv_label_set_text_static(label: *LvObj, text: [*:0]const u8) void;
extern fn lv_label_set_long_mode(label: *LvObj, mode: c.lv_label_long_mode_t) void;
extern fn lv_label_set_recolor(label: *LvObj, enable: bool) void;

extern fn lv_textarea_create(parent: *LvObj) ?*LvObj;
extern fn lv_textarea_get_text(obj: *LvObj) ?[*:0]const u8;
extern fn lv_textarea_set_max_length(obj: *LvObj, n: u32) void;
extern fn lv_textarea_set_one_line(obj: *LvObj, enable: bool) void;
extern fn lv_textarea_set_password_mode(obj: *LvObj, enable: bool) void;
extern fn lv_textarea_set_text(obj: *LvObj, text: [*:0]const u8) void;

extern fn lv_dropdown_create(parent: *LvObj) ?*LvObj;
extern fn lv_dropdown_set_text(obj: *LvObj, text: ?[*:0]const u8) void;
extern fn lv_dropdown_set_options(obj: *LvObj, options: [*:0]const u8) void;
extern fn lv_dropdown_set_options_static(obj: *LvObj, options: [*:0]const u8) void;
extern fn lv_dropdown_add_option(obj: *LvObj, option: [*:0]const u8, pos: u32) void;
extern fn lv_dropdown_clear_options(obj: *LvObj) void;
extern fn lv_dropdown_set_selected(obj: *LvObj, idx: u16) void;
extern fn lv_dropdown_get_selected(obj: *const LvObj) u16;
extern fn lv_dropdown_get_selected_str(obj: *const LvObj, buf: [*]u8, bufsize: u32) void;

extern fn lv_spinner_create(parent: *LvObj, speed_ms: u32, arc_deg: u32) ?*LvObj;

extern fn lv_bar_create(parent: *LvObj) ?*LvObj;
extern fn lv_bar_set_value(bar: *LvObj, value: i32, c.lv_anim_enable_t) void;
extern fn lv_bar_set_range(bar: *LvObj, min: i32, max: i32) void;

extern fn lv_win_create(parent: *LvObj, header_height: c.lv_coord_t) ?*LvObj;
extern fn lv_win_add_title(win: *LvObj, title: [*:0]const u8) ?*LvObj;
extern fn lv_win_get_content(win: *LvObj) *LvObj;

extern fn lv_qrcode_create(parent: *LvObj, size: c.lv_coord_t, dark: Color, light: Color) ?*LvObj;
extern fn lv_qrcode_update(qrcode: *LvObj, data: *const anyopaque, data_len: u32) c.lv_res_t;

extern fn lv_keyboard_create(parent: *LvObj) ?*LvObj;
extern fn lv_keyboard_set_textarea(kb: *LvObj, ta: *LvObj) void;
extern fn lv_keyboard_set_mode(kb: *LvObj, mode: c.lv_keyboard_mode_t) void;
