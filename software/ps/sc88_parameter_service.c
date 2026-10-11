/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_parameter_service.h"
#include "sc88_parameter_audio.h"
#include "sc88_player.h"
#include <string.h>

#ifdef SC88_PARAMETER_EFFECTS
volatile unsigned sc88_effect_block_us[4], sc88_effect_blocks;
volatile unsigned sc88_effect_capture_frames;
#endif

#ifdef SC88_PARAMETER_CAPTURE_FIRST
enum { CAPTURE_FRAMES = 2048, CAPTURE_WORDS = 323 };
_Static_assert(CAPTURE_FRAMES * CAPTURE_WORDS * 8 <= SC88_CAPTURE_BYTES, "Capture exceeds reserved DDR");
volatile unsigned sc88_parameter_capture_frames;

void sc88_parameter_capture_flush(void)
{
    /* The caller has stopped playback and left the timed audio callback. */
    if (sc88_parameter_capture_frames) {
        sc88_flush(SC88_NATIVE_CAPTURE_BASE, CAPTURE_FRAMES * CAPTURE_WORDS * 8);
        sc88_barrier();
    }
}
#endif

void sc88_parameter_service_stop(sc88_parameter_service *s)
{
    sc88_write32(0x004, 8);
    sc88_write32(0x014, 0);
    sc88_barrier();
    s->stopped = 1;
    sc88_parameter_blocks_stop(s->blocks);
}

static int fail(sc88_parameter_service *s, unsigned reason)
{
    if (!s->fault) s->fault = reason;
    sc88_parameter_service_stop(s);
    return -1;
}

int sc88_parameter_service_init(sc88_parameter_service *s, sc88_parameter_blocks *b,
                                uint8_t *results, uint8_t *audio, unsigned left, unsigned right)
{
    memset(s, 0, sizeof(*s));
#ifdef SC88_PARAMETER_EFFECTS
    sc88_effect_capture_frames = 0;
#endif
#ifdef SC88_PARAMETER_CAPTURE_FIRST
    sc88_parameter_capture_frames = 0;
#endif
    s->blocks = b; s->results = results; s->audio = audio;
    s->left_cell = left; s->right_cell = right;
    if (left >= 64 || right >= 64 || sc88_read32(0) != 0x53435034 ||
        sc88_read32(0x008) != 1 || sc88_read32(0x00c) ||
        sc88_read32(0x080) || sc88_read32(0x088) || sc88_read32(0x084) != 7)
        return fail(s, 1);
    s->last_call_us = sc88_time_us();
    return 0;
}

static void descriptor(unsigned offset, uint32_t address, unsigned bytes, uint32_t result_address,
                       unsigned result_bytes, unsigned frames, uint64_t first, unsigned last)
{
    const uint32_t words[7] = {address, bytes, result_address, result_bytes, frames,
                              (uint32_t)first, (uint32_t)(first >> 32)};
    for (unsigned i = 0; i < 7; ++i) sc88_write32(offset + i * 4, words[i]);
    sc88_barrier();
    sc88_write32(offset + 28, last ? 0x101 : 1);
    sc88_barrier();
}

