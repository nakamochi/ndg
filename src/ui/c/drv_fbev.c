/**
 * framebuffer display + evdev touchpad drivers init
 */

#include "lv_drivers/display/fbdev.h"
#include "lv_drivers/indev/evdev.h"
#include "lvgl/lvgl.h"

#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#if USE_BSD_EVDEV
#include <dev/evdev/input.h>
#else
#include <linux/input.h>
#endif

#define DISP_BUF_SIZE (NM_DISP_HOR * NM_DISP_VER / 10)

/* returns NULL on error */
lv_disp_t *nm_disp_init(void)
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
    return lv_disp_drv_register(&disp_drv);
}

int nm_indev_init(void)
{
    /* lv driver correctly closes and opens evdev again if already inited */
    evdev_init();

    /* keypad input devices default group;
     * future-proof: don't have any atm */
    lv_group_t *g = lv_group_create();
    if (g == NULL) {
        return -1;
    }
    lv_group_set_default(g);

    static lv_indev_drv_t touchpad_drv;
    lv_indev_drv_init(&touchpad_drv);
    touchpad_drv.type = LV_INDEV_TYPE_POINTER;
    touchpad_drv.read_cb = evdev_read;
    lv_indev_t *touchpad = lv_indev_drv_register(&touchpad_drv);
    if (touchpad == NULL) {
        return -1;
    }

    return 0;
}

int nm_open_evdev_nonblock(void)
{
    // see lib/lv_drivers/indev/evdev.c
#if USE_BSD_EVDEV
    int fd = open(EVDEV_NAME, O_RDWR | O_NOCTTY);
#else
    int fd = open(EVDEV_NAME, O_RDWR | O_NOCTTY | O_NDELAY);
#endif
    if (fd == -1) {
        return -1;
    }
#if USE_BSD_EVDEV
    fcntl(fd, F_SETFL, O_NONBLOCK);
#else
    fcntl(fd, F_SETFL, O_ASYNC | O_NONBLOCK);
#endif
    return fd;
}

void nm_close_evdev(int fd)
{
    if (fd != -1) {
        close(fd);
    }
}

bool nm_consume_input_events(int fd)
{
    if (fd == -1) {
        return false;
    }
    struct input_event in;
    int count = 0;
    while (read(fd, &in, sizeof(struct input_event)) > 0) {
        count++;
    }
    return count > 0;
}
