/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_PARAMETER_FRAME_H
#define SC88_PARAMETER_FRAME_H
#include "sc88_host_config.h"
#define SC88_PARAMETER_FRAME_BYTES 16384u

typedef struct {
    uint8_t *data;
    unsigned words, configs, packets, fault, finished;
    unsigned pending, voice, stage, mask, terminal;
    uint32_t values[22];
} sc88_parameter_frame;

/* Caller owns a 16 KiB buffer; DMA publication is allowed only after finish succeeds. */
void sc88_parameter_frame_begin(sc88_parameter_frame *frame, uint8_t *data, uint64_t number);
int sc88_parameter_frame_configs(sc88_parameter_frame *frame, const sc88_host_changes *changes);
int sc88_parameter_frame_hook(sc88_parameter_frame *frame, unsigned voice, unsigned stage,
                             unsigned mask, const uint32_t *selected, int terminal);
/* Returns aligned byte count, or zero on malformed/oversized/incomplete input. */
unsigned sc88_parameter_frame_finish(sc88_parameter_frame *frame);
#endif
