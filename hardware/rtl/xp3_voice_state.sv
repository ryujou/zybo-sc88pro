// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module xp3_voice_state (
    input logic clk, rst,
    output logic ready,
    input logic read_enable,
    input logic [8:0] read_address,
    output logic [255:0] read_data,
    input logic [7:0] write_enable,
    input logic [8:0] write_address,
    input logic [255:0] write_data
);
    logic scrubbing;
    logic [8:0] clear_address, ram_write_address;
    logic [255:0] ram_write_data;
    assign ready = !rst && !scrubbing;
    assign ram_write_address = scrubbing ? clear_address : write_address;
    assign ram_write_data = scrubbing ? 256'b0 : write_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            scrubbing <= 1;
            clear_address <= 0;
        end else if (scrubbing) begin
            if (clear_address == 511) scrubbing <= 0;
            else clear_address <= clear_address + 1;
        end
    end
    for (genvar bank=0; bank<8; bank=bank+1) begin: banks
        // A reset sweep writes RAM instead of resetting all 131072 storage bits in parallel.
        (* ram_style = "block" *) logic [31:0] words [0:511];
        always_ff @(posedge clk) begin
            if (!rst && (scrubbing || write_enable[bank]))
                words[ram_write_address] <= ram_write_data[bank*32 +: 32];
            if (ready && read_enable) read_data[bank*32 +: 32] <= words[read_address];
        end
    end
endmodule
