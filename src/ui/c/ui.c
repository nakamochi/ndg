#define _DEFAULT_SOURCE /* needed for usleep() */

#include "lvgl/lvgl.h"

#include "ui.h"

#include <stdlib.h>
#include <unistd.h>

lv_disp_t* drv_init(void);

static lv_style_t style_title;
static lv_style_t style_text_muted;
static lv_style_t style_btn_red;
static const lv_font_t* font_large;
static lv_obj_t* virt_keyboard;
static lv_obj_t* tabview; /* main tabs content parent; lv_tabview_create */

static void textarea_event_cb(lv_event_t* e)
{
    lv_obj_t* textarea = lv_event_get_target(e);
    lv_event_code_t code = lv_event_get_code(e);
    if (code == LV_EVENT_FOCUSED) {
        if (lv_indev_get_type(lv_indev_get_act()) != LV_INDEV_TYPE_KEYPAD) {
            lv_keyboard_set_textarea(virt_keyboard, textarea);
            lv_obj_set_style_max_height(virt_keyboard, NM_DISP_HOR * 2 / 3, 0);
            lv_obj_update_layout(tabview); /* make sure sizes are recalculated */
            lv_obj_set_height(tabview, NM_DISP_VER - lv_obj_get_height(virt_keyboard));
            lv_obj_clear_flag(virt_keyboard, LV_OBJ_FLAG_HIDDEN);
            lv_obj_scroll_to_view_recursive(textarea, LV_ANIM_OFF);
        }
    } else if (code == LV_EVENT_DEFOCUSED) {
        lv_keyboard_set_textarea(virt_keyboard, NULL);
        lv_obj_set_height(tabview, NM_DISP_VER);
        lv_obj_add_flag(virt_keyboard, LV_OBJ_FLAG_HIDDEN);
        lv_indev_reset(NULL, textarea);
    } else if (code == LV_EVENT_READY || code == LV_EVENT_CANCEL) {
        lv_obj_set_height(tabview, NM_DISP_VER);
        lv_obj_add_flag(virt_keyboard, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_state(textarea, LV_STATE_FOCUSED);
        lv_indev_reset(NULL, textarea); /* forget the last clicked object to make it focusable again */
    }
}

static void create_bitcoin_panel(lv_obj_t* parent)
{
  lv_obj_t* label = lv_label_create(parent);
  lv_label_set_text_static(label, "bitcoin tab isn't designed yet\nfollow https://nakamochi.io");
  lv_obj_center(label);
}

static void create_lnd_panel(lv_obj_t* parent)
{
  lv_obj_t* label = lv_label_create(parent);
  lv_label_set_text_static(label, "lightning tab isn't designed yet\nfollow https://nakamochi.io");
  lv_obj_center(label);
}

static struct {
    lv_obj_t* wifi_spinner_obj;       /* lv_spinner_create */
    lv_obj_t* wifi_status_obj;        /* lv_label_create */
    lv_obj_t* wifi_connect_btn_obj;   /* lv_btn_create */
    lv_obj_t* wifi_ssid_list_obj;     /* lv_dropdown_create */
    lv_obj_t* wifi_pwd_obj;           /* lv_textarea_create */
    lv_obj_t* power_halt_btn_obj;     /* lv_btn_create */
} settings;

/**
 * update the UI with network connection info, placing text into wifi_status_obj as is.
 * wifi_list is optional; items must be delimited by '\n' if non-null.
 * args are alloc-copied and owned by lvgl.
 */
extern void ui_update_network_status(const char *text, const char *wifi_list)
{
    if (wifi_list) {
        lv_dropdown_set_options(settings.wifi_ssid_list_obj, wifi_list);
    }
    lv_obj_clear_state(settings.wifi_connect_btn_obj, LV_STATE_DISABLED);
    lv_obj_add_flag(settings.wifi_spinner_obj, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(settings.wifi_status_obj, text);
}

static void wifi_connect_btn_callback(lv_event_t* e)
{
    (void)e; /* unused */
    lv_obj_add_state(settings.wifi_connect_btn_obj, LV_STATE_DISABLED);
    lv_obj_clear_flag(settings.wifi_spinner_obj, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(settings.wifi_status_obj, "connecting ...");

    char buf[100];
    lv_dropdown_get_selected_str(settings.wifi_ssid_list_obj, buf, sizeof(buf));
    nm_wifi_start_connect(buf, lv_textarea_get_text(settings.wifi_pwd_obj));
}

static void power_halt_btn_callback(lv_event_t *e)
{
    if (e->user_data) { /* ptr to msgbox */
        lv_obj_t *msgbox = e->user_data;
        /* first button is "proceed", do shutdown */
        if (lv_msgbox_get_active_btn(msgbox) == 0) {
            /* shutdown confirmed */
            nm_sys_shutdown();
        }
        /* shutdown aborted or passthrough from confirmed shutdown.
         * in the latter case, ui is still running for a brief moment,
         * until ngui terminates. */
        lv_msgbox_close(msgbox);
        return;
    }

    /* first button must always be a "proceed", do shutdown;
     * text is irrelevant */
    static const char *btns[] = {"PROCEED", "ABORT", NULL};
    lv_obj_t *msgbox = lv_msgbox_create(
        NULL                 /* modal */,
        "SHUTDOWN",          /* title */
        "are you sure?",     /* text */
        btns,
        false                /* close btn */);
    lv_obj_center(msgbox);
    lv_obj_add_event_cb(msgbox, power_halt_btn_callback, LV_EVENT_VALUE_CHANGED, msgbox);
    return;
}

static void create_settings_panel(lv_obj_t* parent)
{
  /********************
   * wifi panel
   ********************/
  lv_obj_t* wifi_panel = lv_obj_create(parent);
  lv_obj_set_height(wifi_panel, LV_SIZE_CONTENT);
  lv_obj_t * wifi_panel_title = lv_label_create(wifi_panel);
  lv_label_set_text_static(wifi_panel_title, LV_SYMBOL_WIFI " WIFI");
  lv_obj_add_style(wifi_panel_title, &style_title, 0);

  lv_obj_t* wifi_spinner = lv_spinner_create(wifi_panel, 1000 /* speed */, 60 /* arc in deg */);
  settings.wifi_spinner_obj = wifi_spinner;
  lv_obj_add_flag(wifi_spinner, LV_OBJ_FLAG_HIDDEN);
  lv_obj_set_size(wifi_spinner, 20, 20);
  lv_obj_set_style_arc_width(wifi_spinner, 4, LV_PART_INDICATOR);

  lv_obj_t* wifi_status = lv_label_create(wifi_panel);
  settings.wifi_status_obj = wifi_status;
  lv_label_set_text_static(wifi_status, "unknown status");
  lv_label_set_long_mode(wifi_status, LV_LABEL_LONG_WRAP);
  lv_obj_set_height(wifi_status, LV_SIZE_CONTENT);
  lv_label_set_recolor(wifi_status, true);

  lv_obj_t* wifi_ssid_label = lv_label_create(wifi_panel);
  lv_label_set_text_static(wifi_ssid_label, "network name");
  lv_obj_add_style(wifi_ssid_label, &style_text_muted, 0);
  lv_obj_t* wifi_ssid = lv_dropdown_create(wifi_panel);
  settings.wifi_ssid_list_obj = wifi_ssid;
  lv_dropdown_clear_options(wifi_ssid);

  lv_obj_t* wifi_pwd_label = lv_label_create(wifi_panel);
  lv_label_set_text_static(wifi_pwd_label, "password");
  lv_obj_add_style(wifi_pwd_label, &style_text_muted, 0);
  lv_obj_t* wifi_pwd = lv_textarea_create(wifi_panel);
  settings.wifi_pwd_obj = wifi_pwd;
  lv_textarea_set_one_line(wifi_pwd, true);
  lv_textarea_set_password_mode(wifi_pwd, true);
  lv_obj_add_event_cb(wifi_pwd, textarea_event_cb, LV_EVENT_ALL, NULL);

  lv_obj_t* wifi_connect_btn = lv_btn_create(wifi_panel);
  settings.wifi_connect_btn_obj = wifi_connect_btn;
  lv_obj_set_height(wifi_connect_btn, LV_SIZE_CONTENT);
  lv_obj_add_event_cb(wifi_connect_btn, wifi_connect_btn_callback, LV_EVENT_CLICKED, NULL);
  lv_obj_t* wifi_connect_btn_label = lv_label_create(wifi_connect_btn);
  lv_label_set_text_static(wifi_connect_btn_label, "CONNECT");
  lv_obj_center(wifi_connect_btn_label);

  /********************
   * power panel
   ********************/
  lv_obj_t* power_panel = lv_obj_create(parent);
  lv_obj_set_height(power_panel, LV_SIZE_CONTENT);
  lv_obj_t * power_panel_title = lv_label_create(power_panel);
  lv_label_set_text_static(power_panel_title, LV_SYMBOL_POWER " POWER");
  lv_obj_add_style(power_panel_title, &style_title, 0);

  lv_obj_t* poweroff_text = lv_label_create(power_panel);
  lv_label_set_text_static(poweroff_text, "once shut down, the power cord\ncan be removed.");
  lv_label_set_long_mode(poweroff_text, LV_LABEL_LONG_WRAP);
  lv_obj_set_height(poweroff_text, LV_SIZE_CONTENT);
  lv_label_set_recolor(poweroff_text, true);

  lv_obj_t* power_halt_btn = lv_btn_create(power_panel);
  settings.power_halt_btn_obj = power_halt_btn;
  lv_obj_set_height(power_halt_btn, LV_SIZE_CONTENT);
  lv_obj_add_style(power_halt_btn, &style_btn_red, 0);
  lv_obj_add_event_cb(power_halt_btn, power_halt_btn_callback, LV_EVENT_CLICKED, NULL);
  lv_obj_t* power_halt_btn_label = lv_label_create(power_halt_btn);
  lv_label_set_text_static(power_halt_btn_label, "SHUTDOWN");
  lv_obj_center(power_halt_btn_label);

  /********************
   * layout
   ********************/
  static lv_coord_t parent_grid_cols[] = {LV_GRID_FR(1), LV_GRID_TEMPLATE_LAST};
  static lv_coord_t parent_grid_rows[] = {
      LV_GRID_CONTENT, /* wifi panel */
      LV_GRID_CONTENT, /* power panel */
      LV_GRID_TEMPLATE_LAST
  };
  lv_obj_set_grid_dsc_array(parent, parent_grid_cols, parent_grid_rows);
  lv_obj_set_grid_cell(wifi_panel, LV_GRID_ALIGN_STRETCH, 0, 1, LV_GRID_ALIGN_CENTER, 0, 1);
  lv_obj_set_grid_cell(power_panel, LV_GRID_ALIGN_STRETCH, 0, 1, LV_GRID_ALIGN_CENTER, 1, 1);

  static lv_coord_t wifi_grid_cols[] = {LV_GRID_FR(1), LV_GRID_FR(1), LV_GRID_TEMPLATE_LAST};
  static lv_coord_t wifi_grid_rows[] = {
      LV_GRID_CONTENT, /* title */
      5,               /* separator */
      LV_GRID_CONTENT, /* wifi status text */
      30,              /* wifi selector */
      5,               /* separator */
      LV_GRID_CONTENT, /* password label */
      30,              /* password input */
      5,               /* separator */
      LV_GRID_CONTENT, /* connect btn */
      LV_GRID_TEMPLATE_LAST
  };
  lv_obj_set_grid_dsc_array(wifi_panel, wifi_grid_cols, wifi_grid_rows);
  lv_obj_set_grid_cell(wifi_panel_title, LV_GRID_ALIGN_STRETCH, 0, 1, LV_GRID_ALIGN_CENTER, 0, 1);
  lv_obj_set_grid_cell(wifi_spinner, LV_GRID_ALIGN_END, 1, 1, LV_GRID_ALIGN_CENTER, 0, 1);
  /* column 0 */
  lv_obj_set_grid_cell(wifi_status, LV_GRID_ALIGN_START, 0, 1, LV_GRID_ALIGN_START, 2, 7);
  /* column 1 */
  lv_obj_set_grid_cell(wifi_ssid_label, LV_GRID_ALIGN_START, 1, 1, LV_GRID_ALIGN_START, 2, 1);
  lv_obj_set_grid_cell(wifi_ssid, LV_GRID_ALIGN_STRETCH, 1, 1, LV_GRID_ALIGN_CENTER, 3, 1);
  lv_obj_set_grid_cell(wifi_pwd_label, LV_GRID_ALIGN_START, 1, 1, LV_GRID_ALIGN_START, 5, 1);
  lv_obj_set_grid_cell(wifi_pwd, LV_GRID_ALIGN_STRETCH, 1, 1, LV_GRID_ALIGN_CENTER, 6, 1);
  lv_obj_set_grid_cell(wifi_connect_btn, LV_GRID_ALIGN_STRETCH, 1, 1, LV_GRID_ALIGN_CENTER, 8, 1);

  static lv_coord_t power_grid_cols[] = {LV_GRID_FR(1), LV_GRID_FR(1), LV_GRID_TEMPLATE_LAST};
  static lv_coord_t power_grid_rows[] = {
      LV_GRID_CONTENT, /* title */
      5,               /* separator */
      LV_GRID_CONTENT, /* power off text and btn*/
      LV_GRID_TEMPLATE_LAST
  };
  lv_obj_set_grid_dsc_array(power_panel, power_grid_cols, power_grid_rows);
  lv_obj_set_grid_cell(power_panel_title, LV_GRID_ALIGN_STRETCH, 0, 2, LV_GRID_ALIGN_CENTER, 0, 1);
  /* column 0 */
  lv_obj_set_grid_cell(poweroff_text, LV_GRID_ALIGN_START, 0, 1, LV_GRID_ALIGN_START, 2, 1);
  /* column 1 */
  lv_obj_set_grid_cell(power_halt_btn, LV_GRID_ALIGN_STRETCH, 1, 1, LV_GRID_ALIGN_CENTER, 2, 1);
}

static void tab_changed_event_cb(lv_event_t* e)
{
    (void)e; /* unused */
    uint16_t n = lv_tabview_get_tab_act(tabview);
    switch (n) {
    case 2:
        nm_tab_settings_active();
        break;
    default:
        LV_LOG_INFO("unhandled tab index %i", n);
    }
}

extern int ui_init()
{
  lv_init();
  lv_disp_t* disp = drv_init();
  if (disp == NULL) {
      return -1;
  }
  /* default theme is static */
  lv_theme_t* theme = lv_theme_default_init(
          disp,
          lv_palette_main(LV_PALETTE_BLUE), /* primary */
          lv_palette_main(LV_PALETTE_RED),  /* secondary */
          true /*LV_THEME_DEFAULT_DARK*/,
          LV_FONT_DEFAULT);
  lv_disp_set_theme(disp, theme);

  font_large = &lv_font_courierprimecode_24; /* static */
  lv_style_init(&style_title);
  lv_style_set_text_font(&style_title, font_large);

  lv_style_init(&style_text_muted);
  lv_style_set_text_opa(&style_text_muted, LV_OPA_50);

  lv_style_init(&style_btn_red);
  lv_style_set_bg_color(&style_btn_red, lv_palette_main(LV_PALETTE_RED));

  /* global virtual keyboard */
  virt_keyboard = lv_keyboard_create(lv_scr_act());
  if (virt_keyboard == NULL) {
      /* TODO: or continue without keyboard? */
      return -1;
  }
  lv_obj_add_flag(virt_keyboard, LV_OBJ_FLAG_HIDDEN);

  const lv_coord_t tabh = 60;
  tabview = lv_tabview_create(lv_scr_act(), LV_DIR_TOP, tabh);
  if (tabview == NULL) {
      return -1;
  }

  /**
   * tab_changed_event_cb relies on the specific tab order, 0-based index:
   * 0: bitcoin
   * 1: lightning
   * 2: settings
   */
  lv_obj_t* tab_btc = lv_tabview_add_tab(tabview, NM_SYMBOL_BITCOIN " BITCOIN");
  if (tab_btc == NULL) {
      return -1;
  }
  create_bitcoin_panel(tab_btc);
  lv_obj_t* tab_lnd = lv_tabview_add_tab(tabview, NM_SYMBOL_BOLT " LIGHTNING");
  if (tab_lnd == NULL) {
      return -1;
  }
  create_lnd_panel(tab_lnd);
  lv_obj_t* tab_settings = lv_tabview_add_tab(tabview, LV_SYMBOL_SETTINGS " SETTINGS");
  if (tab_settings == NULL) {
      return -1;
  }
  create_settings_panel(tab_settings);

  lv_obj_add_event_cb(tabview, tab_changed_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
  return 0;
}
