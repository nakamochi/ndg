#ifndef NM_UI_H
#define NM_UI_H

#include <stdint.h>

/**
 * returns elapsed time since program start, in ms.
 * rolls over when overflow occurs.
 */
uint32_t nm_get_curr_tick();

/**
 * initiates system shutdown leading to poweroff.
 */
void nm_sys_shutdown();

/**
 * invoken when the UI is switched to the network settings tab.
 */
void nm_tab_settings_active();

/**
 * initiate connection to a wifi network with the given SSID and a password.
 * connection, if successful, is persisted in wpa_supplicant config.
 */
int nm_wifi_start_connect(const char *ssid, const char *password);

#endif
