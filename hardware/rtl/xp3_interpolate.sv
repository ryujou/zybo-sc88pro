// SPDX-License-Identifier: GPL-3.0-only
// Three taps from the pinned XP interpolation table; thanks to InfoSecDJ and NukeYKT.
`timescale 1ns/1ps
module xp3_interpolate #(
    parameter TABLE_FILE = "xp3_interpolation.mem"
) (
    input logic clk, rst, in_valid,
    output logic in_ready,
    input logic [1:0] format_code, gain,
    input logic [6:0] phase,
    input logic [35:0] cells,
    input logic [17:0] accumulator,
    output logic out_valid,
    input logic out_ready,
    output logic signed [19:0] sample
);
    import xp3_sample_pkg::*;
    typedef enum logic [2:0] {IDLE, MULTIPLY, ADD, WRAP, DONE} state_t;
    state_t state;
    logic [11:0] coefficients [0:383];
    logic [11:0] coefficient, encoded, decode_encoded;
    logic [35:0] cell_data;
    logic [1:0] format_reg, gain_reg, tap, decode_format;
    logic [6:0] phase_reg;
    logic signed [17:0] operand, operand_reg;
    logic signed [30:0] product, rounded_product, contribution;
    logic signed [31:0] extended;
    logic signed [19:0] wrapped;
    logic [3:0] shift;
    logic omit_tap;

    initial $readmemh(TABLE_FILE, coefficients);
    always_comb begin
        in_ready = state == IDLE && !rst;
        out_valid = state == DONE && !rst;
        encoded = cell_data[tap*12 +: 12];
        decode_encoded = state == IDLE ? cells[11:0] : tap == 0 ? cell_data[23:12] : cell_data[35:24];
        decode_format = state == IDLE ? format_code : format_reg;
        if (decode_format == 2) operand = decode_delta(decode_format, decode_encoded);
        else operand = $signed({{10{decode_encoded[7]}}, decode_encoded[7:0]}) <<< 6;
        rounded_product = product >>> 8;
        contribution = omit_tap ? 31'sd0 : ((rounded_product <<< 2) >>> shift);
        wrapped = extended[19:0];
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            sample <= 0;
        end else begin
            case (state)
                IDLE: if (in_valid) begin
                    format_reg <= format_code;
                    gain_reg <= gain;
                    phase_reg <= phase;
                    cell_data <= cells;
                    extended <= $signed({{14{accumulator[17]}}, accumulator}) <<< 2;
                    coefficient <= coefficients[{2'b0, phase}];
                    operand_reg <= operand;
                    tap <= 0;
                    state <= MULTIPLY;
                end
                MULTIPLY: begin
                    product <= operand_reg * $signed({1'b0, coefficient});
                    shift <= format_reg == 2 ? 4'd4 : format_reg == 1 ? 4'd10 : 4'd10 - encoded[11:8];
                    omit_tap <= format_reg != 1 && format_reg != 2 && encoded[11:8] > 10;
                    state <= ADD;
                end
                ADD: begin
                    extended <= extended + contribution;
                    if (tap == 2) state <= WRAP;
                    else begin
                        tap <= tap + 1;
                        coefficient <= coefficients[{(tap + 2'd1), phase_reg}];
                        operand_reg <= operand;
                        state <= MULTIPLY;
                    end
                end
                WRAP: begin sample <= wrapped >>> (2'd3 - gain_reg); state <= DONE; end
                DONE: if (out_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
