/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_parameter_reader.h"
#include <string.h>

static uint64_t get(const uint8_t *p, unsigned bytes)
{
    uint32_t low = p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
    if (bytes == 4) return low;
    uint32_t high = p[4] | (uint32_t)p[5] << 8 | (uint32_t)p[6] << 16 | (uint32_t)p[7] << 24;
    return low | (uint64_t)high << 32;
}

static int fail(sc88_parameter_reader *r, unsigned reason)
{
    if (!r->fault) r->fault = reason;
    return -1;
}

void sc88_parameter_reader_init(sc88_parameter_reader *r)
{
    memset(r, 0, sizeof(*r));
    r->need_header = 1;
}

int sc88_parameter_reader_header(sc88_parameter_reader *r, const uint8_t *p, unsigned bytes)
{
    if (r->fault || !r->need_header || r->ended || bytes != 104) return fail(r, 1);
    uint64_t boot = get(p + 16, 8), song = get(p + 24, 8), tail = get(p + 32, 8), total = get(p + 40, 8);
    if (memcmp(p, "SC88PAR1", 8) || get(p + 8, 4) != 1 || get(p + 12, 4) != 32000 ||
        memcmp(p + 48, "9af8bb05bcef2994b5dbb60c5c028e978a72aecb", 40) ||
        get(p + 88, 4) != 1 || get(p + 92, 4) != 1 || get(p + 96, 4) != r->segment ||
        get(p + 100, 4) != r->block_index || !boot || !song || tail > song ||
        boot > UINT64_MAX - song || total != boot + song) return fail(r, 1);
    if (r->segment && memcmp(p, r->identity, 96)) return fail(r, 1);
    memcpy(r->identity, p, 96);
    r->total_frames = total;
    r->need_header = 0;
    return 0;
}

int sc88_parameter_reader_block(sc88_parameter_reader *r, const uint8_t *p, unsigned bytes)
{
    if (r->fault || r->need_header || r->ended || r->remaining || r->position != r->bytes ||
        r->sequence || bytes < 32) return fail(r, 2);
    uint64_t first = get(p + 8, 8), last = get(p + 16, 8);
    uint32_t payload = (uint32_t)get(p + 24, 4), count = (uint32_t)get(p + 28, 4);
    if (memcmp(p, "PBL1", 4) || get(p + 4, 4) != r->block_index || first != r->frame ||
        last < first || last > r->total_frames || !payload || payload > SC88_PARAMETER_BLOCK_BYTES ||
        bytes - 32 != payload || !count || count > payload / 24) return fail(r, 2);
    r->data = p + 32;
    r->bytes = payload;
    r->position = 0;
    r->remaining = count;
    r->block_last = last;
    ++r->block_index;
    return 0;
}

static int validate(sc88_parameter_reader *r, const sc88_parameter_event *e)
{
    static const uint32_t allowed[5] = {0, 0x15801, 0x1000, 0x10001, 0x3ffc3f};
    if (e->kind == 6 || e->kind == 7) {
        if (e->target != 1 || e->voice >= 64 || e->stage < 1 || e->stage > 4) return fail(r, 3);
        if (e->kind == 7) {
            if (e->stage != 4 || e->mask || e->bytes != 1 || e->payload[0] > 4) return fail(r, 3);
        } else {
            if (!e->mask || (e->mask & ~allowed[e->stage])) return fail(r, 3);
            unsigned offset = 0;
            for (unsigned fields = e->mask; fields; fields &= fields - 1) {
                unsigned n = (unsigned)__builtin_ctz(fields);
                if (e->bytes - offset < 4) return fail(r, 3);
                uint32_t value = (uint32_t)get(e->payload + offset, 4);
                unsigned width = n == 21 ? 1 : n >= 15 ? 20 : 18;
                if (value >= (1u << width) || (n >= 6 && n <= 10 && (value & 0x20000))) return fail(r, 3);
                offset += 4;
            }
            if (offset != e->bytes) return fail(r, 3);
        }
        unsigned key = e->voice * 4 + e->stage;
        uint8_t seen = r->control_seen[key - 1];
        /* Fixed reference consumes Delta before the optional terminal arbitration. */
        if (key < r->hook_key || (e->kind == 6 && seen) || (e->kind == 7 && (seen & 2))) return fail(r, 4);
        r->hook_key = key;
        r->control_seen[key - 1] |= e->kind == 6 ? 1 : 2;
        return 0;
    }
    if (e->stage || e->voice != 255 || e->mask) return fail(r, 3);
    switch (e->kind) {
    case 1: case 5: case 8:
        if (e->target || e->bytes) return fail(r, 3);
        break;
    case 2:
        if (r->hook_key || (e->target != 1 && e->target != 2) || e->bytes != 3) return fail(r, 3);
        break;
    case 3:
        if (r->hook_key || e->target > 2 || e->bytes != 2 ||
            (!e->target && (e->payload[0] != 0x8f || e->payload[1] != 0xfe))) return fail(r, 3);
        break;
    case 4:
        if (r->hook_key || e->target || e->bytes != 1) return fail(r, 3);
        break;
    default: return fail(r, 3);
    }
    return 0;
}

int sc88_parameter_reader_next(sc88_parameter_reader *r, sc88_parameter_event *event)
{
    if (r->fault || r->need_header) return fail(r, 4);
    if (!r->remaining) return 0;
    if (r->ended || r->bytes - r->position < 24) return fail(r, 3);
    const uint8_t *p = r->data + r->position;
    sc88_parameter_event e;
    e.frame = get(p, 8); e.sequence = (uint32_t)get(p + 8, 4);
    e.kind = p[12]; e.stage = p[13]; e.target = p[14]; e.voice = p[15];
    e.mask = (uint32_t)get(p + 16, 4); e.bytes = (uint32_t)get(p + 20, 4); e.payload = p + 24;
    if (e.bytes > r->bytes - r->position - 24) return fail(r, 3);
    if (e.frame != r->frame || e.sequence != r->sequence || e.frame > r->block_last ||
        (r->remaining == 1 && (e.frame != r->block_last || r->position + 24 + e.bytes != r->bytes)) ||
        (!r->reset_seen && e.kind != 1) || (e.frame == r->total_frames && e.kind != 8)) return fail(r, 4);
    if (e.kind == 1 && (r->reset_seen || r->records)) return fail(r, 4);
    if (e.kind == 8 && (e.frame != r->total_frames || r->remaining != 1)) return fail(r, 5);
    if (r->remaining == 1 && e.kind != 5 && e.kind != 8) return fail(r, 4);
    if (validate(r, &e)) return -1;
    r->position += 24 + e.bytes;
    --r->remaining; ++r->sequence; ++r->records;
    if (e.kind == 1) r->reset_seen = 1;
    if (e.kind == 5) {
        ++r->frame; r->sequence = r->hook_key = 0;
        memset(r->control_seen, 0, sizeof(r->control_seen));
    }
    if (e.kind == 8) r->ended = 1;
    *event = e;
    return 1;
}

int sc88_parameter_reader_eof(sc88_parameter_reader *r, unsigned more)
{
    if (r->fault || r->need_header || r->complete || r->remaining || r->position != r->bytes ||
        (!r->ended && r->sequence) || (r->ended && more) || (!r->ended && !more)) return fail(r, 5);
    if (r->ended) r->complete = 1;
    else { ++r->segment; r->need_header = 1; }
    return 0;
}
