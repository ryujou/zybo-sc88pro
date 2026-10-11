// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_codec.h"
#include "sc88_player.h"
#include "xparameters.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xiicps.h"
#include "xscugic.h"
#include "xtime_l.h"
#include "sleep.h"

#define PL_IRQ 61u
static XIicPs i2c;
static XScuGic interrupt_controller;
static volatile unsigned block_interrupt;
volatile struct {
    uint32_t magic,state,frames,blocks,fault,max_due_cycles,max_core_cycles,capture_base;
} sc88_status;

uint32_t sc88_read32(unsigned offset) {return Xil_In32(SC88_CONTROL_BASE+offset);}
void sc88_write32(unsigned offset,uint32_t value) {Xil_Out32(SC88_CONTROL_BASE+offset,value);}
void sc88_flush(uintptr_t address,size_t bytes) {Xil_DCacheFlushRange((INTPTR)address,(u32)bytes);}
void sc88_invalidate(uintptr_t address,size_t bytes) {Xil_DCacheInvalidateRange((INTPTR)address,(u32)bytes);}
void sc88_barrier(void) {__asm__ volatile("dsb sy" ::: "memory");}
uint64_t sc88_time_us(void) {
    XTime time;XTime_GetTime(&time);
    return (uint64_t)time*1000000u/COUNTS_PER_SECOND;
}
const uint64_t *sc88_result_words(unsigned slot) {return (const uint64_t *)(SC88_RESULT_BASE+slot*0x10000u);}
void sc88_delay_us(unsigned microseconds) {usleep(microseconds);}
int sc88_i2c_write(uint8_t address,const uint8_t *bytes,unsigned count) {
    const int status=XIicPs_MasterSendPolled(&i2c,(u8 *)bytes,(s32)count,address);
    if(status!=XST_SUCCESS) return status;
    const uint64_t started=sc88_time_us();
    while(XIicPs_BusIsBusy(&i2c)) if(sc88_time_us()-started>100000) return -1;
    return 0;
}
static void block_irq(void *context) {
    (void)context;
    XScuGic_Disable(&interrupt_controller,PL_IRQ);
    block_interrupt=1;
}
static int initialize_peripherals(void) {
    XIicPs_Config *i2c_config=XIicPs_LookupConfig(XPAR_XIICPS_0_DEVICE_ID);
    if(!i2c_config || XIicPs_CfgInitialize(&i2c,i2c_config,i2c_config->BaseAddress)!=XST_SUCCESS) return -1;
    if(XIicPs_SetSClk(&i2c,100000)!=XST_SUCCESS) return -1;
    XScuGic_Config *gic_config=XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if(!gic_config || XScuGic_CfgInitialize(&interrupt_controller,gic_config,gic_config->CpuBaseAddress)!=XST_SUCCESS) return -2;
    if(XScuGic_Connect(&interrupt_controller,PL_IRQ,block_irq,NULL)!=XST_SUCCESS) return -3;
    XScuGic_SetPriorityTriggerType(&interrupt_controller,PL_IRQ,0xa0,1);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,(Xil_ExceptionHandler)XScuGic_InterruptHandler,&interrupt_controller);
    Xil_ExceptionEnable();
    return sc88_codec_init();
}
static int fail(int code) {
    sc88_write32(0x14,0);sc88_write32(4,8);
    sc88_status.state=3;sc88_status.fault=sc88_read32(0xc);
    sc88_flush((uintptr_t)&sc88_status,sizeof(sc88_status));sc88_barrier();
    xil_printf("SC88_ERROR code=%d fault=%08x\r\n",code,sc88_status.fault);
    return code;
}
int main(void) {
    Xil_ICacheEnable();Xil_DCacheEnable();
    sc88_status.magic=0x53433453;sc88_status.state=1;sc88_status.capture_base=SC88_CAPTURE_BASE;
    xil_printf("SC88_PHASE4_DIAGNOSTIC signed24 32000Hz; selected mixer cells\r\n");
    const struct sc88_trace_header *header=(const struct sc88_trace_header *)SC88_COMMAND_BASE;
    struct sc88_trace trace;
    if(sc88_trace_open(header,header->bytes,&trace)!=0) return fail(-10);
    int status=initialize_peripherals();if(status) return fail(status);
    struct sc88_player player;
    status=sc88_player_prepare(&player,&trace,(int32_t *)SC88_CAPTURE_BASE);if(status) return fail(status);
    XScuGic_Enable(&interrupt_controller,PL_IRQ);
    uint64_t last_progress=sc88_time_us();
    sc88_player_start();
    for(;;) {
        if(block_interrupt) {
            block_interrupt=0;
            status=sc88_player_service(&player);
            if(status<0) return fail(status);
            sc88_status.frames=player.captured_frames;sc88_status.blocks=player.completed_blocks;
            last_progress=sc88_time_us();
            if(status==1) break;
            XScuGic_Enable(&interrupt_controller,PL_IRQ);
        }
        if(sc88_time_us()-last_progress>1000000) return fail(-11);
    }
    sc88_status.max_due_cycles=sc88_read32(0x1c);sc88_status.max_core_cycles=sc88_read32(0x20);sc88_status.state=2;
    sc88_flush((uintptr_t)&sc88_status,sizeof(sc88_status));sc88_barrier();
    xil_printf("SC88_CAPTURE_COMPLETE frames=%u blocks=%u max_due=%u max_core=%u capture=%08x\r\n",
        sc88_status.frames,sc88_status.blocks,sc88_status.max_due_cycles,sc88_status.max_core_cycles,SC88_CAPTURE_BASE);
    for(;;) __asm__ volatile("wfi");
}
