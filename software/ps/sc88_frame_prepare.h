/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_FRAME_PREPARE_H
#define SC88_FRAME_PREPARE_H
#include "sc88_parameter_frame.h"
#include "sc88_parameter_reader.h"
#include "sc88_parameter_memory.h"

typedef struct {
    uint64_t command[8];
    uint64_t controls[256];
    unsigned control_count, result_words, parameter_bytes;
} sc88_prepared_frame;

typedef struct {
    sc88_host_config host;
    sc88_host_changes changes;
    sc88_parameter_frame packer;
    sc88_prepared_frame *output;
    uint64_t frame, total_frames;
    uint32_t parameter_address;
    unsigned irq_acknowledge, active, fault;
} sc88_frame_prepare;

void sc88_frame_prepare_init(sc88_frame_prepare *prepare, uint64_t total_frames);
int sc88_frame_prepare_begin(sc88_frame_prepare *prepare, sc88_prepared_frame *output,
                            uint8_t *parameters, uint32_t parameter_address);
/* Input is a validated reader event. END belongs to the file reader, not an audio frame.
   1 complete frame; 0 more events needed; -1 fault. */
int sc88_frame_prepare_event(sc88_frame_prepare *prepare, const sc88_parameter_event *event);
#endif
