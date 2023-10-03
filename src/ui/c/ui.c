/**
 * function declarations with nm_ prefix are typically defined in zig,
 * while function definitions with nm_ prefix are extern'ed to call from zig.
 */

#define _DEFAULT_SOURCE /* needed for usleep() */

#include "lvgl/lvgl.h"

#include <stdlib.h>
#include <unistd.h>

/**
 * initiates system shutdown leading to poweroff.
 */
void nm_sys_shutdown();

/**
 * creates an info panel with build info, semver, about and other related items.
 */
int nm_create_info_panel(lv_obj_t *parent);

/**
 * creates the bitcoin tab panel.
 */
int nm_create_bitcoin_panel(lv_obj_t *parent);

/**
 * creates the lightning tab panel.
 */
int nm_create_lightning_panel(lv_obj_t *parent);

/**
 * creates the sysupdates section of the settings panel.
 */
lv_obj_t *nm_create_settings_sysupdates(lv_obj_t *parent);

/**
 * invoken when the UI is switched to the network settings tab.
 */
void nm_tab_settings_active();

/**
 * initiate connection to a wifi network with the given SSID and a password.
 * connection, if successful, is persisted in wpa_supplicant config.
 */
int nm_wifi_start_connect(const char *ssid, const char *password);

/**
 * callback fn when "power off" button is pressed.
 */
void nm_poweroff_btn_callback(lv_event_t *e);

static lv_style_t style_title;
static lv_style_t style_text_muted;
static lv_style_t style_btn_red;
static const lv_font_t *font_large;
static lv_obj_t *virt_keyboard;
static lv_obj_t *tabview; /* main tabs content parent; lv_tabview_create */

/**
 * returns user-managed data previously set on an object with nm_obj_set_userdata.
 * the returned value may be NULL.
 */
extern void *nm_obj_userdata(lv_obj_t *obj)
{
    return obj->user_data;
}

/**
 * set or "attach" user-managed data to an object.
 * the data pointer may be NULL.
 */
extern void nm_obj_set_userdata(lv_obj_t *obj, void *data)
{
    obj->user_data = data;
}

/**
 * returns a "red" style for a button. useful to attract particular attention
 * to a potentially "dangerous" operation.
 *
 * the returned value is static. available only after nm_ui_init.
 */
extern lv_style_t *nm_style_btn_red()
{
    return &style_btn_red;
}

extern lv_style_t *nm_style_title()
{
    return &style_title;
}

static void textarea_event_cb(lv_event_t *e)
{
    lv_obj_t *textarea = lv_event_get_target(e);
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
        lv_indev_reset(NULL, textarea); /* forget last obj to make it focusable again */
    }
}

