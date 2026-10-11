// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_board_synth #(parameter integer BLOCK_DMA=0);
    `include "vectors.svh"
    logic clk=0,audio_clk=0,rst=1,audio_reset=1,soft_reset=0,start=0,stop=0,pause=0;
    always #5 clk=~clk;
    always #40.690104 audio_clk=~audio_clk;
    wire [63:0] first_frame=FIRST_FRAME,descriptors=DESCRIPTORS;
    wire [5:0] highest_voice=VOICES-1,left_cell=LEFT_CELL,right_cell=RIGHT_CELL;
    wire [15:0] initial_irq_status=INITIAL_IRQ,irq_mask=IRQ_MASK;
    wire initial_irq_interrupt=INITIAL_INTERRUPT;
    wire [7:0] physical16=31;
    wire [31:0] bank_shifts=0;
    wire command_valid,command_ready,write_valid,write_ready,ready,ended,pause_ack,wave_idle;
    wire [63:0] command_data,write_data,published_frame;
    wire [13:0] fault;
    wire [31:0] completed,written,max_due_cycles,max_frame_cycles,cache_hits,cache_misses,axi_bursts,timeouts,overruns;
    wire [5:0] audio_level;
    wire bclk,lrclk,serial_data,mute_n,audio_accepted,audio_mute_n;
    wire signed [23:0] native_left,native_right;
    wire m_axi_arvalid,m_axi_rready,m_axi_arlock;
    logic m_axi_arready=0,m_axi_rvalid=0,m_axi_rlast=0;
    wire [31:0] m_axi_araddr;
    wire [5:0] m_axi_arid;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize,m_axi_arprot;
    wire [1:0] m_axi_arburst;
    wire [3:0] m_axi_arcache;
    logic [63:0] m_axi_rdata=0;
    wire [5:0] m_axi_rid=0;
    wire [1:0] m_axi_rresp=0;
    pcm_synth dut(.*);
    logic [63:0] commands[0:COMMAND_COUNT-1],records[0:RECORD_COUNT-1];
    logic [31:0] states[0:FRAME_COUNT*VOICES*51-1];
    logic [16:0] irqs[0:FRAME_COUNT-1];
    integer command_index=0,record_index=0,read_index=0,done_count=0,audio_count=0,wire_frames=0;
    integer cycles=0,fd,fields,expect_frame,expect_voice,expect_cs,expect_address,expect_byte;
    integer issued=0,responded=0,beat=0,gap=0;
    logic [31:0] queue[0:65535];
    integer earliest[0:65535];
    logic r_fire=0,feeding=0,pending_rom=0;
    `ifdef REAL_ROM
    byte unsigned real_rom[0:20971519];
    integer rom_fd,rom_size;
    `endif
    wire [7:0] dma_fault;
    wire dma_finished;
    if(BLOCK_DMA) begin: transport
        board_dma_fixture fixture(.clk,.rst,.run(feeding),.command_valid,.command_ready,.command_data,
            .write_valid,.write_ready,.write_data,.fault(dma_fault),.finished(dma_finished));
    end else begin: direct_stream
        assign command_valid=feeding && command_index<COMMAND_COUNT;
        assign command_data=command_index<COMMAND_COUNT ? commands[command_index] : 0;
        assign write_ready=cycles%19!=0;
        assign dma_fault=0;
        assign dma_finished=1;
    end
    function automatic [7:0] byte_for(input logic [31:0] offset);
        `ifdef REAL_ROM
        byte_for=real_rom[offset];
        `else
        byte_for=8'((offset*73+(offset>>7)*19+32'h35)^(offset>>13));
        `endif
    endfunction
    function automatic [31:0] state_word(input integer voice,input integer word);
        integer address;
        address=voice*8+word/8;
        case(word%8)
            0:state_word=dut.core.voice_core.storage.banks[0].words[address];
            1:state_word=dut.core.voice_core.storage.banks[1].words[address];
            2:state_word=dut.core.voice_core.storage.banks[2].words[address];
            3:state_word=dut.core.voice_core.storage.banks[3].words[address];
            4:state_word=dut.core.voice_core.storage.banks[4].words[address];
            5:state_word=dut.core.voice_core.storage.banks[5].words[address];
            6:state_word=dut.core.voice_core.storage.banks[6].words[address];
            7:state_word=dut.core.voice_core.storage.banks[7].words[address];
        endcase
    endfunction
    function automatic [23:0] pcm(input integer f,input integer cell_index);
        pcm=records[f*(VOICES*4+64)+VOICES*4+cell_index][23:0];
    endfunction
    always @(posedge clk) if(!rst) begin
        cycles=cycles+1;
        if(fault || dma_fault) $fatal(1,"BOARD_FAULT bits=%h DMA=%h frame=%d due_age=%d core_cycles=%d",fault,dma_fault,completed,dut.commands.age,dut.core.elapsed);
        if(command_valid && command_ready) begin
            if(command_data!==commands[command_index]) $fatal(1,"BOARD_COMMAND_DMA_ORDER");
            command_index<=command_index+1;
        end
        if(write_valid && write_ready) begin
            if(record_index>=RECORD_COUNT || write_data!==records[record_index])
                $fatal(1,"BOARD_RECORD_DIFFERENCE record=%d got=%h expected=%h",record_index,write_data,records[record_index]);
            record_index=record_index+1;
        end
        if(dut.done_valid && dut.done_ready) begin
            if(dut.done_frame!=FIRST_FRAME+done_count || {dut.done_irq_interrupt,dut.done_irq_status}!==irqs[done_count])
                $fatal(1,"BOARD_DONE_DIFFERENCE frame=%d",done_count);
            for(integer v=0;v<VOICES;v=v+1)
                for(integer w=0;w<51;w=w+1)
                    if(state_word(v,w)!==states[(done_count*VOICES+v)*51+w])
                        $fatal(1,"BOARD_STATE_DIFFERENCE frame=%d voice=%d word=%d",done_count,v,w);
            done_count=done_count+1;
        end
        if(dut.core.rom_rsp_valid && dut.core.rom_rsp_ready) begin
            if(!pending_rom || dut.core.rom_rsp_data!==8'(expect_byte)) $fatal(1,"BOARD_ROM_BYTE");
            pending_rom=0;
        end
        if(dut.core.rom_req_valid && dut.core.rom_req_ready) begin
            if(pending_rom || read_index>=READ_COUNT) $fatal(1,"BOARD_ROM_COUNT");
            fields=$fscanf(fd,"%d %d %d %d %d\n",expect_frame,expect_voice,expect_cs,expect_address,expect_byte);
            if(fields!=5 || dut.frame_id!=64'(expect_frame) || dut.core.active_voice+integer'(dut.core.rom_req_partner)!=expect_voice ||
               dut.core.rom_req_cs!==3'(expect_cs) || dut.core.rom_req_address!==24'(expect_address))
                $fatal(1,"BOARD_ROM_ADDRESS frame=%d read=%d",completed,read_index);
            pending_rom=1;read_index=read_index+1;
        end
        if(m_axi_arvalid && m_axi_arready) begin
            if(m_axi_araddr<32'h10000000 || m_axi_araddr>=32'h11400000 || m_axi_araddr[4:0]!=0 || m_axi_arlen!=3 || m_axi_arsize!=3 || m_axi_arid!=0)
                $fatal(1,"BOARD_AXI_ADDRESS");
            queue[issued]=m_axi_araddr;earliest[issued]=cycles+8;issued=issued+1;
        end
        r_fire=m_axi_rvalid && m_axi_rready;
    end
    always @(negedge clk) if(!rst) begin
        m_axi_arready=cycles%5!=0;
        if(r_fire) begin
            if(m_axi_rlast) begin responded=responded+1;beat=0;end
            else beat=beat+1;
            gap=beat%2;m_axi_rvalid=0;
        end
        if(!m_axi_rvalid) begin
            if(gap>0) gap=gap-1;
            else if(responded<issued && cycles>=earliest[responded]) begin
                m_axi_rvalid=1;m_axi_rlast=beat==3;
                for(integer lane=0;lane<8;lane=lane+1)
                    m_axi_rdata[lane*8+:8]=byte_for(queue[responded]-32'h10000000+32'(beat*8+lane));
            end
        end
    end
    always @(posedge audio_clk) begin
        #1;
        if(audio_accepted && !audio_reset) begin
            if(audio_count>=FRAME_COUNT || native_left!==pcm(audio_count,LEFT_CELL) || native_right!==pcm(audio_count,RIGHT_CELL))
                $fatal(1,"BOARD_NATIVE_PCM frame=%d",audio_count);
            audio_count=audio_count+1;
        end
    end
    integer slot_bit=31;
    logic previous_lr=1;
    logic [23:0] wire_expected;
    always @(posedge bclk) begin
        #1;
        if(lrclk!=previous_lr) slot_bit=0;
        else slot_bit=slot_bit+1;
        previous_lr=lrclk;
        if(mute_n) begin
            if(slot_bit<0 || slot_bit>31 || audio_count==0) $fatal(1,"BOARD_I2S_FRAME");
            wire_expected=pcm(audio_count-1,lrclk ? RIGHT_CELL : LEFT_CELL);
            if(slot_bit>=1 && slot_bit<=16) begin
                if(serial_data!==wire_expected[24-slot_bit]) $fatal(1,"BOARD_I2S_BIT frame=%d slot=%d",audio_count-1,slot_bit);
            end else if(serial_data!==0) $fatal(1,"BOARD_I2S_PADDING");
            if(lrclk && slot_bit==31) wire_frames=wire_frames+1;
        end
    end
    initial begin
        $readmemh("commands.hex",commands);$readmemh("records.hex",records);
        $readmemh("states.hex",states);$readmemh("irq.hex",irqs);
        `ifdef REAL_ROM
        rom_fd=$fopen("decoded-wave.bin","rb");if(!rom_fd) $fatal(1,"Missing decoded Wave ROM");
        rom_size=$fread(real_rom,rom_fd);$fclose(rom_fd);if(rom_size!=20971520) $fatal(1,"Decoded Wave ROM size");
        `endif
        fd=$fopen("reads.txt","r");if(fd==0) $fatal(1,"read observations missing");
        repeat(100) @(negedge clk);rst=0;audio_reset=0;
        wait(ready);@(negedge clk);start=1;
        @(negedge clk);start=0;feeding=1;
        wait(ended && written==FRAME_COUNT && wire_frames==FRAME_COUNT);
        repeat(7000) @(negedge clk);
        if(fault || dma_fault || !dma_finished || mute_n || audio_count!=FRAME_COUNT || record_index!=RECORD_COUNT || read_index!=READ_COUNT ||
           done_count!=FRAME_COUNT || command_index!=COMMAND_COUNT || pending_rom || issued!=responded)
            $fatal(1,"BOARD_FINAL_COUNTS");
        $display("BOARD_SYNTH_PASS frames=%0d records=%0d reads=%0d wire_frames=%0d max_core=%0d max_due=%0d",done_count,record_index,read_index,wire_frames,max_frame_cycles,max_due_cycles);
        $finish;
    end
    initial begin #(FRAME_COUNT*40000+2000000);$fatal(1,"BOARD_TIMEOUT frames=%d audio=%d",completed,audio_count);end
endmodule
