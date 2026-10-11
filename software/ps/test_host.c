// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_codec.h"
#include "sc88_trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint16_t expected[][2]={{15,0},{6,0x77},{0,0x97},{1,0x97},{2,0x79},{3,0x79},{4,0x10},{5,0},{7,2},{8,0x18},{9,1},{6,0x67}};
static unsigned writes,delays;
static int failure=-1;
void test_player(const struct sc88_trace *trace);
static void require(int condition,const char *message) {
    if(!condition) {fprintf(stderr,"HOST_TEST_FAILURE %s\n",message);exit(1);}
}
int sc88_i2c_write(uint8_t address,const uint8_t *bytes,unsigned count) {
    require(address==0x1a && count==2 && writes<12,"I2C address/count");
    require(bytes[0]==((expected[writes][0]<<1)|(expected[writes][1]>>8)) && bytes[1]==(expected[writes][1]&255),"Codec sequence");
    if(writes>=10) require(delays==1,"VMID wait precedes ACTIVE/OUT");
    return (int)writes++==failure ? -77 : 0;
}
void sc88_delay_us(unsigned microseconds) {
    require(microseconds==75000 && writes==10 && delays==0,"VMID delay");++delays;
}
int main(int argc,char **argv) {
    require(argc==2,"trace path argument");
    require(sc88_codec_init()==0 && writes==12 && delays==1,"Codec success");
    for(failure=0;failure<12;++failure) {
        writes=delays=0;
        require(sc88_codec_init()==-77 && writes==(unsigned)failure+1,"I2C failure propagation");
    }
    FILE *file=fopen(argv[1],"rb");require(file!=NULL,"open trace");
    require(fseek(file,0,SEEK_END)==0,"seek trace");long length=ftell(file);require(length>=64,"trace size");rewind(file);
    uint8_t *data=malloc((size_t)length);require(data!=NULL,"trace memory");
    require(fread(data,1,(size_t)length,file)==(size_t)length,"read trace");fclose(file);
    struct sc88_trace trace;
    require(sc88_trace_open(data,(size_t)length,&trace)==0,"valid trace");
    struct sc88_trace_header original=*trace.header;
    struct sc88_trace_header *header=(void *)data;
    unsigned negatives=0;
    header->version=99;require(sc88_trace_open(data,(size_t)length,&trace)!=0,"bad version");*header=original;++negatives;
    header->voices=63;require(sc88_trace_open(data,(size_t)length,&trace)!=0,"bad voice count");*header=original;++negatives;
    header->bytes-=1;require(sc88_trace_open(data,(size_t)length,&trace)!=0,"truncated input");*header=original;++negatives;
    struct sc88_trace_block *block=(void *)(data+64),saved=*block;
    block->offset+=8;require(sc88_trace_open(data,(size_t)length,&trace)!=0,"unaligned block");*block=saved;++negatives;
    block->frames+=1;require(sc88_trace_open(data,(size_t)length,&trace)!=0,"frame mismatch");*block=saved;++negatives;
    block->first_frame+=1;require(sc88_trace_open(data,(size_t)length,&trace)!=0,"frame order");*block=saved;++negatives;
    uint64_t *command=(void *)(data+block->offset),word=*command;
    *command=0xf000000000000000ull;require(sc88_trace_open(data,(size_t)length,&trace)!=0,"unknown opcode");*command=word;++negatives;
    *command=51ull<<40;require(sc88_trace_open(data,(size_t)length,&trace)!=0,"bad state address");*command=word;++negatives;
    require(sc88_trace_open(data,(size_t)length,&trace)==0,"restored trace");
    test_player(&trace);
    printf("PS_HOST_PASS frames=%u blocks=%u codec_failures=12 trace_negatives=%u\n",header->frames,header->blocks,negatives);
    free(data);return 0;
}
