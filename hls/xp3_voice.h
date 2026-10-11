// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#ifdef XP3_NATIVE_TEST
#include "native_stream.h"
#else
#include <hls_stream.h>
#endif

// Caller-owned state RAM: two 51-word Voice slots; slot 1 is only a paired-filter context.
constexpr unsigned xp3VoiceWords=51, xp3StateWords=102, xp3ContextWords=40;
// command: bits 0..1=single/deferred-source/pair-filter, bits 8..13=physical Voice, bit 16=slot.
// context: clock lo/hi, IRQ status/mask/pending/accepted/blocked, 8 CS descriptors,
//          8 ROM sizes, 8 physical-width/bank-shift words. Remaining words are reserved zero.
// ROM request: CS in bits 24..26, CS-relative decoded byte address in bits 0..23.
void xp3_voice_step(uint32_t state[xp3StateWords], uint32_t context[xp3ContextWords],
                    uint32_t command, uint32_t audio[4],
                    hls::stream<uint32_t>& requests, hls::stream<uint8_t>& replies);
