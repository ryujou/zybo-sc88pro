/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_PARAMETER_AUDIO_H
#define SC88_PARAMETER_AUDIO_H
#include "sc88_frame_prepare.h"

/* Phase 4 direct mixer diagnostic, not the Phase 5 XP DSP/LSP effect path.
   Results are CPU-owned after DMA completion and Cache invalidation. */
int sc88_parameter_diagnostic(const sc88_prepared_frame *frame, const uint64_t *results,
                              unsigned result_words, unsigned left_cell, unsigned right_cell,
                              uint64_t *stereo);
int sc88_parameter_effects(const sc88_prepared_frame *frame, const uint64_t *results,
                          unsigned result_words, uint64_t *stereo);
#endif
