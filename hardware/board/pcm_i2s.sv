// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_i2s (
    input logic clk,rst,enable,pause,
    input logic sample_valid,
    output logic sample_ready,
    input logic signed [23:0] sample_left,sample_right,
    output logic bclk,lrclk,serial_data,mute_n,
    output logic frame_tick,underrun,
    output logic signed [23:0] native_left,native_right
);
    logic [2:0] subcycle;
    logic [5:0] bit_index;
    wire [5:0] next_bit=bit_index+1'b1;
    logic active;
    wire boundary=subcycle==5 && bit_index==63;
    assign sample_ready=boundary && enable && !pause && !underrun && !rst;
    assign mute_n=active && !underrun && !rst;

    // Six MCLK cycles per BCLK and 64 BCLK cycles per stereo frame.
    // Slot bit zero carries the I2S delay; bits 1..16 carry signed24[23:8].
    always_ff @(posedge clk) begin
        if(rst) begin
            subcycle<=5;bit_index<=63;bclk<=0;lrclk<=1;serial_data<=0;
            frame_tick<=0;underrun<=0;active<=0;native_left<=0;native_right<=0;
        end else begin
            frame_tick<=0;
            if(subcycle==5) begin
                subcycle<=0;bit_index<=next_bit;bclk<=0;lrclk<=next_bit[5];
                serial_data<=0;
                if(next_bit==0) begin
                    frame_tick<=1;
                    active<=enable && !pause && !underrun && sample_valid;
                    if(enable && !pause && !underrun && sample_valid) begin
                        native_left<=sample_left;native_right<=sample_right;
                    end else begin native_left<=0;native_right<=0;end
                    if(enable && !pause && !underrun && !sample_valid) underrun<=1;
                end else if(next_bit>=1 && next_bit<=16)
                    serial_data<=native_left[24-next_bit];
                else if(next_bit>=33 && next_bit<=48)
                    serial_data<=native_right[56-next_bit];
            end else begin
                subcycle<=subcycle+1'b1;
                if(subcycle==2) bclk<=1;
            end
        end
    end
endmodule
