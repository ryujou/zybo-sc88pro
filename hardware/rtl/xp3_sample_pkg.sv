// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
package xp3_sample_pkg;
    function automatic logic signed [17:0] decode_delta(input logic [1:0] format_code, input logic [11:0] encoded);
        logic signed [17:0] mantissa;
        logic [7:0] magnitude;
        logic [17:0] expanded;
        begin
            mantissa = {{10{encoded[7]}}, encoded[7:0]};
            if (format_code == 2) begin
                magnitude = encoded[7] ? -encoded[7:0] : encoded[7:0];
                expanded = magnitude[7:4] == 0 ? {14'b0, magnitude[3:0]} :
                    ({13'b0, 1'b1, magnitude[3:0]} << (magnitude[7:4] - 1));
                expanded = expanded << 6;
                decode_delta = encoded[7] ? -$signed(expanded) : $signed(expanded);
            end else if (format_code == 1) decode_delta = mantissa;
            else if (encoded[11:8] <= 10) decode_delta = mantissa <<< encoded[11:8];
            else decode_delta = 0;
        end
    endfunction
endpackage
