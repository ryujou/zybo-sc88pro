// SPDX-License-Identifier: GPL-3.0-only
// Fixed XP3 Chamberlin filter and TVA, sharing one signed product datapath.
`timescale 1ns/1ps
module xp3_filter_tva (
    input  logic clk, rst,
    input  logic in_valid,
    output logic in_ready,
    input  logic tva,
    input  logic [1:0] mode,
    input  logic signed [23:0] sample, old_bp, old_lp,
    input  logic [19:0] frequency, damping,
    input  logic [15:0] gain,
    output logic out_valid,
    input  logic out_ready,
    output logic signed [23:0] result, next_bp, next_lp, high_pass
);
    typedef enum logic [3:0] {IDLE, MUL_LP, LP, MUL_HP, HP, MUL_BP, BP, MUL_TVA, TVA, DONE} state_t;
    state_t state;
    logic [1:0] selected_mode;
    logic signed [23:0] x, bp, lp;
    logic [19:0] f, q, g;
    logic signed [23:0] multiply_value;
    logic [19:0] multiply_coefficient;
    logic signed [44:0] product;
    logic signed [26:0] scaled, sum_lp, sum_hp, sum_bp, difference;
    logic signed [23:0] clipped_bp;

    function automatic logic signed [23:0] sat24(input logic signed [26:0] value);
        if (value > 27'sd8388607) sat24 = 24'sh7fffff;
        else if (value < -27'sd8388608) sat24 = 24'sh800000;
        else sat24 = value[23:0];
    endfunction

    always_comb begin
        in_ready = (state == IDLE || (state == DONE && out_ready)) && !rst;
        out_valid = (state == DONE) && !rst;
        multiply_value = bp;
        multiply_coefficient = f;
        if (state == MUL_HP) multiply_coefficient = q;
        if (state == MUL_BP) multiply_value = high_pass;
        if (state == MUL_TVA) begin
            multiply_value = x;
            multiply_coefficient = g;
        end
        // Negative products divide toward zero, unlike interpolation's arithmetic shift.
        scaled = (product >>> 19) + ((product[44] && (|product[18:0])) ? 27'sd1 : 27'sd0);
        sum_lp = $signed(lp) + scaled;
        sum_hp = $signed(x) - $signed(next_lp) - scaled;
        sum_bp = $signed(bp) + scaled;
        difference = $signed(high_pass) - $signed(next_lp);
        clipped_bp = sat24(sum_bp);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            result <= 0;
            next_bp <= 0;
            next_lp <= 0;
            high_pass <= 0;
        end else if (in_valid && in_ready) begin
                    x <= sample;
                    bp <= old_bp;
                    lp <= old_lp;
                    f <= frequency;
                    q <= damping;
                    g <= {gain, 4'b0};
                    selected_mode <= mode;
                    next_bp <= old_bp;
                    next_lp <= old_lp;
                    high_pass <= 0;
                    state <= tva ? MUL_TVA : MUL_LP;
        end else begin
            case (state)
                MUL_LP, MUL_HP, MUL_BP, MUL_TVA: begin
                    product <= multiply_value * $signed({1'b0, multiply_coefficient});
                    case (state)
                        MUL_LP: state <= LP;
                        MUL_HP: state <= HP;
                        MUL_BP: state <= BP;
                        default: state <= TVA;
                    endcase
                end
                LP: begin next_lp <= sat24(sum_lp); state <= MUL_HP; end
                HP: begin high_pass <= sat24(sum_hp); state <= MUL_BP; end
                BP: begin
                    next_bp <= clipped_bp;
                    case (selected_mode)
                        0: result <= next_lp;
                        1: result <= clipped_bp;
                        2: result <= high_pass;
                        3: result <= sat24(difference);
                    endcase
                    state <= DONE;
                end
                TVA: begin result <= sat24(scaled); state <= DONE; end
                DONE: if (out_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
