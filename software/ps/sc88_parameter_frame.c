/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_parameter_frame.h"
#include <string.h>

static void put(uint8_t *data, uint64_t value, unsigned bytes)
{
    uint32_t low = (uint32_t)value;
    data[0] = (uint8_t)low; data[1] = (uint8_t)(low >> 8);
    if (bytes == 2) return;
    data[2] = (uint8_t)(low >> 16); data[3] = (uint8_t)(low >> 24);
    if (bytes == 4) return;
    uint32_t high = (uint32_t)(value >> 32);
    data[4] = (uint8_t)high; data[5] = (uint8_t)(high >> 8);
    data[6] = (uint8_t)(high >> 16); data[7] = (uint8_t)(high >> 24);
}

static int fail(sc88_parameter_frame *frame, unsigned reason)
{
    if (!frame->fault) frame->fault = reason;
    return -1;
}

static int append(sc88_parameter_frame *frame, uint64_t word)
{
    if (frame->words == (SC88_PARAMETER_FRAME_BYTES - 32) / 8) return fail(frame, 2);
    put(frame->data + 32 + frame->words * 8, word, 8);
    ++frame->words;
    return 0;
}

void sc88_parameter_frame_begin(sc88_parameter_frame *frame, uint8_t *data, uint64_t number)
{
    memset(frame, 0, sizeof(*frame));
    frame->data = data;
    memset(data, 0, 32);
    memcpy(data, "SC88DMA1", 8);
    put(data + 8, number, 8);
}

int sc88_parameter_frame_configs(sc88_parameter_frame *frame, const sc88_host_changes *changes)
{
    if (frame->fault || frame->finished || frame->pending) return fail(frame, 1);
    /* Words come directly from the validated host converter, before any PC hook. */
    for (unsigned n = 0; n < changes->count; ++n) {
        if (append(frame, changes->words[n])) return -1;
        ++frame->configs;
    }
    return 0;
}

static int flush_hook(sc88_parameter_frame *frame)
{
    if (!frame->pending) return 0;
    uint64_t header = (UINT64_C(2) << 60) | ((uint64_t)frame->voice << 54) |
                      ((uint64_t)frame->stage << 51) | ((uint64_t)frame->mask << 25);
    if (frame->terminal) header |= (UINT64_C(1) << 50) | ((uint64_t)(frame->terminal - 1) << 47);
    if (append(frame, header)) return -1;
    unsigned count = 0;
    uint64_t pair = 0;
    for (unsigned fields = frame->mask; fields; fields &= fields - 1) {
        unsigned n = (unsigned)__builtin_ctz(fields);
        pair |= (uint64_t)frame->values[n] << ((count & 1) * 32);
        if (++count % 2 == 0) {
            if (append(frame, pair)) return -1;
            pair = 0;
        }
    }
    if (count % 2 && append(frame, pair)) return -1;
    ++frame->packets;
    return 0;
}

int sc88_parameter_frame_hook(sc88_parameter_frame *frame, unsigned voice, unsigned stage,
                             unsigned mask, const uint32_t *selected, int terminal)
{
    static const uint32_t allowed[5] = {0, 0x15801, 0x1000, 0x10001, 0x3ffc3f};
    if (frame->fault || frame->finished || voice >= 64 || stage < 1 || stage > 4 ||
        (mask & ~allowed[stage]) || terminal < -1 || terminal > 4 ||
        (terminal != -1 && stage != 4) || (!mask && terminal == -1)) return fail(frame, 1);
    unsigned index = 0;
    for (unsigned fields = mask; fields; fields &= fields - 1) {
        unsigned n = (unsigned)__builtin_ctz(fields);
        uint32_t value = selected[index++];
        unsigned width = n == 21 ? 1 : n >= 15 ? 20 : 18;
        if (value >= (1u << width) || (n >= 6 && n <= 10 && (value & 0x20000))) return fail(frame, 1);
    }
    unsigned key = voice * 4 + stage, previous = frame->voice * 4 + frame->stage;
    if (frame->pending && key < previous) return fail(frame, 1);
    if (!frame->pending || key != previous) {
        if (flush_hook(frame)) return -1;
        frame->pending = 1;
        frame->voice = voice;
        frame->stage = stage;
        frame->mask = frame->terminal = 0;
    }
    /* SC88PAR1 permits one Delta and one Terminal at the same hook, in either order. */
    if ((mask && frame->mask) || (terminal != -1 && frame->terminal)) return fail(frame, 1);
    if (terminal != -1) frame->terminal = (unsigned)terminal + 1;
    index = 0;
    for (unsigned fields = mask; fields; fields &= fields - 1)
        frame->values[(unsigned)__builtin_ctz(fields)] = selected[index++];
    frame->mask |= mask;
    return 0;
}

unsigned sc88_parameter_frame_finish(sc88_parameter_frame *frame)
{
    if (frame->fault || frame->finished) { fail(frame, 1); return 0; }
    if (flush_hook(frame)) return 0;
    unsigned used = 32 + frame->words * 8, bytes = (used + 31) & ~31u;
    memset(frame->data + used, 0, bytes - used);
    put(frame->data + 16, bytes, 4);
    put(frame->data + 20, frame->words, 4);
    put(frame->data + 24, frame->configs, 2);
    put(frame->data + 26, frame->packets, 2);
    frame->finished = 1;
    return bytes;
}
