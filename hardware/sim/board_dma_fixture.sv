// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module board_dma_fixture (
    input logic clk,rst,run,
    output wire command_valid,
    input logic command_ready,
    output wire [63:0] command_data,
    input logic write_valid,
    output wire write_ready,
    input logic [63:0] write_data,
    output wire [7:0] fault,
    output wire finished
);
    `include "vectors.svh"
    wire stop=0;
    wire [5:0] highest_voice=VOICES-1;
    logic submit=0,submit_slot=0,acknowledge=0,ack_slot=0,last_block=0;
    logic [31:0] command_address=0,command_bytes=0,result_address=0,result_bytes=0;
    logic [4:0] frame_count=0;
    logic [63:0] first_frame=0;
    wire submit_error,acknowledge_error,idle,ready;
    wire [3:0] ownership;
    wire [1:0] completion;
    wire [63:0] session_first_frame;
    wire m_axi_arvalid,m_axi_rready,m_axi_awvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready;
    wire [31:0] m_axi_araddr,m_axi_awaddr;
    wire [7:0] m_axi_arlen,m_axi_awlen;
    wire [63:0] m_axi_wdata;
    logic m_axi_arready=0,m_axi_rvalid=0,m_axi_rlast=0,m_axi_awready=0,m_axi_wready=0,m_axi_bvalid=0;
    logic [63:0] m_axi_rdata=0;
    wire [5:0] m_axi_rid=0,m_axi_bid=0;
    wire [1:0] m_axi_rresp=0,m_axi_bresp=0;
    pcm_transport dut(.*);
    logic [63:0] packet[0:PACKET_WORDS-1],blocks[0:BLOCK_COUNT-1],expected[0:RECORD_COUNT-1];
    integer cycles=0,read_left=0,read_word=0,write_left=0,write_index=0,b_delay=0,completed_blocks=0;
    integer write_position=0;
    logic read_fire=0;
    always @(posedge clk) if(!rst) begin
        cycles=cycles+1;
        read_fire=m_axi_rvalid && m_axi_rready;
        if(m_axi_arvalid && m_axi_arready) begin
            if(read_left || m_axi_araddr[2:0] || m_axi_arlen>15 || m_axi_araddr[11:0]+(m_axi_arlen+1)*8>4096 ||
               m_axi_araddr<32'h02000000 || (m_axi_araddr-32'h02000000)/8+m_axi_arlen>=PACKET_WORDS)
                $fatal(1,"BOARD_DMA_AR");
            read_left=m_axi_arlen+1;read_word=(m_axi_araddr-32'h02000000)/8;
        end
        if(read_fire) begin read_left=read_left-1;read_word=read_word+1;end
        if(m_axi_awvalid && m_axi_awready) begin
            write_position=write_index%(16*(VOICES*4+64));
            if(write_left || m_axi_bvalid || b_delay || m_axi_awlen>15 || m_axi_awaddr[11:0]+(m_axi_awlen+1)*8>4096 ||
               m_axi_awaddr!==32'h06000000+((write_index/(16*(VOICES*4+64)))%2)*65536+write_position*8)
                $fatal(1,"BOARD_DMA_AW address=%h record=%d",m_axi_awaddr,write_index);
            write_left=m_axi_awlen+1;
        end
        if(m_axi_wvalid && m_axi_wready) begin
            if(write_left==0 || m_axi_wlast!==(write_left==1) || write_index>=RECORD_COUNT || m_axi_wdata!==expected[write_index])
                $fatal(1,"BOARD_DDR_RESULT record=%d",write_index);
            write_left=write_left-1;write_index=write_index+1;
            if(m_axi_wlast) b_delay=4;
        end
        if(m_axi_bvalid && m_axi_bready) m_axi_bvalid<=0;
        if(completion) begin
            if(completion!==(completed_blocks%2 ? 2'b10 : 2'b01)) $fatal(1,"BOARD_BLOCK_COMPLETION_ORDER");
            completed_blocks=completed_blocks+1;
        end
        if(finished && (write_index!=RECORD_COUNT || completed_blocks!=BLOCK_COUNT)) $fatal(1,"BOARD_DMA_FINISH");
    end
    always @(negedge clk) if(!rst) begin
        m_axi_arready=cycles%7>1;
        m_axi_awready=cycles%11<7;
        m_axi_wready=cycles%5!=0 && write_left>0;
        if(read_fire) m_axi_rvalid=0;
        if(!m_axi_rvalid && read_left>0 && cycles%3!=0) begin
            m_axi_rvalid=1;m_axi_rlast=read_left==1;m_axi_rdata=packet[read_word];
        end
        if(b_delay>0) begin
            b_delay=b_delay-1;
            if(b_delay==0) m_axi_bvalid=1;
        end
    end
    task descriptor(input integer index);
        @(negedge clk);submit_slot=1'(index%2);
        command_address=blocks[index][63:32];command_bytes=blocks[index][31:0];
        result_address=index%2 ? 32'h06010000 : 32'h06000000;
        frame_count=5'(FRAME_COUNT-index*16<16 ? FRAME_COUNT-index*16 : 16);
        result_bytes=frame_count*(VOICES*4+64)*8;first_frame=FIRST_FRAME+index*16;last_block=index==BLOCK_COUNT-1;
        #1;if(submit_error) $fatal(1,"BOARD_DESCRIPTOR_REJECTED block=%d",index);
        submit=1;@(negedge clk);submit=0;
    endtask
    initial begin
        $readmemh("packet.hex",packet);$readmemh("blocks.hex",blocks);$readmemh("records.hex",expected);
        wait(!rst);wait(ready);
        descriptor(0);if(BLOCK_COUNT>1) descriptor(1);
        for(integer b=2;b<BLOCK_COUNT;b=b+1) begin
            wait(ownership[(b%2)*2+:2]==3);
            repeat(13) @(negedge clk);
            ack_slot=1'(b%2);#1;if(acknowledge_error) $fatal(1,"BOARD_CPU_OWNERSHIP");
            acknowledge=1;@(negedge clk);acknowledge=0;
            descriptor(b);
        end
    end
endmodule