static int transfer(sc88_parameter_service *s)
{
    sc88_parameter_blocks *b = s->blocks;
    if (s->stopped) return -1;
    unsigned fault = sc88_read32(0x00c);
    if (fault || b->fault) return fail(s, fault ? fault : 2);

    for (unsigned n = 0; n < 2; ++n) {
        unsigned slot = b->submit_slot;
        sc88_input_block *block = &b->input[slot];
        if (block->owner != SC88_INPUT_READY) break;
        for (unsigned i = 0; i < block->frames; ++i) {
            sc88_prepared_frame *frame = sc88_parameter_blocks_frame(b, slot, i);
            sc88_flush((uintptr_t)(b->parameters + (slot * SC88_FRAMES_PER_BLOCK + i) * SC88_PARAMETER_SLOT_BYTES),
                       frame->parameter_bytes);
        }
        sc88_flush((uintptr_t)(b->commands + slot * SC88_FRAME_COMMAND_STRIDE), block->frames * 64);
        /* Result slots are aligned and CPU read-only. Invalidate after DMA
           completion; there are no dirty CPU result lines to clean here. */
        sc88_barrier();
        descriptor(0x100 + slot * 32, SC88_FRAME_COMMAND_BASE + slot * SC88_FRAME_COMMAND_STRIDE,
                   block->frames * 64, SC88_SEND_RESULT_BASE + slot * SC88_SEND_RESULT_STRIDE,
                   block->result_bytes, block->frames, block->first_frame, block->last);
        if (sc88_parameter_blocks_submit(b, slot)) return fail(s, 9);
    }
    for (unsigned n = 0; n < 2; ++n) {
        unsigned slot = b->audio_release_slot;
        if (b->audio[slot].owner != SC88_AUDIO_DMA ||
            ((sc88_read32(0x088) >> (slot * 2)) & 3) != 3) break;
        sc88_write32(0x180 + slot * 32 + 28, 2);
        sc88_write32(0x010, 4u << slot);
        sc88_barrier();
        if (sc88_parameter_audio_release(b, slot)) return fail(s, 3);
    }
    for (unsigned n = 0; n < 2; ++n) {
        unsigned slot = b->result_slot;
        if (b->input[slot].owner != SC88_INPUT_SUBMITTED ||
            ((sc88_read32(0x080) >> (slot * 2)) & 3) != 3) break;
        sc88_invalidate((uintptr_t)(s->results + slot * SC88_SEND_RESULT_STRIDE), b->input[slot].result_bytes);
        sc88_barrier();
        if (sc88_parameter_blocks_result_ready(b, slot)) return fail(s, 4);
        sc88_write32(0x010, 1u << slot);
        sc88_barrier();
    }
    for (unsigned n = 0; n < 2; ++n) {
        unsigned input = b->release_slot, audio = b->audio_fill_slot;
        sc88_input_block *block = &b->input[input];
        if (block->owner != SC88_INPUT_RESULT_READY || b->audio[audio].owner != SC88_AUDIO_FREE) break;
        if (block->first_frame != b->audio_next_frame || sc88_parameter_audio_begin(b, audio, block->frames))
            return fail(s, 5);
        const uint64_t *results = (const uint64_t *)(s->results + input * SC88_SEND_RESULT_STRIDE);
        uint64_t *output = (uint64_t *)(s->audio + audio * SC88_RETURN_AUDIO_STRIDE);
        unsigned words = 0;
#ifdef SC88_PARAMETER_EFFECTS
        uint64_t effect_start = sc88_time_us();
#endif
        for (unsigned i = 0; i < block->frames; ++i) {
            sc88_prepared_frame *frame = sc88_parameter_blocks_frame(b, input, i);
#ifdef SC88_PARAMETER_EFFECTS
            if (frame->result_words > block->result_bytes / 8 - words ||
                sc88_parameter_effects(frame, results + words, frame->result_words, output + i)) return fail(s, 6);
            if (frame->command[1] >= 0x04000000u / 8) return fail(s, 12);
            ((uint64_t *)SC88_NATIVE_CAPTURE_BASE)[frame->command[1]] = output[i];
            sc88_effect_capture_frames = (unsigned)frame->command[1] + 1;
#else
            if (frame->result_words > block->result_bytes / 8 - words ||
                sc88_parameter_diagnostic(frame, results + words, frame->result_words,
                                          s->left_cell, s->right_cell, output + i)) return fail(s, 6);
#endif
#ifdef SC88_PARAMETER_CAPTURE_FIRST
            uint64_t number = frame->command[1];
            uint64_t capture_offset = number - SC88_PARAMETER_CAPTURE_FIRST;
            if (capture_offset < CAPTURE_FRAMES) {
                uint64_t *capture = (uint64_t *)SC88_NATIVE_CAPTURE_BASE +
                    (unsigned)capture_offset * CAPTURE_WORDS;
                capture[0] = number; capture[1] = frame->result_words; capture[2] = output[i];
                memcpy(capture + 3, results + words, frame->result_words * 8);
                ++sc88_parameter_capture_frames;
            }
#endif
            words += frame->result_words;
        }
#ifdef SC88_PARAMETER_EFFECTS
        sc88_effect_block_us[sc88_effect_blocks++ & 3] = (unsigned)(sc88_time_us() - effect_start);
        sc88_flush(SC88_NATIVE_CAPTURE_BASE + block->first_frame * 8, block->frames * 8);
#endif
        if (words * 8 != block->result_bytes || sc88_parameter_audio_ready(b, audio)) return fail(s, 6);
        sc88_flush((uintptr_t)output, block->frames * 8);
        sc88_barrier();
        /* An effect block can overrun while the CPU owns it. A faulted PL rejects
           descriptor publication with an AXI error, so stop before that write. */
        fault = sc88_read32(0x00c);
        if (fault) return fail(s, fault);
#ifndef SC88_PARAMETER_EFFECTS
        descriptor(0x180 + audio * 32, SC88_RETURN_AUDIO_BASE + audio * SC88_RETURN_AUDIO_STRIDE,
                   block->frames * 8, 0, 0, block->frames, block->first_frame, block->last);
#endif
        if (sc88_parameter_audio_submit(b, audio)) return fail(s, 7);
#ifdef SC88_PARAMETER_EFFECTS
        if (sc88_parameter_audio_release(b, audio)) return fail(s, 7);
#endif
        sc88_write32(0x100 + input * 32 + 28, 2);
        sc88_barrier();
        if (sc88_parameter_blocks_release(b, input)) return fail(s, 8);
    }
    if (!s->started && b->input[0].owner == SC88_INPUT_SUBMITTED &&
        (b->input[1].owner == SC88_INPUT_SUBMITTED || b->input[0].last)) {
        sc88_write32(0x004, 1);
        sc88_barrier();
        s->started = 1;
    }
#ifdef SC88_PARAMETER_EFFECTS
    if (b->input_complete && b->audio_next_frame == b->prepare.total_frames &&
        b->input[0].owner == SC88_INPUT_FREE && b->input[1].owner == SC88_INPUT_FREE &&
        sc88_read32(0x18) == b->prepare.total_frames && sc88_read32(0x24) == b->prepare.total_frames)
        return 1;
#else
    unsigned level = sc88_read32(0x03c);
    unsigned queued = 0;
    for (unsigned slot = 0; slot < 2; ++slot)
        if (b->input[slot].owner == SC88_INPUT_SUBMITTED) queued += b->input[slot].frames;
    uint64_t remaining = b->prepare.total_frames - b->audio_next_frame;
    unsigned needed = remaining < 32 ? (unsigned)remaining : 32;
    /* The first audio due gives only 31.25 us. Prime the next command blocks
       before starting I2S, after the initial results have released their slots. */
    if (s->started && !s->audio_started && queued >= needed &&
        (level >= 32 || (level && sc88_read32(0x08c)))) {
        sc88_write32(0x004, 16);
        sc88_barrier();
        s->audio_started = 1;
    }
    if (sc88_read32(0x008) & 16) {
        if (!s->audio_started || !b->input_complete || b->audio_next_frame != b->prepare.total_frames)
            return fail(s, 10);
        /* The final DMA completion may arrive after this call's owner snapshot. */
        if (b->input[0].owner != SC88_INPUT_FREE || b->input[1].owner != SC88_INPUT_FREE ||
            b->audio[0].owner != SC88_AUDIO_FREE || b->audio[1].owner != SC88_AUDIO_FREE) return 0;
        return 1;
    }
#endif
    return 0;
}

int sc88_parameter_service_poll(sc88_parameter_service *s)
{
    uint64_t started = sc88_time_us(), gap = started - s->last_call_us;
    if (gap > s->max_gap_us) s->max_gap_us = gap;
    s->last_call_us = started;
    int status = transfer(s);
    uint64_t elapsed = sc88_time_us() - started;
    if (elapsed > s->max_service_us) s->max_service_us = elapsed;
    return status;
}
