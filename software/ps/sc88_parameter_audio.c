/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_parameter_audio.h"

static int sample(uint64_t word, unsigned cell, uint32_t *value)
{
    const uint64_t payload = (UINT64_C(1) << 62) | UINT64_C(0x1ffffff);
    if ((word & ~payload) != ((UINT64_C(1) << 63) | (uint64_t)cell << 40) ||
        ((word >> 24) & 1) != ((word >> 23) & 1)) return -1;
    uint32_t bits = (uint32_t)word & 0xffffffu;
    *value = bits & 0x800000u ? bits | 0xff000000u : bits;
    return 0;
}

int sc88_parameter_diagnostic(const sc88_prepared_frame *frame, const uint64_t *results,
                              unsigned result_words, unsigned left_cell, unsigned right_cell,
                              uint64_t *stereo)
{
    unsigned sends = ((unsigned)frame->command[4] & 63u) * 4 + 4;
    if (result_words != sends + 64 || result_words != frame->result_words || left_cell > 63 || right_cell > 63)
        return -1;
    uint32_t left, right;
    if (sample(results[sends + left_cell], left_cell, &left) ||
        sample(results[sends + right_cell], right_cell, &right)) return -1;
    *stereo = left | (uint64_t)right << 32;
    return 0;
}
