// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_voice_state;
    logic clk=0, rst=1, ready, read_enable=0;
    logic [8:0] read_address=0, write_address=0;
    logic [255:0] read_data, write_data=0;
    logic [7:0] write_enable=0;
    logic [255:0] expected [0:511];
    integer cycles;
    xp3_voice_state dut(.*);
    always #5 clk=~clk;

    task automatic wait_scrub;
        cycles=0;
        while(!ready) begin
            @(negedge clk); cycles=cycles+1;
            if(cycles>512) $fatal(1,"Reset sweep exceeds 512 clocks");
        end
        if(cycles!=512) $fatal(1,"Incorrect reset sweep %0d",cycles);
    endtask
    task automatic read_all(input logic cleared);
        for(integer address=0;address<512;address=address+1) begin
            read_enable=1; read_address=9'(address);
            @(negedge clk);
            if(read_data !== (cleared ? 256'b0 : expected[address]))
                $fatal(1,"RAM difference row=%0d got=%h expected=%h",address,read_data,cleared ? 256'b0 : expected[address]);
        end
        read_enable=0;
    endtask
    initial begin
        repeat(2) @(negedge clk);
        rst=0;
        #1;
        wait_scrub();
        read_all(1);
        // Exercise every row and every lane, then masked writes preserving the other lanes.
        for(integer address=0;address<512;address=address+1) begin
            write_address=9'(address); write_enable=8'hff;
            for(integer bank=0;bank<8;bank=bank+1)
                write_data[bank*32 +: 32]=32'h81f020a3 ^ (address*8191) ^ (bank*32'h1020304);
            expected[address]=write_data;
            @(negedge clk);
        end
        write_enable=0; read_all(0);
        for(integer address=0;address<512;address=address+1) begin
            write_address=9'(address); write_enable=8'(1<<(address%8)); write_data='1;
            expected[address][(address%8)*32 +: 32]=32'hffffffff;
            @(negedge clk);
        end
        write_enable=0; read_all(0);
        // Reset wins over active write/read and restarting a sweep clears the whole RAM.
        write_enable='1; write_data='1; read_enable=1; rst=1;
        @(negedge clk);
        if(ready) $fatal(1,"Ready asserted during reset");
        rst=0;
        repeat(137) @(negedge clk);
        rst=1; @(negedge clk); rst=0;
        write_enable=0; read_enable=0;
        wait_scrub(); read_all(1);
        $display("VOICE_STATE_PASS rows=512 banks=8 reset_cycles=512");
        $finish;
    end
    initial begin #1000000; $fatal(1,"Watchdog"); end
endmodule
