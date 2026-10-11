// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_mixer (
    input logic clk, rst,
    output logic ready,
    input logic frame_valid,
    output logic frame_ready,
    input logic [63:0] frame_id,
    input logic [5:0] frame_highest_voice,
    input logic voice_valid,
    output logic voice_ready,
    input logic [5:0] voice_index,
    input logic signed [23:0] voice_prior,
    input logic [63:0] voice_sends,
    output logic send_valid,
    input logic send_ready,
    output logic [63:0] send_frame,
    output logic [5:0] send_voice,
    output logic [1:0] send_index,
    output logic [7:0] send_slot,
    output logic [5:0] send_destination,
    output logic signed [24:0] send_contribution,
    output logic mix_valid,
    input logic mix_ready,
    output logic [5:0] mix_destination,
    output logic signed [23:0] mix_sample,
    output logic mix_seen,
    output logic mix_last,
    output logic done_valid,
    input logic done_ready
);
    typedef enum logic [3:0] {CLEAR,IDLE,VOICE,MULTIPLY,DEPOSIT,SEND,DUMP,DONE} state_t;
    state_t state;
    (* ram_style="distributed" *) logic signed [23:0] cells [0:127];
    logic [6:0] clear_address;
    logic bank;
    logic [63:0] seen, sends;
    logic [5:0] highest;
    logic signed [23:0] prior;
    logic signed [34:0] product, quotient;
    logic signed [25:0] sum;
    logic [15:0] send_config;
    logic signed [23:0] current;

    assign ready=state!=CLEAR && !rst;
    assign frame_ready=state==IDLE && !rst;
    assign voice_ready=state==VOICE && !rst;
    assign send_valid=state==SEND && !rst;
    assign mix_valid=state==DUMP && !rst;
    assign done_valid=state==DONE && !rst;
    assign send_config=sends[send_index*16+:16];
    assign send_slot={send_voice,2'b00}+(send_index==0 ? 8'd0 : send_index==3 ? 8'd3 : 8'd2);
    // Signed division toward zero must retain a negative product's discarded fraction.
    assign quotient=(product+(product[34] ? 35'sd511 : 35'sd0))>>>9;
    assign sum=$signed({{2{current[23]}},current})+$signed({quotient[24],quotient[24:0]});
    assign mix_sample=cells[{bank,mix_destination}];
    assign mix_seen=seen[mix_destination];
    assign mix_last=mix_destination==63;

    always_ff @(posedge clk) begin
        if(rst) begin
            state<=CLEAR; clear_address<=0; bank<=0; seen<=0;
            send_frame<=0; send_voice<=0; send_index<=0;
            send_destination<=0; send_contribution<=0; mix_destination<=0;
            prior<=0; sends<=0; highest<=0; product<=0; current<=0;
        end else case(state)
            CLEAR: begin
                cells[clear_address]<=0;
                if(clear_address==127) state<=IDLE;
                else clear_address<=clear_address+1'b1;
            end
            IDLE: if(frame_valid) begin
                send_frame<=frame_id; highest<=frame_highest_voice;
                bank<=frame_id[0]; seen<=0; state<=VOICE;
            end
            VOICE: if(voice_valid) begin
                send_voice<=voice_index; prior<=voice_prior; sends<=voice_sends;
                send_index<=0; state<=MULTIPLY;
            end
            MULTIPLY: begin
                product<=prior*$signed({1'b0,send_config[15:6]});
                current<=seen[send_config[5:0]] ? cells[{bank,send_config[5:0]}] : 24'sd0;
                send_destination<=send_config[5:0];
                state<=DEPOSIT;
            end
            DEPOSIT: begin
                send_contribution<=quotient[24:0];
                if(sum>26'sd8388607) cells[{bank,send_destination}]<=24'sh7fffff;
                else if(sum < -26'sd8388608) cells[{bank,send_destination}]<=24'sh800000;
                else cells[{bank,send_destination}]<=sum[23:0];
                seen[send_destination]<=1'b1;
                state<=SEND;
            end
            SEND: if(send_ready) begin
                if(send_index==3) begin
                    if(send_voice==highest) begin mix_destination<=0; state<=DUMP; end
                    else state<=VOICE;
                end else begin send_index<=send_index+1'b1; state<=MULTIPLY; end
            end
            DUMP: if(mix_ready) begin
                if(mix_destination==63) state<=DONE;
                else mix_destination<=mix_destination+1'b1;
            end
            DONE: if(done_ready) state<=IDLE;
            default: state<=CLEAR;
        endcase
    end
endmodule
