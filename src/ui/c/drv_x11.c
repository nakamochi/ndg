/**
 * X11 drivers init for display, keyboard and mouse
 */

#include "lv_drivers/x11/x11.h"
#include "lvgl/lvgl.h"
#include "lvgl/src/misc/lv_log.h"

lv_disp_t *nm_disp_init(void)
{
    lv_x11_init("nakamochi gui", NM_DISP_HOR, NM_DISP_VER);

    static lv_disp_draw_buf_t buf;
    static lv_color_t cb1[NM_DISP_HOR * 100];
    static lv_color_t cb2[NM_DISP_HOR * 100];
    lv_disp_draw_buf_init(&buf, cb1, cb2, NM_DISP_HOR * 100);

    static lv_disp_drv_t disp_drv;
    lv_disp_drv_init(&disp_drv);
    disp_drv.draw_buf = &buf;
    disp_drv.flush_cb = lv_x11_flush;
    disp_drv.hor_res = NM_DISP_HOR;
    disp_drv.ver_res = NM_DISP_VER;
    disp_drv.antialiasing = 1;
    return lv_disp_drv_register(&disp_drv);
}

int nm_indev_init(void)
{
    static lv_indev_drv_t mouse_drv;
    lv_indev_drv_init(&mouse_drv);
    mouse_drv.type = LV_INDEV_TYPE_POINTER;
    mouse_drv.read_cb = lv_x11_get_pointer;
    lv_indev_t *mouse = lv_indev_drv_register(&mouse_drv);
    if (mouse == NULL) {
        LV_LOG_WARN("lv_indev_drv_register(&mouse_drv) returned NULL");
        return -1;
    }
    /* set a cursor for the mouse */
    LV_IMG_DECLARE(mouse_cursor_icon);
    lv_obj_t *cursor_obj = lv_img_create(lv_scr_act());
    lv_img_set_src(cursor_obj, &mouse_cursor_icon);
    lv_indev_set_cursor(mouse, cursor_obj);

    static lv_indev_drv_t keyboard_drv;
    lv_indev_drv_init(&keyboard_drv);
    keyboard_drv.type = LV_INDEV_TYPE_KEYPAD;
    keyboard_drv.read_cb = lv_x11_get_keyboard;
    lv_indev_t *kb = lv_indev_drv_register(&keyboard_drv);
    if (kb == NULL) {
        LV_LOG_WARN("lv_indev_drv_register(&keyboard_drv) returned NULL");
        return -1;
    }

    /* keypad input devices default group */
    lv_group_t *g = lv_group_create();
    if (g == NULL) {
        LV_LOG_WARN("lv_group_create returned NULL; won't set default group");
        return -1;
    }
    lv_group_set_default(g);
    lv_indev_set_group(kb, g);

    return 0;
}
