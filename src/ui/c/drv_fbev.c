/**
 * framebuffer display + evdev touchpad drivers init
 */

#include "lv_drivers/display/fbdev.h"
#include "lv_drivers/indev/evdev.h"
#include "lvgl/lvgl.h"

#include <fcntl.h>
#include <linux/fb.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#if USE_BSD_EVDEV
#include <dev/evdev/input.h>
#else
#include <linux/input.h>
#endif

#define DISP_BUF_SIZE (NM_DISP_HOR * NM_DISP_VER / 10)

static int fb_fd = -1;
static uint8_t *fb_mem = NULL;
static size_t fb_mem_len = 0;
static struct fb_fix_screeninfo fb_fix;
static struct fb_var_screeninfo fb_var;

static bool nm_fb_open(void)
{
    if (fb_fd != -1) {
        return true;
    }

    fb_fd = open(FBDEV_PATH, O_RDWR);
    if (fb_fd == -1) {
        LV_LOG_WARN("open(%s) failed", FBDEV_PATH);
        return false;
    }
    if (ioctl(fb_fd, FBIOGET_FSCREENINFO, &fb_fix) == -1) {
        LV_LOG_WARN("FBIOGET_FSCREENINFO failed");
        close(fb_fd);
        fb_fd = -1;
        return false;
    }
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &fb_var) == -1) {
        LV_LOG_WARN("FBIOGET_VSCREENINFO failed");
        close(fb_fd);
        fb_fd = -1;
        return false;
    }

    fb_mem_len = fb_fix.smem_len;
    fb_mem = mmap(NULL, fb_mem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fb_mem == MAP_FAILED) {
        LV_LOG_WARN("mmap framebuffer failed");
        fb_mem = NULL;
        close(fb_fd);
        fb_fd = -1;
        return false;
    }

    LV_LOG_INFO("fbdev: %ux%u virt=%ux%u bpp=%u line=%u r=%u/%u g=%u/%u b=%u/%u a=%u/%u",
        fb_var.xres,
        fb_var.yres,
        fb_var.xres_virtual,
        fb_var.yres_virtual,
        fb_var.bits_per_pixel,
        fb_fix.line_length,
        fb_var.red.offset,
        fb_var.red.length,
        fb_var.green.offset,
        fb_var.green.length,
        fb_var.blue.offset,
        fb_var.blue.length,
        fb_var.transp.offset,
        fb_var.transp.length);
    return true;
}

#if LV_COLOR_DEPTH == 16 && LV_COLOR_16_SWAP
static inline uint16_t nm_bswap16(uint16_t v)
{
    return (uint16_t)((v << 8) | (v >> 8));
}
#endif

static inline uint32_t nm_mask_u32(uint32_t len)
{
    return (len >= 32u) ? UINT32_MAX : ((1u << len) - 1u);
}

#if LV_COLOR_DEPTH == 32
static inline uint32_t nm_lv32_to_fb32(uint32_t p)
{
    uint8_t r = (uint8_t)((p >> 16) & 0xff);
    uint8_t g = (uint8_t)((p >> 8) & 0xff);
    uint8_t b = (uint8_t)(p & 0xff);

    uint32_t out = 0;
    out |= ((uint32_t)r) << fb_var.red.offset;
    out |= ((uint32_t)g) << fb_var.green.offset;
    out |= ((uint32_t)b) << fb_var.blue.offset;
    if (fb_var.transp.length) {
        uint32_t a = nm_mask_u32(fb_var.transp.length);
        out |= a << fb_var.transp.offset;
    }
    return out;
}
#endif

#if LV_COLOR_DEPTH == 16
static inline uint32_t nm_rgb565_to_fb32(uint16_t p)
{
#if LV_COLOR_16_SWAP
    p = nm_bswap16(p);
#endif
    uint8_t r5 = (p >> 11) & 0x1f;
    uint8_t g6 = (p >> 5) & 0x3f;
    uint8_t b5 = p & 0x1f;

    uint8_t r8 = (uint8_t)((r5 << 3) | (r5 >> 2));
    uint8_t g8 = (uint8_t)((g6 << 2) | (g6 >> 4));
    uint8_t b8 = (uint8_t)((b5 << 3) | (b5 >> 2));

    uint32_t out = 0;
    out |= ((uint32_t)r8) << fb_var.red.offset;
    out |= ((uint32_t)g8) << fb_var.green.offset;
    out |= ((uint32_t)b8) << fb_var.blue.offset;
    if (fb_var.transp.length) {
        uint32_t a = nm_mask_u32(fb_var.transp.length);
        out |= a << fb_var.transp.offset;
    }
    return out;
}
#endif

