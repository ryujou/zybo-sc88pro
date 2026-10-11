// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_player.h"

static void submit_block(struct sc88_player *player,unsigned slot)
{
    const uint32_t index=player->next_block++;
    const struct sc88_trace_block *block=&player->trace->blocks[index];
    const unsigned base=0x100+slot*32;
    player->slot_block[slot]=index;
    sc88_write32(base,SC88_COMMAND_BASE+block->offset);
    sc88_write32(base+4,block->bytes);
    sc88_write32(base+8,SC88_RESULT_BASE+slot*0x10000);
    sc88_write32(base+12,block->frames*(player->trace->header->voices*4+64)*8);
    sc88_write32(base+16,block->frames);
    sc88_write32(base+20,(uint32_t)block->first_frame);
    sc88_write32(base+24,(uint32_t)(block->first_frame>>32));
    sc88_barrier();
    sc88_write32(base+28,1|(block->last<<8));
}

int sc88_player_prepare(struct sc88_player *player,const struct sc88_trace *trace,int32_t *capture)
{
    const struct sc88_trace_header *header=trace->header;
    if(header->frames>SC88_CAPTURE_BYTES/8) return -1;
    *player=(struct sc88_player){.trace=trace,.capture=capture,.slot_block={UINT32_MAX,UINT32_MAX}};
    sc88_write32(4,4);
    const uint64_t started=sc88_time_us();
    while(!(sc88_read32(8)&1)) if(sc88_time_us()-started>1000000) return -2;
    if(sc88_read32(0)!=0x53433430u) return -3;
    sc88_write32(0x40,(uint32_t)header->descriptors);
    sc88_write32(0x44,(uint32_t)(header->descriptors>>32));
    sc88_write32(0x48,header->physical16);
    sc88_write32(0x4c,header->bank_shifts);
    sc88_write32(0x50,header->irq_status);
    sc88_write32(0x54,header->irq_mask);
    sc88_write32(0x58,header->interrupt);
    sc88_write32(0x5c,((header->voices-1)<<16)|header->audio_route);
    sc88_flush(SC88_WAVE_BASE,SC88_WAVE_BYTES);
    sc88_flush(SC88_COMMAND_BASE,header->bytes);
    sc88_barrier();
    sc88_write32(0x10,7);
    sc88_write32(0x14,7);
    submit_block(player,0);
    if(player->next_block<header->blocks) submit_block(player,1);
    return 0;
}

void sc88_player_start(void)
{
    sc88_barrier();
    sc88_write32(4,1);
}

static int32_t signed24(uint64_t value)
{
    const uint32_t bits=(uint32_t)value&0xffffffu;
    return (int32_t)(bits^0x800000u)-0x800000;
}

int sc88_player_service(struct sc88_player *player)
{
    if(sc88_read32(0xc)) { sc88_write32(4,8);return -4; }
    const uint32_t pending=sc88_read32(0x10);
    // A slot may complete while the CPU is servicing the other slot. Process original frame order.
    for(unsigned count=0;count<2;++count)
    {
        const unsigned slot=player->completed_blocks&1;
        if(((sc88_read32(0x80)>>(slot*2))&3)!=3) break;
        const uint32_t index=player->slot_block[slot];
        if(index!=player->completed_blocks) return -5;
        const struct sc88_trace_block *block=&player->trace->blocks[index];
        const unsigned stride=player->trace->header->voices*4+64;
        const unsigned left=player->trace->header->audio_route&63;
        const unsigned right=(player->trace->header->audio_route>>8)&63;
        sc88_barrier();
        sc88_invalidate(SC88_RESULT_BASE+slot*0x10000,block->frames*stride*8);
        sc88_barrier();
        const uint64_t *words=sc88_result_words(slot);
        for(unsigned frame=0;frame<block->frames;++frame)
        {
            const unsigned mix=frame*stride+player->trace->header->voices*4;
            player->capture[player->captured_frames*2]=signed24(words[mix+left]);
            player->capture[player->captured_frames*2+1]=signed24(words[mix+right]);
            ++player->captured_frames;
        }
        sc88_barrier();
        sc88_write32(0x100+slot*32+28,2);
        sc88_write32(0x10,1u<<slot);
        ++player->completed_blocks;
        player->slot_block[slot]=UINT32_MAX;
        if(player->next_block<player->trace->header->blocks) submit_block(player,slot);
    }
    if(pending&4) return -4;
    if(player->completed_blocks==player->trace->header->blocks)
    {
        sc88_flush((uintptr_t)player->capture,player->captured_frames*8);
        sc88_barrier();
        sc88_write32(0x14,0);
        return 1;
    }
    return 0;
}
