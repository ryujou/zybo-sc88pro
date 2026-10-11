// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_parameter_results (
    input logic clk,rst,start,stop,
    input logic [63:0] first_frame,
    input logic metadata_valid,
    output logic metadata_ready,
    input logic [63:0] metadata_frame,
    input logic [5:0] metadata_highest_voice,
    input logic metadata_last,
    input logic out_valid,
    output logic out_ready,
    input logic [63:0] out_frame,out_data,
    input logic out_first,out_last,
    output logic write_valid,
    input logic write_ready,
    output logic [63:0] write_data,
    output logic frame_written,ended,
    output logic [31:0] frames,
    output logic [2:0] level,
    output logic error
);
    logic active,closed;
    logic [63:0] next_metadata,expected_frame;
    logic [8:0] index,last_index;
    logic [1:0] head,tail;
    logic [5:0] highest [0:3];
    logic last [0:3];
    wire boundary=out_frame==expected_frame && out_first==(index==0) && out_last==(index==last_index);
    wire push=metadata_valid && metadata_ready;
    wire take=out_valid && out_ready;
    wire pop=take && out_last;
    assign last_index=({3'd0,highest[head]}+1'b1)*4+63;
    assign metadata_ready=active && !closed && !stop && !error && level<4;
    assign write_valid=active && !stop && !error && level!=0 && out_valid && boundary;
    assign out_ready=active && !stop && !error && level!=0 && write_ready && boundary;
    assign write_data=out_data;
    always_ff @(posedge clk) begin
        if(rst) begin
            active<=0;closed<=0;next_metadata<=0;expected_frame<=0;index<=0;head<=0;tail<=0;
            frames<=0;level<=0;error<=0;frame_written<=0;ended<=0;
            for(integer i=0;i<4;i=i+1) begin highest[i]<=0;last[i]<=0;end
        end else begin
            frame_written<=0;
            if(start && !active && !closed && !error) begin
                active<=1;next_metadata<=first_frame;expected_frame<=first_frame;
            end
            if(push) begin
                if(metadata_frame!=next_metadata) error<=1;
                else begin
                    highest[tail]<=metadata_highest_voice;last[tail]<=metadata_last;tail<=tail+1'b1;
                    next_metadata<=next_metadata+1'b1;
                    if(metadata_last) closed<=1;
                end
            end
            case({push,pop})
                2'b10:level<=level+1'b1;
                2'b01:level<=level-1'b1;
                default:;
            endcase
            if(active && !stop && !error && level!=0 && out_valid && !boundary) error<=1;
            if(take) begin
                if(out_last) begin
                    head<=head+1'b1;index<=0;expected_frame<=expected_frame+1'b1;
                    frames<=frames+1'b1;frame_written<=1;
                    if(last[head]) begin ended<=1;active<=0;end
                end else index<=index+1'b1;
            end
            if(stop) begin active<=0;closed<=1;end
        end
    end
endmodule
