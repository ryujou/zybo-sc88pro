/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_PARAMETER_READER_H
#define SC88_PARAMETER_READER_H
#include <stdint.h>
#define SC88_PARAMETER_BLOCK_BYTES (8u * 1024u * 1024u)

typedef struct {
    uint64_t frame;
    uint32_t sequence, mask, bytes;
    uint8_t kind, stage, target, voice;
    const uint8_t *payload;
} sc88_parameter_event;

typedef struct {
    uint64_t frame, total_frames, block_last, records;
    uint32_t sequence, segment, block_index, remaining, bytes, position;
    unsigned need_header, reset_seen, ended, complete, fault, hook_key;
    uint8_t identity[96], control_seen[256];
    const uint8_t *data;
} sc88_parameter_reader;

void sc88_parameter_reader_init(sc88_parameter_reader *reader);
int sc88_parameter_reader_header(sc88_parameter_reader *reader, const uint8_t *data, unsigned bytes);
/* Caller keeps this complete logical block alive until next() returns zero. */
int sc88_parameter_reader_block(sc88_parameter_reader *reader, const uint8_t *data, unsigned bytes);
/* 1: validated event, 0: block exhausted, -1: latched error. No event is emitted on error. */
int sc88_parameter_reader_next(sc88_parameter_reader *reader, sc88_parameter_event *event);
/* At actual file EOF, more says whether the immediately following numbered segment exists. */
int sc88_parameter_reader_eof(sc88_parameter_reader *reader, unsigned more);
#endif
