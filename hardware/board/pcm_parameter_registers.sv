// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_parameter_registers (
    input logic clk,rst,
    input logic reg_valid,reg_write,
    input logic [11:0] reg_address,
    input logic [31:0] reg_wdata,
    input logic [3:0] reg_wstrb,
    output logic reg_ready,reg_error,
    output logic [31:0] reg_rdata,
    input logic ready,reset_busy,ended,finished,pause_ack,
    input logic [25:0] fault,
    input logic [31:0] completed,written,max_due_cycles,max_frame_cycles,cache_hits,cache_misses,axi_bursts,timeouts,overruns,
    input logic [5:0] audio_level,
    input logic [3:0] ownership,
    input logic [1:0] completion,
    input logic dma_idle,wave_idle,audio_idle,
    input logic [3:0] audio_ownership,
    input logic [1:0] audio_completion,
    input logic audio_finished,
    input logic [31:0] audio_frames,parameter_bursts,parameter_configs,parameter_packets,parameter_noops,
    output logic start,audio_start,pause,reset_request,stop_request,active,audio_active,irq,
    output logic submit,submit_slot,
    output logic [31:0] command_address,command_bytes,result_address,result_bytes,
    output logic [4:0] frame_count,
    output logic [63:0] first_frame,
    output logic last_block,
    input logic submit_error,
    output logic acknowledge,ack_slot,
    input logic acknowledge_error,
    output logic audio_submit,audio_submit_slot,audio_acknowledge,audio_ack_slot,
    output logic [31:0] audio_address,
    output logic [4:0] audio_frame_count,
    output logic [63:0] audio_first_frame,
    output logic audio_last_block,
    input logic audio_submit_error,audio_acknowledge_error
);
    (* ram_style="block" *) logic [31:0] descriptor_memory[0:31];
    logic [31:0] descriptor_latch[0:6];
    typedef enum logic [2:0] {CLEAR,IDLE,LOAD,REPLY,WAIT_RELEASE} access_state_t;
    access_state_t access_state;
    logic [4:0] clear_address,memory_address;
    logic [2:0] load_index;
    logic [4:0] pending,irq_enable;
    logic mapped,writable,descriptor_access,audio_access,accept,access_error;
    logic [31:0] read_data,descriptor_read;
    wire slot=reg_address[5];
    wire [1:0] descriptor_index={audio_access,slot};
    wire [2:0] word_index=reg_address[4:2];
    wire descriptor_commit=descriptor_access && reg_write && word_index==7 && (reg_wdata==1 || reg_wdata==257);
    // A fault may latch during a CPU descriptor write. Acknowledge that write
    // without changing ownership; SLVERR would trap the ARM before it can stop.
    wire fault_suppressed=|fault && (descriptor_access ||
        (reg_address==12'h004 && (reg_wdata[0] || reg_wdata[4])));
    wire memory_write=!rst && (access_state==CLEAR || (accept && descriptor_access && word_index<7));
    wire [4:0] memory_write_address=access_state==CLEAR ? clear_address : {descriptor_index,word_index};
    wire [31:0] memory_write_data=access_state==CLEAR ? 32'd0 : reg_wdata;
    assign descriptor_access=(reg_address>=12'h100 && reg_address<12'h140) || audio_access;
    assign audio_access=reg_address>=12'h180 && reg_address<12'h1c0;
    assign submit_slot=slot;
    assign ack_slot=slot;
    assign command_address=descriptor_latch[0];
    assign command_bytes=descriptor_latch[1];
    assign result_address=descriptor_latch[2];
    assign result_bytes=descriptor_latch[3];
    assign frame_count=descriptor_latch[4][4:0];
    assign first_frame={descriptor_latch[6],descriptor_latch[5]};
    assign last_block=reg_wdata[8];
    assign accept=reg_valid && reg_ready && reg_write && !reg_error && !fault_suppressed;
    assign submit=accept && !audio_access && descriptor_access && word_index==7 && reg_wdata[0];
    assign acknowledge=accept && !audio_access && descriptor_access && word_index==7 && reg_wdata[1];
    assign audio_submit=accept && audio_access && word_index==7 && reg_wdata[0];
    assign audio_acknowledge=accept && audio_access && word_index==7 && reg_wdata[1];
    assign audio_submit_slot=slot;
    assign audio_ack_slot=slot;
    assign audio_address=descriptor_latch[0];
    assign audio_frame_count=descriptor_latch[4][4:0];
    assign audio_first_frame={descriptor_latch[6],descriptor_latch[5]};
    assign audio_last_block=reg_wdata[8];
    assign irq=|(pending & irq_enable);
    // Serialized descriptor reads trade a few MMIO cycles for BRAM instead of wide FF muxes.
    always_comb begin
        memory_address={descriptor_index,word_index};
        if(access_state==IDLE && descriptor_commit) memory_address={descriptor_index,3'd0};
        if(access_state==LOAD) memory_address={descriptor_index,3'(load_index+1)};
    end
    always_ff @(posedge clk) begin
        descriptor_read<=descriptor_memory[memory_address];
        if(memory_write) descriptor_memory[memory_write_address]<=memory_write_data;
    end
    always_comb begin
        read_data=0;mapped=1;writable=0;
        case(reg_address)
            12'h000: read_data=32'h53435034;
            12'h004: begin read_data={27'd0,audio_active,2'd0,pause,active};writable=1;end
            12'h008: read_data={24'd0,audio_active,|fault,finished,ended,reset_busy,pause_ack,active,ready};
            12'h00c: read_data={6'd0,fault};
            12'h010: begin read_data={27'd0,pending};writable=1;end
            12'h014: begin read_data={27'd0,irq_enable};writable=1;end
            12'h018: read_data=completed;
            12'h01c: read_data=max_due_cycles;
            12'h020: read_data=max_frame_cycles;
            12'h024: read_data=written;
            12'h028: read_data=cache_hits;
            12'h02c: read_data=cache_misses;
            12'h030: read_data=axi_bursts;
            12'h034: read_data=timeouts;
            12'h038: read_data=overruns;
            12'h03c: read_data={26'd0,audio_level};
            12'h080: read_data={28'd0,ownership};
            12'h084: read_data={29'd0,audio_idle,wave_idle,dma_idle};
            12'h088: read_data={28'd0,audio_ownership};
            12'h08c: read_data={31'd0,audio_finished};
            12'h090: read_data=audio_frames;
            12'h0a0: read_data=parameter_bursts;
            12'h0a4: read_data=parameter_configs;
            12'h0a8: read_data=parameter_packets;
            12'h0ac: read_data=parameter_noops;
            default: begin
                if(descriptor_access) begin
                    writable=1;
                    if(word_index==7) read_data={30'd0,(audio_access ? audio_ownership[slot*2+:2] : ownership[slot*2+:2])};
                    else read_data=descriptor_read;
                end else mapped=0;
            end
        endcase
        access_error=!mapped || reg_address[1:0]!=0;
        if(reg_write) begin
            if(!writable || reg_wstrb!=4'hf || reset_busy) access_error=1;
            if(!fault_suppressed) begin
            case(reg_address)
                12'h004: begin
                    if(reg_wdata[31:5]!=0 || (reg_wdata[0] && (active || !ready || ownership[1:0]!=1 || |fault))) access_error=1;
                    if(reg_wdata[4] && (!active || audio_active || |fault ||
                       !(audio_level>=32 || (audio_finished && audio_level!=0)))) access_error=1;
                end
                12'h010,12'h014: if(reg_wdata[31:5]!=0) access_error=1;
                default: ;
            endcase
            if(descriptor_access) begin
                if(word_index==7) begin
                    if(reg_wdata==1 || reg_wdata==257) begin
                        if((audio_access ? audio_submit_error : submit_error) || |fault || descriptor_latch[4][31:5]!=0) access_error=1;
                        if(audio_access && (descriptor_latch[1]!={24'd0,audio_frame_count,3'd0} ||
                           descriptor_latch[2]!=0 || descriptor_latch[3]!=0)) access_error=1;
                    end else if(reg_wdata==2) begin
                        if(audio_access ? audio_acknowledge_error : acknowledge_error) access_error=1;
                    end else access_error=1;
                end else if((audio_access ? audio_ownership[slot*2+:2] : ownership[slot*2+:2])!=0) access_error=1;
            end
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            reg_ready<=0;reg_error<=0;reg_rdata<=0;
            access_state<=CLEAR;clear_address<=0;load_index<=0;
            for(integer w=0;w<7;w=w+1) descriptor_latch[w]<=0;
            active<=0;audio_active<=0;pause<=0;start<=0;audio_start<=0;reset_request<=0;stop_request<=0;pending<=0;irq_enable<=0;
        end else begin
            reg_ready<=0;
            case(access_state)
                CLEAR: begin
                    clear_address<=clear_address+1;
                    if(clear_address==31) access_state<=IDLE;
                end
                IDLE: if(reg_valid) begin
                    load_index<=0;
                    access_state<=descriptor_commit ? LOAD : REPLY;
                end
                LOAD: begin
                    descriptor_latch[load_index]<=descriptor_read;
                    load_index<=load_index+1;
                    if(load_index==6) access_state<=REPLY;
                end
                REPLY: begin
                    reg_ready<=1;reg_error<=access_error;reg_rdata<=read_data;
                    access_state<=WAIT_RELEASE;
                end
                WAIT_RELEASE: if(!reg_valid) access_state<=IDLE;
                default: access_state<=CLEAR;
            endcase
            start<=0;audio_start<=0;reset_request<=0;stop_request<=0;
            pending<=(pending & ((accept && reg_address==12'h010) ? ~reg_wdata[4:0] : 5'b11111)) | {|fault,audio_completion,completion};
            if(accept) begin
                case(reg_address)
                    12'h004: begin
                        pause<=reg_wdata[1];reset_request<=reg_wdata[2];stop_request<=reg_wdata[3];
                        if(reg_wdata[0]) begin start<=1;active<=1;end
                        if(reg_wdata[4]) begin audio_start<=1;audio_active<=1;end
                    end
                    12'h014: irq_enable<=reg_wdata[4:0];
                    default: ;
                endcase
            end
        end
    end
endmodule
