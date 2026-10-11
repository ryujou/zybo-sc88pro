// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_player.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t registers[0x140/4],slot_block[2],next_block,owner,pending;
static uint64_t result_words[2][5120],clock_us;
static unsigned serial,last_barrier,last_descriptor,last_invalidate[2],flushed_wave,flushed_commands,submitted,invalidations,capture_flush;
static int timed_out;
static const struct sc88_trace *input;
static int32_t *output;
static void require(int condition,const char *message) {
    if(!condition) {fprintf(stderr,"PLAYER_TEST_FAILURE %s\n",message);exit(1);}
}
uint32_t sc88_read32(unsigned offset) {
    if(offset==0) return 0x53433430;
    if(offset==8) return timed_out ? 0 : 1;
    if(offset==0x80) return owner;
    if(offset==0x10) return pending;
    return registers[offset/4];
}
void sc88_write32(unsigned offset,uint32_t value) {
    ++serial;
    if(offset==4 && value==4) {
        memset(registers,0,sizeof(registers));owner=0;pending=0;next_block=0;
        flushed_wave=flushed_commands=submitted=invalidations=capture_flush=0;
        return;
    }
    if(offset==0x10) {pending&=~value;return;}
    if(offset>=0x100 && (offset&31)==28) {
        const unsigned slot=(offset-0x100)/32,base=0x100+slot*32;
        if(value==2) {
            require(((owner>>(slot*2))&3)==3 && last_invalidate[slot]!=0,"CPU release before completed read");
            owner&=~(3u<<(slot*2));last_invalidate[slot]=0;
        } else {
            require(((owner>>(slot*2))&3)==0 && next_block<input->header->blocks,"overwrite DMA-owned slot");
            require(flushed_wave && flushed_commands && last_barrier>last_descriptor,"flush/barrier before doorbell");
            const struct sc88_trace_block *block=&input->blocks[next_block];
            require(slot==next_block%2 && registers[base/4]==SC88_COMMAND_BASE+block->offset && registers[(base+4)/4]==block->bytes,"command descriptor order");
            require(registers[(base+8)/4]==SC88_RESULT_BASE+slot*0x10000 && registers[(base+12)/4]==block->frames*(input->header->voices*4+64)*8,"result descriptor range");
            require(registers[(base+16)/4]==block->frames && registers[(base+20)/4]==(uint32_t)block->first_frame && value==(1|(block->last<<8)),"frame descriptor metadata");
            slot_block[slot]=next_block++;owner|=1u<<(slot*2);++submitted;
        }
        return;
    }
    registers[offset/4]=value;
    if(offset>=0x100) last_descriptor=serial;
}
void sc88_flush(uintptr_t address,size_t bytes) {
    ++serial;
    if(address==SC88_WAVE_BASE) {require(bytes==SC88_WAVE_BYTES,"Wave cache extent");flushed_wave=1;}
    else if(address==SC88_COMMAND_BASE) {require(bytes==input->header->bytes,"command cache extent");flushed_commands=1;}
    else {require(address==(uintptr_t)output && bytes==input->header->frames*8,"capture cache extent");++capture_flush;}
}
void sc88_invalidate(uintptr_t address,size_t bytes) {
    const unsigned slot=(unsigned)((address-SC88_RESULT_BASE)/0x10000);
    require(slot<2 && address==SC88_RESULT_BASE+slot*0x10000 && ((owner>>(slot*2))&3)==3,"invalidate only completed slot");
    require(bytes==input->blocks[slot_block[slot]].frames*(input->header->voices*4+64)*8,"invalidate complete records");
    last_invalidate[slot]=++serial;++invalidations;
}
void sc88_barrier(void) {last_barrier=++serial;}
uint64_t sc88_time_us(void) {clock_us+=600000;return clock_us;}
const uint64_t *sc88_result_words(unsigned slot) {
    require(last_invalidate[slot] && last_barrier>last_invalidate[slot],"invalidate/barrier before CPU reads");
    return result_words[slot];
}
static int32_t sample(unsigned frame,unsigned channel) {
    return channel ? -8388608+(int32_t)frame : 8388607-(int32_t)frame;
}
static void complete(unsigned slot) {
    require(((owner>>(slot*2))&3)==1,"complete queued slot");
    const struct sc88_trace_block *block=&input->blocks[slot_block[slot]];
    const unsigned voices=input->header->voices,stride=voices*4+64;
    for(unsigned frame=0;frame<block->frames;++frame) {
        const unsigned absolute=(unsigned)(block->first_frame-input->header->first_frame)+frame;
        result_words[slot][frame*stride+voices*4+(input->header->audio_route&63)]=(uint32_t)sample(absolute,0)&0xffffffu;
        result_words[slot][frame*stride+voices*4+((input->header->audio_route>>8)&63)]=(uint32_t)sample(absolute,1)&0xffffffu;
    }
    owner|=3u<<(slot*2);pending|=1u<<slot;
}
void test_player(const struct sc88_trace *trace) {
    struct sc88_player player;
    input=trace;output=calloc(trace->header->frames*2,sizeof(*output));require(output!=NULL,"capture allocation");
    require(sc88_player_prepare(&player,trace,output)==0 && submitted==(trace->header->blocks<2 ? 1u : 2u),"initial slot preload");
    sc88_player_start();require(registers[1]==1,"start doorbell");
    require(sc88_player_service(&player)==0 && invalidations==0,"never read active DMA output");
    unsigned services=0;
    while(player.completed_blocks<trace->header->blocks) {
        for(unsigned slot=0;slot<2;++slot) if(((owner>>(slot*2))&3)==1) complete(slot);
        const int result=sc88_player_service(&player);++services;
        require(result==(player.completed_blocks==trace->header->blocks ? 1 : 0),"service completion status");
    }
    require(submitted==trace->header->blocks && invalidations==trace->header->blocks && !owner && !pending && capture_flush==1,"all slots recycled once");
    for(unsigned frame=0;frame<trace->header->frames;++frame) for(unsigned channel=0;channel<2;++channel)
        require(output[frame*2+channel]==sample(frame,channel),"native signed24 capture order");
    require(sc88_player_prepare(&player,trace,output)==0,"fault setup");
    registers[0xc/4]=1;require(sc88_player_service(&player)==-4 && registers[1]==8 && invalidations==0,"fault stop without output read");
    timed_out=1;require(sc88_player_prepare(&player,trace,output)==-2,"ready timeout");timed_out=0;
    printf("PS_PLAYER_PASS frames=%u blocks=%u services=%u cache_order=1 fault_stop=1 timeout=1\n",trace->header->frames,trace->header->blocks,services);
    free(output);
}
