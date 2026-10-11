// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_results (
    input logic clk,rst,start,stop,
    input logic [63:0] first_frame,
    input logic [5:0] highest_voice,left_cell,right_cell,
    input logic out_valid,
    output logic out_ready,
    input logic [63:0] out_frame,out_data,
    input logic out_first,out_last,
    output logic write_valid,
    input logic write_ready,
    output logic [63:0] write_data,
    output logic sample_valid,
    input logic sample_ready,
    output logic signed [23:0] sample_left,sample_right,
    output logic [63:0] sample_frame,
    output logic frame_written,
    output logic [31:0] frames,
    output logic error
);
    logic active;
    logic [63:0] expected_frame;
    logic [8:0] index,last_index;
    logic [5:0] left_select,right_select;
    logic signed [23:0] left_pending,right_pending;
    logic capacity,valid_boundary,take;
    assign capacity=!out_last || !sample_valid || sample_ready;
    assign write_valid=active && !stop && !error && out_valid && capacity;
    assign write_data=out_data;
    assign out_ready=active && !stop && !error && write_ready && capacity;
    assign take=out_valid && out_ready;
    assign valid_boundary=out_frame==expected_frame && out_first==(index==0) && out_last==(index==last_index);
    always_ff @(posedge clk) begin
        if(rst) begin
            active<=0;expected_frame<=0;index<=0;last_index<=0;
            left_select<=0;right_select<=0;left_pending<=0;right_pending<=0;
            sample_valid<=0;sample_left<=0;sample_right<=0;sample_frame<=0;
            frame_written<=0;frames<=0;error<=0;
        end else begin
            frame_written<=0;
            if(sample_valid && sample_ready) sample_valid<=0;
            if(start && !active && !error) begin
                active<=1;expected_frame<=first_frame;index<=0;
                last_index<=({3'd0,highest_voice}+1'b1)*4+63;
                left_select<=left_cell;right_select<=right_cell;
            end
            if(take) begin
                if(!valid_boundary) begin error<=1;sample_valid<=0;end
                else begin
                    if(out_data[63] && out_data[45:40]==left_select) left_pending<=out_data[23:0];
                    if(out_data[63] && out_data[45:40]==right_select) right_pending<=out_data[23:0];
                    if(out_last) begin
                        sample_left<=(out_data[45:40]==left_select) ? out_data[23:0] : left_pending;
                        sample_right<=(out_data[45:40]==right_select) ? out_data[23:0] : right_pending;
                        sample_frame<=expected_frame;sample_valid<=1;
                        expected_frame<=expected_frame+1'b1;index<=0;
                        frame_written<=1;frames<=frames+1'b1;
                    end else index<=index+1'b1;
                end
            end
            if(stop) begin active<=0;sample_valid<=0;end
        end
    end
endmodule
