// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_codec.h"

static int write_register(unsigned reg,unsigned value) {
    const uint8_t bytes[2]={(uint8_t)((reg<<1)|(value>>8)),(uint8_t)value};
    return sc88_i2c_write(0x1a,bytes,2);
}

int sc88_codec_init(void) {
    static const uint16_t setup[][2]={
        {15,0},{6,0x77},{0,0x97},{1,0x97},{2,0x79},{3,0x79},
        {4,0x10},{5,0},{7,2},{8,0x18}
    };
    for(unsigned i=0;i<sizeof(setup)/sizeof(setup[0]);++i) {
        int status=write_register(setup[i][0],setup[i][1]);
        if(status) return status;
    }
    // Keep OUT powered down while the board's 10 uF VMID capacitor charges.
    sc88_delay_us(75000);
    int status=write_register(9,1);
    if(status) return status;
    return write_register(6,0x67);
}
