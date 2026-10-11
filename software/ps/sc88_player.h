// SPDX-License-Identifier: GPL-3.0-only
#ifndef SC88_PLAYER_H
#define SC88_PLAYER_H
#include "sc88_trace.h"

#define SC88_CONTROL_BASE 0x43c00000u
#define SC88_COMMAND_BASE 0x02000000u
#define SC88_RESULT_BASE 0x06000000u
#define SC88_CAPTURE_BASE 0x08000000u
#define SC88_CAPTURE_BYTES 0x00800000u
#define SC88_WAVE_BASE 0x10000000u
#define SC88_WAVE_BYTES (20u<<20)

struct sc88_player {
    const struct sc88_trace *trace;
    int32_t *capture;
    uint32_t slot_block[2],next_block,completed_blocks,captured_frames;
};
uint32_t sc88_read32(unsigned offset);
void sc88_write32(unsigned offset,uint32_t value);
void sc88_flush(uintptr_t address,size_t bytes);
void sc88_invalidate(uintptr_t address,size_t bytes);
void sc88_barrier(void);
uint64_t sc88_time_us(void);
const uint64_t *sc88_result_words(unsigned slot);
int sc88_player_prepare(struct sc88_player *player,const struct sc88_trace *trace,int32_t *capture);
void sc88_player_start(void);
int sc88_player_service(struct sc88_player *player);
#endif
