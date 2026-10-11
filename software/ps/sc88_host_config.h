/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_HOST_CONFIG_H
#define SC88_HOST_CONFIG_H
#include <stdint.h>

/* Only host-owned latches are mirrored; no running Voice sample state. */
typedef struct {
    uint8_t high_bytes[8192];
    uint8_t released[64], shadow[64];
    uint16_t wide_latch, read_address, highest_voice, irq_mask;
    uint8_t window, wave_descriptors[8];
} sc88_host_config;

/* A release-mask read can emit two writes for each of all 64 Voices. */
typedef struct {
    uint64_t words[128];
    unsigned count;
    unsigned irq_acknowledge;
} sc88_host_changes;

void sc88_host_reset(sc88_host_config *host);
void sc88_host_write(sc88_host_config *host, uint16_t address, uint8_t value,
                     sc88_host_changes *changes);
void sc88_host_read(sc88_host_config *host, uint16_t address,
                    sc88_host_changes *changes);
#endif
