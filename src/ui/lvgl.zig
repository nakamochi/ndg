///! LVGL types in zig.
///
/// lv_xxx functions are directly linked against LVGL lib.
/// other functions, without the lv_ prefix are defined in zig and provide type safety
/// and extra functionality, sometimes composed of multiple calls to lv_xxx.
///
/// nm_xxx functions defined here are exported with "c" convention to allow
/// calls from C code.
///
/// the module usage must be started with a call to init.
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
    pub fn destroy(self: *LvTimer) void {
        lv_timer_del(self);
    }

    /// after the repeat count is reached, the timer is destroy'ed automatically.
    /// to run the timer indefinitely, use -1 for repeat count.
    pub fn setRepeatCount(self: *LvTimer, n: i32) void {
        lv_timer_set_repeat_count(self, n);
    }
};

/// creates a new timer with indefinite repeat count.
pub fn createTimer(f: TimerCallback, period_ms: u32, userdata: ?*anyopaque) !*LvTimer {
    return lv_timer_create(f, period_ms, userdata) orelse error.OutOfMemory;
}

/// a timer callback signature.
pub const TimerCallback = *const fn (timer: *LvTimer) callconv(.C) void;

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

/// a zig representation of lv_event_t, required by all event callbacks.
pub const LvEvent = opaque {
    pub fn code(self: *LvEvent) EventCode {
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
};

/// event callback, equivalent of lv_event_cb_t.
pub const LvEventCallback = *const fn (e: *LvEvent) callconv(.C) void;
/// event descriptor returned from a callback setup.
pub const LvEventDescr = opaque {};

/// all possible codes for an event to trigger a function call,
/// equivalent to lv_event_code_t.
pub const EventCode = enum(c.lv_event_code_t) {
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

/// represents lv_disp_t in C.
pub const LvDisp = opaque {};

/// returns display horizontal resolution.
pub fn displayHoriz() Coord {
    return lv_disp_get_hor_res(null);
}

/// returns display vertical resolution.
pub fn displayVert() Coord {
    return lv_disp_get_ver_res(null);
}

/// forces redraw of dirty areas.
pub fn displayRedraw() void {
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

/// returns active screen of the default display.
pub fn activeScreen() !*LvObj {
    return lv_disp_get_scr_act(null) orelse error.NoDisplay;
}

/// creates a new screen on default display. essentially same as lv_obj_create with null parent.
/// the display must be already initialized.
pub fn createScreen() !*LvObj {
    if (lv_obj_create(null)) |o| {
        return o;
    } else {
        return error.OutOfMemory;
    }
}

/// makes a screen s active.
pub fn loadScreen(s: *LvObj) void {
    lv_disp_load_scr(s);
}

/// represents lv_style_t in C.
pub const LvStyle = opaque {};

/// indicates which parts and in which states to apply a style to an object.
pub const StyleSelector = struct {
    state: State = .default,
    part: Part = .main,

    /// produce an int value suitable for lv_xxx functions.
    fn value(self: StyleSelector) c.lv_style_selector_t {
        return @enumToInt(self.part) | @enumToInt(self.state);
    }
};

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
        .b = @truncate(u5, b >> 3),
        .g = @truncate(u6, g >> 2),
        .r = @truncate(u5, r >> 3),
    };
    return @bitCast(Color, c16);
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
};

/// lightening or darkening levels of the main palette colors.
pub const PaletteModLevel = enum(u8) {
    level1 = 1,
    level2 = 2,
    level3 = 3,
    level4 = 4,
    level5 = 5,
};

/// returns main color from the predefined palette.
pub inline fn paletteMain(p: Palette) Color {
    return lv_palette_main(@enumToInt(p));
}

/// makes the main color from the predefined palette lighter according to the
/// specified level.
pub inline fn paletteLighten(p: Palette, l: PaletteModLevel) Color {
    return lv_palette_lighten(@enumToInt(p), @enumToInt(l));
}

/// makes the main color from the predefined palette darker according to the
/// specified level.
pub inline fn paletteDarken(p: Palette, l: PaletteModLevel) Color {
    return lv_palette_darken(@enumToInt(p), @enumToInt(l));
}

/// represents lv_obj_t type in C.
pub const LvObj = opaque {
    /// deallocates all resources used by the object, including its children.
    /// user data pointers are untouched.
    pub fn destroy(self: *LvObj) void {
        lv_obj_del(self);
    }

    /// deallocates all resources used by the object's children.
    pub fn deleteChildren(self: *LvObj) void {
        lv_obj_clean(self);
    }

    /// creates a new event handler where cb is called upon event with the filter code.
    /// to make cb called on any event, use EventCode.all filter.
    /// multiple event handlers are called in the same order as they were added.
    /// the user data pointer udata is available in a handler using LvEvent.userdata fn.
    pub fn on(self: *LvObj, filter: EventCode, cb: LvEventCallback, udata: ?*anyopaque) *LvEventDescr {
        return lv_obj_add_event_cb(self, cb, filter, udata);
    }

    /// sets label text to a new value.
    pub fn setLabelText(self: *LvObj, text: [*:0]const u8) void {
        lv_label_set_text(self, text);
    }

    /// sets or clears an object flag.
    pub fn setFlag(self: *LvObj, onoff: enum { on, off }, v: ObjFlag) void {
        switch (onoff) {
            .on => lv_obj_add_flag(self, @enumToInt(v)),
            .off => lv_obj_clear_flag(self, @enumToInt(v)),
        }
    }

    /// reports whether the object has v flag set.
    pub fn hasFlag(self: *LvObj, v: ObjFlag) bool {
        return lv_obj_has_flag(self, @enumToInt(v));
    }

    /// returns a user data pointer associated with the object.
    pub fn userdata(self: *LvObj) ?*anyopaque {
        return nm_obj_userdata(self);
    }

    /// associates an arbitrary data with the object.
    /// the pointer can be accessed using LvObj.userdata fn.
    pub fn setUserdata(self: *LvObj, data: ?*const anyopaque) void {
        nm_obj_set_userdata(self, data);
    }

    /// sets object horizontal length.
    pub fn setWidth(self: *LvObj, val: Coord) void {
        lv_obj_set_width(self, val);
    }

    /// sets object vertical length.
    pub fn setHeight(self: *LvObj, val: Coord) void {
        lv_obj_set_height(self, val);
    }

    /// sets object height to its child contents.
    pub fn setHeightToContent(self: *LvObj) void {
        lv_obj_set_height(self, sizeContent);
    }

    /// sets both width and height to 100%.
    pub fn resizeToMax(self: *LvObj) void {
        lv_obj_set_size(self, sizePercent(100), sizePercent(100));
    }

    /// selects which side to pad in setPad func.
    pub const PadSelector = enum { all, left, right, top, bottom, row, column };

    /// adds a padding style to the object.
    pub fn setPad(self: *LvObj, v: Coord, p: PadSelector, sel: StyleSelector) void {
        switch (p) {
            .all => {
                const vsel = sel.value();
                lv_obj_set_style_pad_left(self, v, vsel);
                lv_obj_set_style_pad_right(self, v, vsel);
                lv_obj_set_style_pad_top(self, v, vsel);
                lv_obj_set_style_pad_bottom(self, v, vsel);
            },
            .left => lv_obj_set_style_pad_left(self, v, sel.value()),
            .right => lv_obj_set_style_pad_right(self, v, sel.value()),
            .top => lv_obj_set_style_pad_top(self, v, sel.value()),
            .bottom => lv_obj_set_style_pad_bottom(self, v, sel.value()),
            .row => lv_obj_set_style_pad_row(self, v, sel.value()),
            .column => lv_obj_set_style_pad_column(self, v, sel.value()),
        }
    }

    /// same as setPad .column but using a default constant to make flex layouts consistent.
    pub fn padColumnDefault(self: *LvObj) void {
        self.setPad(20, .column, .{});
    }

    /// aligns object to the center of its parent.
    pub fn center(self: *LvObj) void {
        self.posAlign(.center, 0, 0);
    }

    /// aligns object position. the offset is relative to the specified alignment a.
    pub fn posAlign(self: *LvObj, a: PosAlign, xoffset: Coord, yoffset: Coord) void {
        lv_obj_align(self, @enumToInt(a), xoffset, yoffset);
    }

    /// sets flex layout flow on the object.
    pub fn flexFlow(self: *LvObj, ff: FlexFlow) void {
        lv_obj_set_flex_flow(self, @enumToInt(ff));
    }

    /// sets flex layout growth property; same meaning as in CSS flex.
    pub fn flexGrow(self: *LvObj, val: u8) void {
        lv_obj_set_flex_grow(self, val);
    }

    /// sets flex layout alignments.
    pub fn flexAlign(self: *LvObj, main: FlexAlign, cross: FlexAlignCross, track: FlexAlign) void {
        lv_obj_set_flex_align(self, @enumToInt(main), @enumToInt(cross), @enumToInt(track));
    }

    /// adds a style to the object or one of its parts/states based on the selector.
    pub fn addStyle(self: *LvObj, v: *LvStyle, sel: StyleSelector) void {
        lv_obj_add_style(self, v, sel.value());
    }

    /// removes all styles from the object.
    pub fn removeAllStyle(self: *LvObj) void {
        const sel = StyleSelector{ .part = .any, .state = .any };
        lv_obj_remove_style(self, null, sel.value());
    }

    /// removes only the background styles from the object.
    pub fn removeBackgroundStyle(self: *LvObj) void {
        const sel = StyleSelector{ .part = .main, .state = .any };
        lv_obj_remove_style(self, null, sel.value());
    }

    /// sets a desired background color to objects parts/states.
    pub fn setBackgroundColor(self: *LvObj, v: Color, sel: StyleSelector) void {
        lv_obj_set_style_bg_color(self, v, sel.value());
    }

    /// sets the color of a text, typically a label object.
    pub fn setTextColor(self: *LvObj, v: Color, sel: StyleSelector) void {
        lv_obj_set_style_text_color(self, v, sel.value());
    }
};

pub fn createObject(parent: *LvObj) !*LvObj {
    return lv_obj_create(parent) orelse error.OutOfMemory;
}

pub fn createFlexObject(parent: *LvObj, flow: FlexFlow) !*LvObj {
    var o = try createObject(parent);
    o.flexFlow(flow);
    return o;
}

pub fn createTopObject() !*LvObj {
    const toplayer = lv_disp_get_layer_top(null);
    return lv_obj_create(toplayer) orelse error.OutOfMemory;
}

/// feature-flags controlling object's behavior.
/// OR'ed values are possible.
pub const ObjFlag = enum(c.lv_obj_flag_t) {
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

/// flex layout alignments.
pub const FlexAlign = enum(c.lv_flex_align_t) {
    start = c.LV_FLEX_ALIGN_START,
    end = c.LV_FLEX_ALIGN_END,
    center = c.LV_FLEX_ALIGN_CENTER,
    space_evenly = c.LV_FLEX_ALIGN_SPACE_EVENLY,
    space_around = c.LV_FLEX_ALIGN_SPACE_AROUND,
    space_between = c.LV_FLEX_ALIGN_SPACE_BETWEEN,
};

/// flex layout cross-axis alignments.
pub const FlexAlignCross = enum(c.lv_flex_align_t) {
    start = c.LV_FLEX_ALIGN_START,
    end = c.LV_FLEX_ALIGN_END,
    center = c.LV_FLEX_ALIGN_CENTER,
};

/// flex layout flow variations.
pub const FlexFlow = enum(c.lv_flex_flow_t) {
    row = c.LV_FLEX_FLOW_ROW,
    column = c.LV_FLEX_FLOW_COLUMN,
    row_wrap = c.LV_FLEX_FLOW_ROW_WRAP,
    row_reverse = c.LV_FLEX_FLOW_ROW_REVERSE,
    row_wrap_reverse = c.LV_FLEX_FLOW_ROW_WRAP_REVERSE,
    column_wrap = c.LV_FLEX_FLOW_COLUMN_WRAP,
    column_reverse = c.LV_FLEX_FLOW_COLUMN_REVERSE,
    column_wrap_reverse = c.LV_FLEX_FLOW_COLUMN_WRAP_REVERSE,
};

/// if parent is null, uses lv_scr_act.
pub fn createWindow(parent: ?*LvObj, header_height: i16, title: [*:0]const u8) !Window {
    const pobj = parent orelse try activeScreen();
    const winobj = lv_win_create(pobj, header_height) orelse return error.OutOfMemory;
    if (lv_win_add_title(winobj, title) == null) {
        return error.OutOfMemory;
    }
    return .{ .winobj = winobj };
}

pub const Window = struct {
    winobj: *LvObj,

    pub fn content(self: Window) *LvObj {
        return lv_win_get_content(self.winobj);
    }
};

pub const CreateLabelOpt = struct {
    // LVGL defaults to .wrap
    long_mode: ?enum(c.lv_label_long_mode_t) {
        wrap = c.LV_LABEL_LONG_WRAP, // keep the object width, wrap the too long lines and expand the object height
        dot = c.LV_LABEL_LONG_DOT, // keep the size and write dots at the end if the text is too long
        scroll = c.LV_LABEL_LONG_SCROLL, // keep the size and roll the text back and forth
        scroll_circular = c.LV_LABEL_LONG_SCROLL_CIRCULAR, // keep the size and roll the text circularly
        clip = c.LV_LABEL_LONG_CLIP, // keep the size and clip the text out of it
    } = null,
    pos: ?PosAlign = null,
};

/// creates a new label object.
/// the text is heap-duplicated for the lifetime of the object and free'ed automatically.
pub fn createLabel(parent: *LvObj, text: [*:0]const u8, opt: CreateLabelOpt) !*LvObj {
    var lb = lv_label_create(parent) orelse return error.OutOfMemory;
    //lv_label_set_text_static(lb, text); // static doesn't work with .dot
    lv_label_set_text(lb, text);
    lv_label_set_recolor(lb, true);
    //lv_obj_set_height(lb, sizeContent); // default
    if (opt.long_mode) |m| {
        lv_label_set_long_mode(lb, @enumToInt(m));
    }
    if (opt.pos) |p| {
        lb.posAlign(p, 0, 0);
    }
    return lb;
}

/// formats label text using std.fmt.format and the provided buffer.
/// a label object is then created with the resulting text using createLabel.
/// the text is heap-dup'ed so no need to retain buf. see createLabel.
pub fn createLabelFmt(parent: *LvObj, buf: []u8, comptime format: []const u8, args: anytype, opt: CreateLabelOpt) !*LvObj {
    const text = try std.fmt.bufPrintZ(buf, format, args);
    return createLabel(parent, text, opt);
}

pub fn createButton(parent: *LvObj, label: [*:0]const u8) !*LvObj {
    const btn = lv_btn_create(parent) orelse return error.OutOfMemory;
    _ = try createLabel(btn, label, .{ .long_mode = .dot, .pos = .center });
    return btn;
}

/// creates a spinner object with hardcoded dimensions and animation speed
/// used througout the GUI.
pub fn createSpinner(parent: *LvObj) !*LvObj {
    const spin = lv_spinner_create(parent, 1000, 60) orelse return error.OutOfMemory;
    lv_obj_set_size(spin, 20, 20);
    const ind: StyleSelector = .{ .part = .indicator };
    lv_obj_set_style_arc_width(spin, 4, ind.value());
    return spin;
}

// ==========================================================================
// imports from nakamochi custom C code that extends LVGL
// ==========================================================================

/// returns a red button style.
pub extern fn nm_style_btn_red() *LvStyle; // TODO: make it private

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
extern fn lv_timer_create(callback: TimerCallback, period_ms: u32, userdata: ?*anyopaque) ?*LvTimer;
extern fn lv_timer_del(timer: *LvTimer) void;
extern fn lv_timer_set_repeat_count(timer: *LvTimer, n: i32) void;

// events --------------------------------------------------------------------

extern fn lv_event_get_code(e: *LvEvent) EventCode;
extern fn lv_event_get_current_target(e: *LvEvent) *LvObj;
extern fn lv_event_get_target(e: *LvEvent) *LvObj;
extern fn lv_event_get_user_data(e: *LvEvent) ?*anyopaque;
extern fn lv_obj_add_event_cb(obj: *LvObj, cb: LvEventCallback, filter: EventCode, userdata: ?*anyopaque) *LvEventDescr;

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

extern fn lv_obj_add_flag(obj: *LvObj, v: c.lv_obj_flag_t) void;
extern fn lv_obj_clear_flag(obj: *LvObj, v: c.lv_obj_flag_t) void;
extern fn lv_obj_has_flag(obj: *LvObj, v: c.lv_obj_flag_t) bool;

extern fn lv_obj_align(obj: *LvObj, a: c.lv_align_t, x: c.lv_coord_t, y: c.lv_coord_t) void;
extern fn lv_obj_set_height(obj: *LvObj, h: c.lv_coord_t) void;
extern fn lv_obj_set_width(obj: *LvObj, w: c.lv_coord_t) void;
extern fn lv_obj_set_size(obj: *LvObj, w: c.lv_coord_t, h: c.lv_coord_t) void;

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

extern fn lv_spinner_create(parent: *LvObj, speed_ms: u32, arc_deg: u32) ?*LvObj;

extern fn lv_win_create(parent: *LvObj, header_height: c.lv_coord_t) ?*LvObj;
extern fn lv_win_add_title(win: *LvObj, title: [*:0]const u8) ?*LvObj;
extern fn lv_win_get_content(win: *LvObj) *LvObj;
