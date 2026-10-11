// SPDX-License-Identifier: GPL-3.0-only
#ifndef SC88_STORAGE_H
#define SC88_STORAGE_H
#include <stdint.h>
struct sc88_storage_stats {
    uint64_t read_bytes;
    uint32_t reads, max_read_us, faults;
    uint32_t sector_size, sectors;
    uint32_t xact_retries, max_xact_retries, xact_exhausted;
    uint8_t device;
};
extern struct sc88_storage_stats sc88_storage_stats;
int sc88_storage_init(void (*service_audio)(void));
void sc88_storage_poll(void);
uint64_t sc88_storage_time_us(void);
void sc88_usb_poll(void);
#endif
