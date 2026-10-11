// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_frame_fifo (
    input logic clk,rst,
    input logic begin_valid,
    output logic begin_ready,
    input logic [63:0] begin_frame,
    input logic record_valid,
    output logic record_ready,
    input logic [63:0] record_data,
    input logic commit_valid,
    output logic commit_ready,
    input logic abort_frame,
    output logic out_valid,
    input logic out_ready,
    output logic [63:0] out_frame,out_data,
    output logic out_first,out_last,
    output logic [1:0] level,high_water,
    output logic empty
);
    (* ram_style="block" *) logic [63:0] memory [0:1023];
    logic [63:0] frame_ids [0:1];
    logic [8:0] lengths [0:1];
    logic [1:0] complete;
    logic write_bank,read_bank,reserved,read_valid;
    logic [8:0] write_index,read_index;
    logic [63:0] read_data;
    logic begin_take,pop,abort_take,read_enable;
    logic [1:0] next_level;

    assign begin_ready=!rst && !reserved && level<2;
    assign record_ready=!rst && reserved && write_index<320 && !abort_frame;
    assign commit_ready=!rst && reserved && write_index!=0 && !record_valid && !abort_frame;
    assign out_valid=!rst && read_valid;
    assign out_data=read_data;
    assign out_frame=frame_ids[read_bank];
    assign out_first=read_index==0;
    assign out_last=read_index+1'b1==lengths[read_bank];
    assign empty=complete==0;
    assign begin_take=begin_valid && begin_ready;
    assign pop=out_valid && out_ready && out_last;
    assign abort_take=abort_frame && reserved && !rst;
    assign next_level=level+2'(begin_take)-2'(pop)-2'(abort_take);
    assign read_enable=!rst && !read_valid && complete[read_bank];

    always_ff @(posedge clk) begin
        if(record_valid && record_ready) memory[{write_bank,write_index}]<=record_data;
        if(read_enable) read_data<=memory[{read_bank,read_index}];
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            complete<=0;write_bank<=0;read_bank<=0;reserved<=0;read_valid<=0;
            write_index<=0;read_index<=0;level<=0;high_water<=0;
            frame_ids[0]<=0;frame_ids[1]<=0;lengths[0]<=0;lengths[1]<=0;
        end else begin
            level<=next_level;
            if(next_level>high_water) high_water<=next_level;
            if(begin_take) begin
                reserved<=1;write_index<=0;frame_ids[write_bank]<=begin_frame;
            end
            if(record_valid && record_ready) write_index<=write_index+1'b1;
            if(commit_valid && commit_ready) begin
                complete[write_bank]<=1;lengths[write_bank]<=write_index;
                write_bank<=!write_bank;reserved<=0;
            end
            if(abort_take) begin reserved<=0;write_index<=0;end
            if(read_enable) read_valid<=1;
            if(out_valid && out_ready) begin
                read_valid<=0;
                if(out_last) begin complete[read_bank]<=0;read_bank<=!read_bank;read_index<=0;end
                else read_index<=read_index+1'b1;
            end
        end
    end
endmodule