static void nm_fbdev_flush(lv_disp_drv_t *drv, const lv_area_t *area, lv_color_t *color_p)
{
    if (!nm_fb_open() || fb_mem == NULL) {
        lv_disp_flush_ready(drv);
        return;
    }

    int32_t x1 = area->x1 < 0 ? 0 : area->x1;
    int32_t y1 = area->y1 < 0 ? 0 : area->y1;
    int32_t x2 = area->x2 >= (int32_t)fb_var.xres ? (int32_t)fb_var.xres - 1 : area->x2;
    int32_t y2 = area->y2 >= (int32_t)fb_var.yres ? (int32_t)fb_var.yres - 1 : area->y2;

    if (x1 > x2 || y1 > y2) {
        lv_disp_flush_ready(drv);
        return;
    }

    const int32_t w = x2 - x1 + 1;
    const int32_t src_w = area->x2 - area->x1 + 1;
    const int32_t src_x_off = x1 - area->x1;
    const int32_t src_y_off = y1 - area->y1;

#if LV_COLOR_DEPTH == 16
    const uint16_t *src = (const uint16_t *)color_p;

    if (fb_var.bits_per_pixel == 16 && fb_var.red.length == 5 && fb_var.red.offset == 11 &&
        fb_var.green.length == 6 && fb_var.green.offset == 5 && fb_var.blue.length == 5 &&
        fb_var.blue.offset == 0) {

        for (int32_t y = y1; y <= y2; y++) {
            uint32_t fb_y = (uint32_t)y + fb_var.yoffset;
            uint32_t fb_x = (uint32_t)x1 + fb_var.xoffset;
            uint8_t *dst_row = fb_mem + (size_t)fb_y * fb_fix.line_length + (size_t)fb_x * 2u;
            const uint16_t *src_row =
                src + (size_t)(src_y_off + (y - y1)) * (size_t)src_w + (size_t)src_x_off;
#if LV_COLOR_16_SWAP
            uint16_t *dst16 = (uint16_t *)dst_row;
            for (int32_t x = 0; x < w; x++) {
                dst16[x] = nm_bswap16(src_row[x]);
            }
#else
            memcpy(dst_row, src_row, (size_t)w * sizeof(uint16_t));
#endif
        }
    } else if (fb_var.bits_per_pixel == 32) {
        for (int32_t y = y1; y <= y2; y++) {
            uint32_t fb_y = (uint32_t)y + fb_var.yoffset;
            uint32_t fb_x = (uint32_t)x1 + fb_var.xoffset;
            uint32_t *dst32 =
                (uint32_t *)(fb_mem + (size_t)fb_y * fb_fix.line_length + (size_t)fb_x * 4u);
            const uint16_t *src_row =
                src + (size_t)(src_y_off + (y - y1)) * (size_t)src_w + (size_t)src_x_off;
            for (int32_t x = 0; x < w; x++) {
                dst32[x] = nm_rgb565_to_fb32(src_row[x]);
            }
        }
    } else {
        LV_LOG_WARN("unsupported fb format: src=16 dst=%ubpp", fb_var.bits_per_pixel);
    }

#elif LV_COLOR_DEPTH == 32
    const uint32_t *src = (const uint32_t *)color_p;

    if (fb_var.bits_per_pixel == 32 && fb_var.red.length == 8 && fb_var.green.length == 8 &&
        fb_var.blue.length == 8) {

        for (int32_t y = y1; y <= y2; y++) {
            uint32_t fb_y = (uint32_t)y + fb_var.yoffset;
            uint32_t fb_x = (uint32_t)x1 + fb_var.xoffset;
            uint32_t *dst32 =
                (uint32_t *)(fb_mem + (size_t)fb_y * fb_fix.line_length + (size_t)fb_x * 4u);
            const uint32_t *src_row =
                src + (size_t)(src_y_off + (y - y1)) * (size_t)src_w + (size_t)src_x_off;
            for (int32_t x = 0; x < w; x++) {
                dst32[x] = nm_lv32_to_fb32(src_row[x]);
            }
        }
    } else if (fb_var.bits_per_pixel == 16 && fb_var.red.length == 5 && fb_var.red.offset == 11 &&
               fb_var.green.length == 6 && fb_var.green.offset == 5 && fb_var.blue.length == 5 &&
               fb_var.blue.offset == 0) {

        for (int32_t y = y1; y <= y2; y++) {
            uint32_t fb_y = (uint32_t)y + fb_var.yoffset;
            uint32_t fb_x = (uint32_t)x1 + fb_var.xoffset;
            uint16_t *dst16 =
                (uint16_t *)(fb_mem + (size_t)fb_y * fb_fix.line_length + (size_t)fb_x * 2u);
            const uint32_t *src_row =
                src + (size_t)(src_y_off + (y - y1)) * (size_t)src_w + (size_t)src_x_off;
            for (int32_t x = 0; x < w; x++) {
                uint32_t p = src_row[x];
                uint8_t r = (uint8_t)((p >> 16) & 0xff);
                uint8_t g = (uint8_t)((p >> 8) & 0xff);
                uint8_t b = (uint8_t)(p & 0xff);
                uint16_t out = (uint16_t)(((r >> 3) & 0x1f) << 11) |
                               (uint16_t)(((g >> 2) & 0x3f) << 5) |
                               (uint16_t)(((b >> 3) & 0x1f) << 0);
                dst16[x] = out;
            }
        }
    } else {
        LV_LOG_WARN("unsupported fb format: src=32 dst=%ubpp", fb_var.bits_per_pixel);
    }
#else
#error Unsupported LV_COLOR_DEPTH
#endif

    lv_disp_flush_ready(drv);
}

/* returns NULL on error */
lv_disp_t *nm_disp_init(void)
{
    if (!nm_fb_open()) {
        return NULL;
    }

    static lv_disp_draw_buf_t buf;
    static lv_color_t cb[DISP_BUF_SIZE];
    lv_disp_draw_buf_init(&buf, cb, NULL, DISP_BUF_SIZE);
    if (fb_var.xres != NM_DISP_HOR || fb_var.yres != NM_DISP_VER) {
        LV_LOG_WARN("framebuffer display mismatch; expected %dx%d", NM_DISP_HOR, NM_DISP_VER);
    }

    static lv_disp_drv_t disp_drv;
    lv_disp_drv_init(&disp_drv);
    disp_drv.draw_buf = &buf;
    disp_drv.hor_res = NM_DISP_HOR;
    disp_drv.ver_res = NM_DISP_VER;
    disp_drv.antialiasing = 1;
    disp_drv.flush_cb = nm_fbdev_flush;
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
