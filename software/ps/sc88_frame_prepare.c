/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_frame_prepare.h"
#include <string.h>

_Static_assert(sizeof(sc88_prepared_frame) <= SC88_PS_CONTROL_STRIDE, "PS controls exceed slot");
_Static_assert(SC88_FRAMES_PER_BLOCK * 64 <= SC88_FRAME_COMMAND_STRIDE, "Frame commands exceed block");
_Static_assert(SC88_FRAMES_PER_BLOCK * 320 * 8 <= SC88_SEND_RESULT_STRIDE, "Voice/mixer results exceed block");
_Static_assert(SC88_FRAMES_PER_BLOCK * 8 <= SC88_RETURN_AUDIO_STRIDE, "Stereo audio exceeds block");
_Static_assert(SC88_PARAMETER_FRAME_BYTES == SC88_PARAMETER_SLOT_BYTES, "Parameter slot mismatch");

static int fail(sc88_frame_prepare *p)
{
    p->fault = 1;
    return -1;
}

void sc88_frame_prepare_init(sc88_frame_prepare *p, uint64_t total_frames)
{
    memset(p, 0, sizeof(*p));
    sc88_host_reset(&p->host);
    p->total_frames = total_frames;
}

int sc88_frame_prepare_begin(sc88_frame_prepare *p, sc88_prepared_frame *output,
                            uint8_t *parameters, uint32_t address)
{
    if (p->fault || p->active || p->frame >= p->total_frames || address < SC88_PARAMETER_BASE ||
        address >= SC88_PARAMETER_BASE + SC88_FRAME_SLOTS * SC88_PARAMETER_SLOT_BYTES ||
        (address - SC88_PARAMETER_BASE) % SC88_PARAMETER_SLOT_BYTES) return fail(p);
    p->output = output;
    memset(output->command, 0, sizeof(output->command));
    output->control_count = output->result_words = output->parameter_bytes = 0;
    p->parameter_address = address;
    p->irq_acknowledge = 0;
    p->active = 1;
    sc88_parameter_frame_begin(&p->packer, parameters, p->frame);
    return 0;
}

int sc88_frame_prepare_event(sc88_frame_prepare *p, const sc88_parameter_event *e)
{
    if (p->fault || !p->active || e->frame != p->frame) return fail(p);
    unsigned address = 0, value = 0;
    if (e->kind >= 1 && e->kind <= 4) {
        if (e->kind == 2 || e->kind == 3) address = e->payload[0] | (unsigned)e->payload[1] << 8;
        if (e->kind == 2) value = e->payload[2];
        if (e->kind == 4) value = e->payload[0];
        if (p->output->control_count == 256) return fail(p);
        p->output->controls[p->output->control_count++] = e->kind | (uint64_t)e->target << 8 |
                                                       (uint64_t)address << 16 | (uint64_t)value << 32;
        if (e->kind == 1) sc88_host_reset(&p->host);
        if (e->target == 1 && (e->kind == 2 || e->kind == 3)) {
            if (e->kind == 2) sc88_host_write(&p->host, (uint16_t)address, (uint8_t)value, &p->changes);
            else sc88_host_read(&p->host, (uint16_t)address, &p->changes);
            p->irq_acknowledge |= p->changes.irq_acknowledge;
            if (p->changes.count && sc88_parameter_frame_configs(&p->packer, &p->changes)) return fail(p);
        }
        return 0;
    }
    if (e->kind == 6 || e->kind == 7) {
        uint32_t selected[22];
        for (unsigned n = 0; n < e->bytes / 4; ++n) {
            const uint8_t *v = e->payload + n * 4;
            selected[n] = v[0] | (uint32_t)v[1] << 8 | (uint32_t)v[2] << 16 | (uint32_t)v[3] << 24;
        }
        if (sc88_parameter_frame_hook(&p->packer, e->voice, e->stage, e->mask, selected,
                                      e->kind == 7 ? e->payload[0] : -1)) return fail(p);
        return 0;
    }
    if (e->kind != 5) return fail(p);
    unsigned bytes = sc88_parameter_frame_finish(&p->packer);
    if (!bytes) return fail(p);
    sc88_prepared_frame *out = p->output;
    out->parameter_bytes = bytes;
    out->result_words = ((p->host.highest_voice & 63) + 1) * 4 + 64;
    out->command[0] = UINT64_C(0x53434431) | (uint64_t)p->irq_acknowledge << 32 |
                      (uint64_t)(p->frame + 1 == p->total_frames) << 33;
#ifdef SC88_PARAMETER_EFFECTS
    out->command[0] |= UINT64_C(1) << 34;
#endif
    out->command[1] = p->frame;
    out->command[2] = p->parameter_address | (uint64_t)bytes << 32;
    for (unsigned n = 0; n < 8; ++n) out->command[3] |= (uint64_t)p->host.wave_descriptors[n] << (n * 8);
    /* SC-88Pro: five physical 16-bit chips, no voice-bank address shift. */
    out->command[4] = (p->host.highest_voice & 63) | UINT64_C(31) << 8 | (uint64_t)p->host.irq_mask << 16;
    p->active = 0;
    ++p->frame;
    return 1;
}
