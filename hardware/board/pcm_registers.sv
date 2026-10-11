// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_registers (
    input logic clk,rst,
    input logic reg_valid,reg_write,
    input logic [11:0] reg_address,
    input logic [31:0] reg_wdata,
    input logic [3:0] reg_wstrb,
    output logic reg_ready,reg_error,
    output logic [31:0] reg_rdata,
    input logic ready,reset_busy,ended,finished,pause_ack,
    input logic [21:0] fault,
    input logic [31:0] completed,written,max_due_cycles,max_frame_cycles,cache_hits,cache_misses,axi_bursts,timeouts,overruns,
    input logic [5:0] audio_level,
    input logic [3:0] ownership,
    input logic [1:0] completion,
    input logic dma_idle,wave_idle,
    output logic start,pause,reset_request,stop_request,active,irq,
    output logic [63:0] descriptors,
    output logic [7:0] physical16,
    output logic [31:0] bank_shifts,
    output logic [15:0] initial_irq_status,irq_mask,
    output logic initial_irq_interrupt,
    output logic [5:0] highest_voice,left_cell,right_cell,
    output logic submit,submit_slot,
    output logic [31:0] command_address,command_bytes,result_address,result_bytes,
    output logic [4:0] frame_count,
    output logic [63:0] first_frame,
    output logic last_block,
    input logic submit_error,
    output logic acknowledge,ack_slot,
    input logic acknowledge_error
);
    logic [31:0] descriptor_words[0:1][0:6];
    logic [2:0] pending,irq_enable;
    logic mapped,writable,config_write,descriptor_access,accept,access_error;
    logic [31:0] read_data;
    wire slot=reg_address[5];
    wire [2:0] word_index=reg_address[4:2];
    assign descriptor_access=reg_address>=12'h100 && reg_address<12'h140;
    assign submit_slot=slot;
    assign ack_slot=slot;
    assign command_address=descriptor_words[slot][0];
    assign command_bytes=descriptor_words[slot][1];
    assign result_address=descriptor_words[slot][2];
    assign result_bytes=descriptor_words[slot][3];
    assign frame_count=descriptor_words[slot][4][4:0];
    assign first_frame={descriptor_words[slot][6],descriptor_words[slot][5]};
    assign last_block=reg_wdata[8];
    assign accept=reg_valid && reg_ready && reg_write && !reg_error;
    assign submit=accept && descriptor_access && word_index==7 && reg_wdata[0];
    assign acknowledge=accept && descriptor_access && word_index==7 && reg_wdata[1];
    assign irq=|(pending & irq_enable);
    always_comb begin
        read_data=0;mapped=1;writable=0;config_write=0;
        case(reg_address)
            12'h000: read_data=32'h53433430;
            12'h004: begin read_data={30'd0,pause,active};writable=1;end
            12'h008: read_data={25'd0,|fault,finished,ended,reset_busy,pause_ack,active,ready};
            12'h00c: read_data={10'd0,fault};
            12'h010: begin read_data={29'd0,pending};writable=1;end
            12'h014: begin read_data={29'd0,irq_enable};writable=1;end
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
            12'h040: begin read_data=descriptors[31:0];writable=1;config_write=1;end
            12'h044: begin read_data=descriptors[63:32];writable=1;config_write=1;end
            12'h048: begin read_data={24'd0,physical16};writable=1;config_write=1;end
            12'h04c: begin read_data=bank_shifts;writable=1;config_write=1;end
            12'h050: begin read_data={16'd0,initial_irq_status};writable=1;config_write=1;end
            12'h054: begin read_data={16'd0,irq_mask};writable=1;config_write=1;end
            12'h058: begin read_data={31'd0,initial_irq_interrupt};writable=1;config_write=1;end
            12'h05c: begin read_data={10'd0,highest_voice,2'd0,right_cell,2'd0,left_cell};writable=1;config_write=1;end
            12'h080: read_data={28'd0,ownership};
            12'h084: read_data={30'd0,wave_idle,dma_idle};
            default: begin
                if(descriptor_access) begin
                    writable=1;
                    if(word_index==7) read_data={30'd0,ownership[slot*2+:2]};
                    else read_data=descriptor_words[slot][word_index];
                end else mapped=0;
            end
        endcase
        access_error=!mapped || reg_address[1:0]!=0;
        if(reg_write) begin
            if(!writable || reg_wstrb!=4'hf || reset_busy) access_error=1;
            if(config_write && (active || ownership!=0)) access_error=1;
            case(reg_address)
                12'h004: if(reg_wdata[31:4]!=0 || (reg_wdata[0] && (active || !ready || ownership[1:0]!=1))) access_error=1;
                12'h010,12'h014: if(reg_wdata[31:3]!=0) access_error=1;
                12'h048: if(reg_wdata[31:8]!=0) access_error=1;
                12'h050,12'h054: if(reg_wdata[31:16]!=0) access_error=1;
                12'h058: if(reg_wdata[31:1]!=0) access_error=1;
                12'h05c: if((reg_wdata & 32'hffc0c0c0)!=0 ||
                              !(reg_wdata[21:16]==0 || reg_wdata[21:16]==7 || reg_wdata[21:16]==31 || reg_wdata[21:16]==63)) access_error=1;
                default: ;
            endcase
            if(descriptor_access) begin
                if(word_index==7) begin
                    if(reg_wdata==1 || reg_wdata==257) begin
                        if(submit_error || descriptor_words[slot][4][31:5]!=0) access_error=1;
                    end else if(reg_wdata==2) begin
                        if(acknowledge_error) access_error=1;
                    end else access_error=1;
                end else if(ownership[slot*2+:2]!=0) access_error=1;
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            reg_ready<=0;reg_error<=0;reg_rdata<=0;
            descriptors<=0;physical16<=31;bank_shifts<=0;initial_irq_status<=0;irq_mask<=0;initial_irq_interrupt<=0;
            highest_voice<=63;left_cell<=0;right_cell<=1;
            active<=0;pause<=0;start<=0;reset_request<=0;stop_request<=0;pending<=0;irq_enable<=0;
            for(integer s=0;s<2;s=s+1) for(integer w=0;w<7;w=w+1) descriptor_words[s][w]<=0;
        end else begin
            reg_ready<=0;
            if(reg_valid && !reg_ready) begin
                reg_ready<=1;reg_error<=access_error;reg_rdata<=read_data;
            end
            start<=0;reset_request<=0;stop_request<=0;
            pending<=(pending & ((accept && reg_address==12'h010) ? ~reg_wdata[2:0] : 3'b111)) | {|fault,completion};
            if(accept) begin
                case(reg_address)
                    12'h004: begin
                        pause<=reg_wdata[1];reset_request<=reg_wdata[2];stop_request<=reg_wdata[3];
                        if(reg_wdata[0]) begin start<=1;active<=1;end
                    end
                    12'h014: irq_enable<=reg_wdata[2:0];
                    12'h040: descriptors[31:0]<=reg_wdata;
                    12'h044: descriptors[63:32]<=reg_wdata;
                    12'h048: physical16<=reg_wdata[7:0];
                    12'h04c: bank_shifts<=reg_wdata;
                    12'h050: initial_irq_status<=reg_wdata[15:0];
                    12'h054: irq_mask<=reg_wdata[15:0];
                    12'h058: initial_irq_interrupt<=reg_wdata[0];
                    12'h05c: begin highest_voice<=reg_wdata[21:16];right_cell<=reg_wdata[13:8];left_cell<=reg_wdata[5:0];end
                    default: if(descriptor_access && word_index<7) descriptor_words[slot][word_index]<=reg_wdata;
                endcase
            end
        end
    end
endmodule
