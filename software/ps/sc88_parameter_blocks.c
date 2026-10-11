/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_parameter_blocks.h"
#include <string.h>

static int fail(sc88_parameter_blocks *b)
{
    b->fault = 1;
    return -1;
}

void sc88_parameter_blocks_init(sc88_parameter_blocks *b, uint64_t total_frames,
                               uint8_t *controls, uint8_t *commands, uint8_t *parameters)
{
    memset(b, 0, sizeof(*b));
    sc88_frame_prepare_init(&b->prepare, total_frames);
    b->controls = controls;
    b->commands = commands;
    b->parameters = parameters;
}

sc88_prepared_frame *sc88_parameter_blocks_frame(sc88_parameter_blocks *b, unsigned slot, unsigned frame)
{
    return (sc88_prepared_frame *)(b->controls + (slot * SC88_FRAMES_PER_BLOCK + frame) * SC88_PS_CONTROL_STRIDE);
}

int sc88_parameter_blocks_event(sc88_parameter_blocks *b, const sc88_parameter_event *e)
{
    if (b->fault || b->stopped || b->end_seen) return fail(b);
    if (e->kind == 8) {
        if (b->prepare.active || b->prepare.frame != b->prepare.total_frames ||
            e->frame != b->prepare.total_frames) return fail(b);
        b->end_seen = 1;
        return 1;
    }
    sc88_input_block *slot = &b->input[b->build_slot];
    if (slot->owner != SC88_INPUT_FREE && slot->owner != SC88_INPUT_BUILDING) return 0;
    if (!b->prepare.active) {
        if (b->prepare.frame >= b->prepare.total_frames) return fail(b);
        if (slot->owner == SC88_INPUT_FREE) {
            *slot = (sc88_input_block){.owner = SC88_INPUT_BUILDING, .first_frame = b->prepare.frame};
        }
        unsigned index = b->build_slot * SC88_FRAMES_PER_BLOCK + slot->frames;
        if (sc88_frame_prepare_begin(&b->prepare, sc88_parameter_blocks_frame(b, b->build_slot, slot->frames),
                                    b->parameters + index * SC88_PARAMETER_SLOT_BYTES,
                                    SC88_PARAMETER_BASE + index * SC88_PARAMETER_SLOT_BYTES)) return fail(b);
    }
    int status = sc88_frame_prepare_event(&b->prepare, e);
    if (status < 0) return fail(b);
    if (status) {
        sc88_prepared_frame *frame = sc88_parameter_blocks_frame(b, b->build_slot, slot->frames);
        memcpy(b->commands + b->build_slot * SC88_FRAME_COMMAND_STRIDE + slot->frames * 64, frame->command, 64);
        ++slot->frames;
        slot->result_bytes += frame->result_words * 8;
        slot->last = b->prepare.frame == b->prepare.total_frames;
        if (slot->frames == SC88_FRAMES_PER_BLOCK && !slot->last) {
            slot->owner = SC88_INPUT_READY;
            b->build_slot ^= 1;
        }
    }
    return 1;
}

int sc88_parameter_blocks_finish(sc88_parameter_blocks *b)
{
    sc88_input_block *slot = &b->input[b->build_slot];
    if (b->fault || b->stopped || b->input_complete || !b->end_seen ||
        slot->owner != SC88_INPUT_BUILDING || !slot->last || !slot->frames) return fail(b);
    slot->owner = SC88_INPUT_READY;
    b->input_complete = 1;
    return 0;
}

int sc88_parameter_blocks_submit(sc88_parameter_blocks *b, unsigned slot)
{
    if (b->fault || b->stopped || slot != b->submit_slot || b->input[slot].owner != SC88_INPUT_READY) return fail(b);
    b->input[slot].owner = SC88_INPUT_SUBMITTED;
    b->submit_slot ^= 1;
    return 0;
}

int sc88_parameter_blocks_result_ready(sc88_parameter_blocks *b, unsigned slot)
{
    if (b->fault || b->stopped || slot != b->result_slot || b->input[slot].owner != SC88_INPUT_SUBMITTED) return fail(b);
    b->input[slot].owner = SC88_INPUT_RESULT_READY;
    b->result_slot ^= 1;
    return 0;
}

int sc88_parameter_blocks_release(sc88_parameter_blocks *b, unsigned slot)
{
    if (b->fault || b->stopped || slot != b->release_slot || b->input[slot].owner != SC88_INPUT_RESULT_READY) return fail(b);
    b->input[slot].owner = SC88_INPUT_FREE;
    b->release_slot ^= 1;
    return 0;
}

int sc88_parameter_audio_begin(sc88_parameter_blocks *b, unsigned slot, unsigned frames)
{
    if (b->fault || b->stopped || slot != b->audio_fill_slot || b->audio[slot].owner != SC88_AUDIO_FREE ||
        !frames || frames > SC88_FRAMES_PER_BLOCK || b->audio_next_frame > b->prepare.total_frames ||
        frames > b->prepare.total_frames - b->audio_next_frame) return fail(b);
    b->audio[slot] = (sc88_audio_block){.owner = SC88_AUDIO_FILLING, .first_frame = b->audio_next_frame,
                                       .frames = frames, .last = frames == b->prepare.total_frames - b->audio_next_frame};
    b->audio_next_frame += frames;
    b->audio_fill_slot ^= 1;
    return 0;
}

int sc88_parameter_audio_ready(sc88_parameter_blocks *b, unsigned slot)
{
    if (b->fault || b->stopped || slot > 1 || b->audio[slot].owner != SC88_AUDIO_FILLING) return fail(b);
    b->audio[slot].owner = SC88_AUDIO_READY;
    return 0;
}

int sc88_parameter_audio_submit(sc88_parameter_blocks *b, unsigned slot)
{
    if (b->fault || b->stopped || slot != b->audio_submit_slot || b->audio[slot].owner != SC88_AUDIO_READY) return fail(b);
    b->audio[slot].owner = SC88_AUDIO_DMA;
    b->audio_submit_slot ^= 1;
    return 0;
}

int sc88_parameter_audio_release(sc88_parameter_blocks *b, unsigned slot)
{
    if (b->fault || b->stopped || slot != b->audio_release_slot || b->audio[slot].owner != SC88_AUDIO_DMA) return fail(b);
    b->audio[slot].owner = SC88_AUDIO_FREE;
    b->audio_release_slot ^= 1;
    return 0;
}

void sc88_parameter_blocks_stop(sc88_parameter_blocks *b)
{
    b->stopped = 1;
}
