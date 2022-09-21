/**
 * SDL2 drivers init for display, keyboard and mouse
 */

#include "lvgl/lvgl.h"
#include "lvgl/src/misc/lv_log.h"
#include "lv_drivers/sdl/sdl.h"

#define SDL_MAIN_HANDLED /*To fix SDL's "undefined reference to WinMain" issue*/
#include SDL_INCLUDE_PATH

lv_disp_t* drv_init(void)
{
  sdl_init();
  SDL_DisplayMode dm;
  int dm_err = SDL_GetDesktopDisplayMode(0, &dm);
  if (dm_err != 0) {
      LV_LOG_WARN("SDL_GetDesktopDisplayMode: %i", dm_err);
  } else {
      unsigned char bpp = SDL_BITSPERPIXEL(dm.format);
      LV_LOG_INFO("%ix%i %dbpp %s", dm.w, dm.h, bpp, SDL_GetPixelFormatName(dm.format));
      if (dm.w != NM_DISP_HOR || dm.h != NM_DISP_VER || bpp != LV_COLOR_DEPTH) {
          LV_LOG_WARN("SDL display mismatch; expected %dx%d %dbpp", NM_DISP_HOR, NM_DISP_VER, LV_COLOR_DEPTH);
      }
  }

  static lv_disp_draw_buf_t buf;
  static lv_color_t cb1[NM_DISP_HOR * 100];
  static lv_color_t cb2[NM_DISP_HOR * 100];
  lv_disp_draw_buf_init(&buf, cb1, cb2, NM_DISP_HOR * 100);

  static lv_disp_drv_t disp_drv;
  lv_disp_drv_init(&disp_drv);
  disp_drv.draw_buf = &buf;
  disp_drv.flush_cb = sdl_display_flush;
  disp_drv.hor_res = NM_DISP_HOR;
  disp_drv.ver_res = NM_DISP_VER;
  disp_drv.antialiasing = 1;
  lv_disp_t* disp = lv_disp_drv_register(&disp_drv);
  if (disp == NULL) {
      return NULL;
  }

  static lv_indev_drv_t mouse_drv;
  lv_indev_drv_init(&mouse_drv);
  mouse_drv.type = LV_INDEV_TYPE_POINTER;
  mouse_drv.read_cb = sdl_mouse_read;
  lv_indev_t* mouse = lv_indev_drv_register(&mouse_drv);
  if (mouse == NULL) {
      LV_LOG_WARN("lv_indev_drv_register(&mouse_drv) returned NULL");
  }

  /* keypad input devices default group */
  lv_group_t * g = lv_group_create();
  if (g == NULL) {
      LV_LOG_WARN("lv_group_create returned NULL; won't set default group");
  } else {
      lv_group_set_default(g);
  }

  static lv_indev_drv_t keyboard_drv;
  lv_indev_drv_init(&keyboard_drv);
  keyboard_drv.type = LV_INDEV_TYPE_KEYPAD;
  keyboard_drv.read_cb = sdl_keyboard_read;
  lv_indev_t *kb = lv_indev_drv_register(&keyboard_drv);
  if (kb == NULL) {
      LV_LOG_WARN("lv_indev_drv_register(&keyboard_drv) returned NULL");
  } else if (g) {
      lv_indev_set_group(kb, g);
  }

  return disp;
}
