// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module xp3_control_math #(parameter TABLE_FILE="xp3_pitch.mem") (
    input logic clk, rst, in_valid,
    output logic in_ready,
    input logic combine_amp,
    input logic [17:0] pitch, amp, amp_mod,
    input logic sum_mode,
    output logic out_valid,
    input logic out_ready,
    output logic [19:0] result
);
    typedef enum logic [1:0] {IDLE,MULTIPLY,FINISH,DONE} state_t;
    state_t state;
    logic [15:0] pitch_table[0:255];
    logic [15:0] mantissa_a,mantissa_b,multiply_a;
    logic [13:0] multiply_b;
    logic [17:0] amp_reg,mod_reg;
    logic [5:0] fraction;
    logic [3:0] octave;
    logic combining,summing,zero_pitch;
    logic [29:0] product_a;
    logic [21:0] product_b;
    logic [20:0] combined;
    logic [21:0] pitch_sum;
    initial $readmemh(TABLE_FILE,pitch_table);
    always_comb begin
        in_ready=state==IDLE && !rst;
        out_valid=state==DONE && !rst;
        multiply_a=combining ? {1'b0,amp_reg[17:3]} : mantissa_a;
        multiply_b=combining ? mod_reg[17:4] : {7'b0,(7'd64-{1'b0,fraction})};
        combined=summing ? (({3'b0,amp_reg}+{3'b0,mod_reg}) << 2) : (product_a >> 8);
        pitch_sum=(product_a >> 2)+(product_b >> 2);
    end
    always_ff @(posedge clk) begin
        if(rst) begin state<=IDLE; result<=0; end
        else case(state)
            IDLE: if(in_valid) begin
                combining<=combine_amp; summing<=sum_mode; amp_reg<=amp; mod_reg<=amp_mod;
                fraction<=pitch[5:0]; octave<=~pitch[17:14]; zero_pitch<=pitch==0;
                mantissa_a<=pitch_table[pitch[13:6]];
                mantissa_b<=pitch[13:6]==255 ? 16'h8000 : pitch_table[pitch[13:6]+8'd1];
                state<=MULTIPLY;
            end
            MULTIPLY: begin
                product_a<=multiply_a*multiply_b;
                product_b<=fraction*mantissa_b;
                state<=FINISH;
            end
            FINISH: begin
                if(combining) result<=combined>21'hffffe ? 20'hffffe : {combined[19:1],1'b0};
                else result<=zero_pitch ? 20'd0 : ((pitch_sum >> 1) >> octave);
                state<=DONE;
            end
            DONE: if(out_ready) state<=IDLE;
        endcase
    end
endmodule
