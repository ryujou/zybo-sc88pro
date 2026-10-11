// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_trace.h"
#include <string.h>

int sc88_trace_open(const void *data,size_t bytes,struct sc88_trace *trace) {
    if(bytes<64 || bytes>32u*1024u*1024u || ((uintptr_t)data&7)) return -1;
    const struct sc88_trace_header *header=data;
    if(memcmp(header->magic,"SC4T",4) || header->version!=1 || header->bytes!=bytes || !header->frames) return -2;
    if(header->voices!=1 && header->voices!=8 && header->voices!=32 && header->voices!=64) return -3;
    if(header->irq_status>0xffff || header->irq_mask>0xffff || header->physical16>255 || header->interrupt>1 ||
       (header->audio_route&~0x3f3fu)) return -4;
    if(header->blocks!=(header->frames+15ull)/16 || 64ull+32ull*header->blocks>bytes) return -5;
    const struct sc88_trace_block *blocks=(const void *)((const uint8_t *)data+64);
    uint64_t next_frame=header->first_frame;
    uint32_t frame_count=0,previous_end=(64u+32u*header->blocks+63u)&~63u;
    for(uint32_t b=0;b<header->blocks;++b) {
        const struct sc88_trace_block *block=&blocks[b];
        unsigned is_last=b+1==header->blocks;
        if(block->offset!=previous_end || (block->offset&63) || !block->bytes || (block->bytes&7) ||
           (uint64_t)block->offset+block->bytes>bytes || !block->frames || block->frames>16 ||
           (!is_last && block->frames!=16) || block->first_frame!=next_frame || block->reserved || block->last!=is_last) return -6;
        const uint64_t *commands=(const void *)((const uint8_t *)data+block->offset);
        uint32_t frames=0,ends=0;
        for(uint32_t i=0;i<block->bytes/8;++i) {
            uint64_t command=commands[i];
            switch(command>>60) {
            case 0:
                if(ends || (command&0x0fffc0c000000000ull) || ((command>>40)&63)>=51 || ((command>>32)&63)>=header->voices) return -7;
                break;
            case 1:
                if(ends || (command&0x0fffffffffffffc0ull) || (command&63)!=header->voices-1) return -8;
                ++frames;
                break;
            case 2:
                if(ends || (command&0x0fffffffffffffffull)) return -9;
                break;
            case 3:
                if(!is_last || ends || (command&0x0fffffffffffffffull) || i+1!=block->bytes/8) return -10;
                ++ends;
                break;
            default:return -11;
            }
        }
        if(frames!=block->frames || ends!=is_last) return -12;
        frame_count+=frames;next_frame+=frames;
        previous_end=(block->offset+block->bytes+63u)&~63u;
    }
    if(frame_count!=header->frames || previous_end!=bytes) return -13;
    trace->data=data;trace->header=header;trace->blocks=blocks;
    return 0;
}
