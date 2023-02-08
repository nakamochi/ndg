/**
 * framebuffer display + evdev touchpad drivers init
 */

#include "lv_drivers/display/fbdev.h"
#include "lv_drivers/indev/evdev.h"
#include "lvgl/lvgl.h"

#define DISP_BUF_SIZE (NM_DISP_HOR * NM_DISP_VER / 10)

lv_disp_t *drv_init(void)
{
    fbdev_init();

    static lv_disp_draw_buf_t buf;
    static lv_color_t cb[DISP_BUF_SIZE];
    lv_disp_draw_buf_init(&buf, cb, NULL, DISP_BUF_SIZE);
    uint32_t hor, vert;
    fbdev_get_sizes(&hor, &vert, NULL);
    if (hor != NM_DISP_HOR || vert != NM_DISP_VER) {
        LV_LOG_WARN("framebuffer display mismatch; expected %dx%d", NM_DISP_HOR, NM_DISP_VER);
    }

    static lv_disp_drv_t disp_drv;
    lv_disp_drv_init(&disp_drv);
    disp_drv.draw_buf = &buf;
    disp_drv.hor_res = NM_DISP_HOR;
    disp_drv.ver_res = NM_DISP_VER;
    disp_drv.antialiasing = 1;
    disp_drv.flush_cb = fbdev_flush;
    lv_disp_t *disp = lv_disp_drv_register(&disp_drv);
    if (disp == NULL) {
        return NULL;
    }

    /* keypad input devices default group;
     * future-proof: don't have any atm */
    lv_group_t *g = lv_group_create();
    if (g == NULL) {
        return NULL;
    }
    lv_group_set_default(g);

    evdev_init();
    static lv_indev_drv_t touchpad_drv;
    lv_indev_drv_init(&touchpad_drv);
    touchpad_drv.type = LV_INDEV_TYPE_POINTER;
    touchpad_drv.read_cb = evdev_read;
    lv_indev_t *touchpad = lv_indev_drv_register(&touchpad_drv);
    if (touchpad == NULL) {
        /* TODO: or continue without the touchpad? */
        return NULL;
    }

    return disp;
}
