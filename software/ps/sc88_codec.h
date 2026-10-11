// SPDX-License-Identifier: GPL-3.0-only
#ifndef SC88_CODEC_H
#define SC88_CODEC_H
#include <stdint.h>
int sc88_i2c_write(uint8_t address,const uint8_t *bytes,unsigned count);
void sc88_delay_us(unsigned microseconds);
int sc88_codec_init(void);
#endif
