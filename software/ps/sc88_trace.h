// SPDX-License-Identifier: GPL-3.0-only
#ifndef SC88_TRACE_H
#define SC88_TRACE_H
#include <stdint.h>
#include <stddef.h>

struct sc88_trace_header {
    char magic[4];
    uint32_t version,bytes,blocks,frames,voices;
    uint64_t first_frame,descriptors;
    uint32_t irq_status,irq_mask,physical16,bank_shifts,audio_route,interrupt;
};
struct sc88_trace_block {
    uint32_t offset,bytes,frames,last;
    uint64_t first_frame,reserved;
};
struct sc88_trace {
    const uint8_t *data;
    const struct sc88_trace_header *header;
    const struct sc88_trace_block *blocks;
};
_Static_assert(sizeof(struct sc88_trace_header)==64,"Trace header layout");
_Static_assert(sizeof(struct sc88_trace_block)==32,"Trace block layout");
int sc88_trace_open(const void *data,size_t bytes,struct sc88_trace *trace);
#endif