static struct {
    lv_obj_t *wifi_spinner_obj;     /* lv_spinner_create */
    lv_obj_t *wifi_status_obj;      /* lv_label_create */
    lv_obj_t *wifi_connect_btn_obj; /* lv_btn_create */
    lv_obj_t *wifi_ssid_list_obj;   /* lv_dropdown_create */
    lv_obj_t *wifi_pwd_obj;         /* lv_textarea_create */
    lv_obj_t *power_halt_btn_obj;   /* lv_btn_create */
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

static void wifi_connect_btn_callback(lv_event_t *e)
{
    (void)e; /* unused */
    lv_obj_add_state(settings.wifi_connect_btn_obj, LV_STATE_DISABLED);
    lv_obj_clear_flag(settings.wifi_spinner_obj, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(settings.wifi_status_obj, "connecting ...");

    char buf[100];
    lv_dropdown_get_selected_str(settings.wifi_ssid_list_obj, buf, sizeof(buf));
    nm_wifi_start_connect(buf, lv_textarea_get_text(settings.wifi_pwd_obj));
}

static int create_settings_panel(lv_obj_t *parent)
{
    /********************
     * wifi panel
     ********************/
    lv_obj_t *wifi_panel = lv_obj_create(parent);
    lv_obj_set_height(wifi_panel, LV_SIZE_CONTENT);
    lv_obj_t *wifi_panel_title = lv_label_create(wifi_panel);
    lv_label_set_text_static(wifi_panel_title, LV_SYMBOL_WIFI " WIFI");
    lv_obj_add_style(wifi_panel_title, &style_title, 0);

    lv_obj_t *wifi_spinner = lv_spinner_create(wifi_panel, 1000 /* speed */, 60 /* arc in deg */);
    settings.wifi_spinner_obj = wifi_spinner;
    lv_obj_add_flag(wifi_spinner, LV_OBJ_FLAG_HIDDEN);
    lv_obj_set_size(wifi_spinner, 20, 20);
    lv_obj_set_style_arc_width(wifi_spinner, 4, LV_PART_INDICATOR);

    lv_obj_t *wifi_status = lv_label_create(wifi_panel);
    settings.wifi_status_obj = wifi_status;
    lv_label_set_text_static(wifi_status, "unknown status");
    lv_label_set_long_mode(wifi_status, LV_LABEL_LONG_WRAP);
    lv_obj_set_height(wifi_status, LV_SIZE_CONTENT);
    lv_label_set_recolor(wifi_status, true);

    lv_obj_t *wifi_ssid_label = lv_label_create(wifi_panel);
    lv_label_set_text_static(wifi_ssid_label, "network name");
    lv_obj_add_style(wifi_ssid_label, &style_text_muted, 0);
    lv_obj_t *wifi_ssid = lv_dropdown_create(wifi_panel);
    settings.wifi_ssid_list_obj = wifi_ssid;
    lv_dropdown_clear_options(wifi_ssid);

    lv_obj_t *wifi_pwd_label = lv_label_create(wifi_panel);
    lv_label_set_text_static(wifi_pwd_label, "password");
    lv_obj_add_style(wifi_pwd_label, &style_text_muted, 0);
    lv_obj_t *wifi_pwd = lv_textarea_create(wifi_panel);
    settings.wifi_pwd_obj = wifi_pwd;
    lv_textarea_set_one_line(wifi_pwd, true);
    lv_textarea_set_password_mode(wifi_pwd, true);
    lv_obj_add_event_cb(wifi_pwd, textarea_event_cb, LV_EVENT_ALL, NULL);

    lv_obj_t *wifi_connect_btn = lv_btn_create(wifi_panel);
    settings.wifi_connect_btn_obj = wifi_connect_btn;
    lv_obj_set_height(wifi_connect_btn, LV_SIZE_CONTENT);
    lv_obj_add_event_cb(wifi_connect_btn, wifi_connect_btn_callback, LV_EVENT_CLICKED, NULL);
    lv_obj_t *wifi_connect_btn_label = lv_label_create(wifi_connect_btn);
    lv_label_set_text_static(wifi_connect_btn_label, "CONNECT");
    lv_obj_center(wifi_connect_btn_label);

    /********************
     * power panel
     ********************/
    lv_obj_t *power_panel = lv_obj_create(parent);
    lv_obj_set_height(power_panel, LV_SIZE_CONTENT);
    lv_obj_t *power_panel_title = lv_label_create(power_panel);
    lv_label_set_text_static(power_panel_title, LV_SYMBOL_POWER " POWER");
    lv_obj_add_style(power_panel_title, &style_title, 0);

    lv_obj_t *poweroff_text = lv_label_create(power_panel);
    lv_label_set_text_static(poweroff_text, "once shut down, the power cord\ncan be removed.");
    lv_label_set_long_mode(poweroff_text, LV_LABEL_LONG_WRAP);
    lv_obj_set_height(poweroff_text, LV_SIZE_CONTENT);
    lv_label_set_recolor(poweroff_text, true);

    lv_obj_t *power_halt_btn = lv_btn_create(power_panel);
    settings.power_halt_btn_obj = power_halt_btn;
    lv_obj_set_height(power_halt_btn, LV_SIZE_CONTENT);
    lv_obj_add_style(power_halt_btn, &style_btn_red, 0);
    lv_obj_add_event_cb(power_halt_btn, nm_poweroff_btn_callback, LV_EVENT_CLICKED, NULL);
    lv_obj_t *power_halt_btn_label = lv_label_create(power_halt_btn);
    lv_label_set_text_static(power_halt_btn_label, "SHUTDOWN");
    lv_obj_center(power_halt_btn_label);

    /********************
     * sysupdates panel
     ********************/
    // ported to zig;
    lv_obj_t *sysupdates_panel = nm_create_settings_sysupdates(parent);

    /********************
     * layout
     ********************/
    static lv_coord_t parent_grid_cols[] = {LV_GRID_FR(1), LV_GRID_TEMPLATE_LAST};
    static lv_coord_t parent_grid_rows[] = {/**/
        LV_GRID_CONTENT,                    /* wifi panel */
        LV_GRID_CONTENT,                    /* power panel */
        LV_GRID_CONTENT,                    /* sysupdates panel */
        LV_GRID_TEMPLATE_LAST};
    lv_obj_set_grid_dsc_array(parent, parent_grid_cols, parent_grid_rows);
    lv_obj_set_grid_cell(wifi_panel, LV_GRID_ALIGN_STRETCH, 0, 1, LV_GRID_ALIGN_CENTER, 0, 1);
    lv_obj_set_grid_cell(power_panel, LV_GRID_ALIGN_STRETCH, 0, 1, LV_GRID_ALIGN_CENTER, 1, 1);
    lv_obj_set_grid_cell(sysupdates_panel, LV_GRID_ALIGN_STRETCH, 0, 1, LV_GRID_ALIGN_CENTER, 2, 1);

    static lv_coord_t wifi_grid_cols[] = {LV_GRID_FR(1), LV_GRID_FR(1), LV_GRID_TEMPLATE_LAST};
    static lv_coord_t wifi_grid_rows[] = {/**/
        LV_GRID_CONTENT,                  /* title */
        5,                                /* separator */
        LV_GRID_CONTENT,                  /* wifi status text */
        30,                               /* wifi selector */
        5,                                /* separator */
        LV_GRID_CONTENT,                  /* password label */
        30,                               /* password input */
        5,                                /* separator */
        LV_GRID_CONTENT,                  /* connect btn */
        LV_GRID_TEMPLATE_LAST};
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
    static lv_coord_t power_grid_rows[] = {/**/
        LV_GRID_CONTENT,                   /* title */
        5,                                 /* separator */
        LV_GRID_CONTENT,                   /* power off text and btn*/
        LV_GRID_TEMPLATE_LAST};
    lv_obj_set_grid_dsc_array(power_panel, power_grid_cols, power_grid_rows);
    lv_obj_set_grid_cell(power_panel_title, LV_GRID_ALIGN_STRETCH, 0, 2, LV_GRID_ALIGN_CENTER, 0, 1);
    /* column 0 */
    lv_obj_set_grid_cell(poweroff_text, LV_GRID_ALIGN_START, 0, 1, LV_GRID_ALIGN_START, 2, 1);
    /* column 1 */
    lv_obj_set_grid_cell(power_halt_btn, LV_GRID_ALIGN_STRETCH, 1, 1, LV_GRID_ALIGN_CENTER, 2, 1);

    return 0;
}

static void tab_changed_event_cb(lv_event_t *e)
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

extern int nm_ui_init(lv_disp_t *disp)
{
    /* default theme is static */
    lv_theme_t *theme = lv_theme_default_init(disp, /**/
        lv_palette_main(LV_PALETTE_BLUE),           /* primary */
        lv_palette_main(LV_PALETTE_RED),            /* secondary */
        true,                                       /* dark mode, LV_THEME_DEFAULT_DARK */
        LV_FONT_DEFAULT /* lv_conf.h def */);
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
     * 3: ndg build info and versioning
     */

    lv_obj_t *tab_btc = lv_tabview_add_tab(tabview, NM_SYMBOL_BITCOIN " BITCOIN");
    if (tab_btc == NULL) {
        return -1;
    }
    if (nm_create_bitcoin_panel(tab_btc) != 0) {
        return -1;
    }

    lv_obj_t *tab_lnd = lv_tabview_add_tab(tabview, NM_SYMBOL_BOLT " LIGHTNING");
    if (tab_lnd == NULL) {
        return -1;
    }
    if (nm_create_lightning_panel(tab_lnd) != 0) {
        return -1;
    }

    lv_obj_t *tab_settings = lv_tabview_add_tab(tabview, LV_SYMBOL_SETTINGS " SETTINGS");
    if (tab_settings == NULL) {
        return -1;
    }
    if (create_settings_panel(tab_settings) != 0) {
        return -1;
    }

    lv_obj_t *tab_info = lv_tabview_add_tab(tabview, NM_SYMBOL_INFO);
    if (tab_info == NULL) {
        return -1;
    }
    if (nm_create_info_panel(tab_info) != 0) {
        return -1;
    }

    /* make the info tab button narrower, just for the icon to fit,
     * by widening the other tab buttons relative width. */
    lv_obj_t *tabbs = lv_tabview_get_tab_btns(tabview);
    lv_btnmatrix_set_btn_width(tabbs, 0, 3);
    lv_btnmatrix_set_btn_width(tabbs, 1, 3);
    lv_btnmatrix_set_btn_width(tabbs, 2, 3);

    lv_obj_add_event_cb(tabview, tab_changed_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
    return 0;
}
