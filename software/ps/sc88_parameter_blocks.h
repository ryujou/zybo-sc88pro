/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_PARAMETER_BLOCKS_H
#define SC88_PARAMETER_BLOCKS_H
#include "sc88_frame_prepare.h"

enum sc88_input_owner {
    SC88_INPUT_FREE, SC88_INPUT_BUILDING, SC88_INPUT_READY,
    SC88_INPUT_SUBMITTED, SC88_INPUT_RESULT_READY
};
enum sc88_audio_owner {
    SC88_AUDIO_FREE, SC88_AUDIO_FILLING, SC88_AUDIO_READY, SC88_AUDIO_DMA
};
typedef struct {
    uint64_t first_frame;
    unsigned owner, frames, result_bytes, last;
} sc88_input_block;
typedef struct {
    uint64_t first_frame;
    unsigned owner, frames, last;
} sc88_audio_block;
typedef struct {
    sc88_frame_prepare prepare;
    uint8_t *controls, *commands, *parameters;
    sc88_input_block input[2];
    sc88_audio_block audio[2];
    uint64_t audio_next_frame;
    unsigned build_slot, submit_slot, result_slot, release_slot;
    unsigned audio_fill_slot, audio_submit_slot, audio_release_slot;
    unsigned end_seen, input_complete, stopped, fault;
} sc88_parameter_blocks;

/* Pointers refer to the regions/strides in sc88_parameter_memory.h. Initialize only
   after old DMA has drained and the PL reset has completed. */
void sc88_parameter_blocks_init(sc88_parameter_blocks *blocks, uint64_t total_frames,
                               uint8_t *controls, uint8_t *commands, uint8_t *parameters);
sc88_prepared_frame *sc88_parameter_blocks_frame(sc88_parameter_blocks *blocks, unsigned slot, unsigned frame);
/* Validated reader event: 1 consumed, 0 wait for a free input slot, -1 fault. */
int sc88_parameter_blocks_event(sc88_parameter_blocks *blocks, const sc88_parameter_event *event);
/* Call only after the reader has validated END and final actual EOF. */
int sc88_parameter_blocks_finish(sc88_parameter_blocks *blocks);
/* Cache maintenance and MMIO belong to the caller; never release on command-read
   completion alone. result_ready follows result DMA completion; release follows PS consumption. */
int sc88_parameter_blocks_submit(sc88_parameter_blocks *blocks, unsigned slot);
int sc88_parameter_blocks_result_ready(sc88_parameter_blocks *blocks, unsigned slot);
int sc88_parameter_blocks_release(sc88_parameter_blocks *blocks, unsigned slot);
int sc88_parameter_audio_begin(sc88_parameter_blocks *blocks, unsigned slot, unsigned frames);
int sc88_parameter_audio_ready(sc88_parameter_blocks *blocks, unsigned slot);
int sc88_parameter_audio_submit(sc88_parameter_blocks *blocks, unsigned slot);
/* Only after the final DDR read response; independent of the input slot. */
int sc88_parameter_audio_release(sc88_parameter_blocks *blocks, unsigned slot);
void sc88_parameter_blocks_stop(sc88_parameter_blocks *blocks);
#endif
