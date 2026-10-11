/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_PARAMETER_SERVICE_H
#define SC88_PARAMETER_SERVICE_H
#include "sc88_parameter_blocks.h"

typedef struct {
    sc88_parameter_blocks *blocks;
    uint8_t *results, *audio;
    unsigned left_cell, right_cell, started, audio_started, stopped, fault;
    uint64_t last_call_us, max_gap_us, max_service_us;
} sc88_parameter_service;

/* Caller initializes blocks only after reset, loads/flushes Wave ROM and configures
   the Codec before enabling service. Pointers use the fixed DDR region strides. */
int sc88_parameter_service_init(sc88_parameter_service *service, sc88_parameter_blocks *blocks,
                                uint8_t *results, uint8_t *audio, unsigned left, unsigned right);
/* No file I/O. Call from the main loop and disk-wait callback. Decoding into blocks
   belongs to the caller; this function transfers READY blocks and consumes results.
   Returns 0 while running, 1 after complete I2S drain, -1 on a latched fault/stop. */
int sc88_parameter_service_poll(sc88_parameter_service *service);
/* Stops submissions and mutes PL. Retains ownership until the caller drains/resets. */
void sc88_parameter_service_stop(sc88_parameter_service *service);
#ifdef SC88_PARAMETER_CAPTURE_FIRST
void sc88_parameter_capture_flush(void);
#endif
#endif
