#ifndef NM_UI_H
#define NM_UI_H

/**
 * this file exists to satisfy LV_TICK_CUSTOM_INCLUDE.
 */

#include <stdint.h>

/**
 * returns elapsed time since program start, in ms.
 * rolls over when overflow occurs.
 */
uint32_t nm_get_curr_tick();

#endif
