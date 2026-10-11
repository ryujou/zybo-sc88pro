// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_interpolate;
    logic clk=0, rst=1, in_valid=0, in_ready, out_valid, out_ready=0;
    logic [1:0] format_code, gain;
    logic [6:0] phase;
    logic [35:0] cells;
    logic [17:0] accumulator;
    logic signed [19:0] sample;
    integer fd, fields, fmt, g, p, acc, c0, c1, c2, y, count=0, cycles;
    xp3_interpolate dut(.*);
    always #5 clk=~clk;
    task automatic check_result;
        if (sample !== 20'(y)) $fatal(1,"DIFFERENCE vector=%0d sample=%0d/%0d format=%0d phase=%0d",count,sample,y,fmt,p);
    endtask
    initial begin
        fd=$fopen("vectors.txt","r");
        if (!fd) $fatal(1,"Cannot open vectors");
        repeat(2) @(negedge clk);
        rst=0;
        while (!$feof(fd)) begin
            fields=$fscanf(fd,"%d %d %d %d %d %d %d %d\n",fmt,g,p,acc,c0,c1,c2,y);
            if (fields!=8) $fatal(1,"Truncated vector %0d",count);
            @(negedge clk);
            if (!in_ready) $fatal(1,"Not ready");
            format_code=2'(fmt); gain=2'(g); phase=7'(p); accumulator=18'(acc);
            cells={12'(c2),12'(c1),12'(c0)}; in_valid=1;
            @(negedge clk); in_valid=0; cycles=0;
            while (!out_valid) begin
                if (in_ready) $fatal(1,"Ready while busy");
                @(negedge clk); cycles=cycles+1;
                if (cycles>7) $fatal(1,"Latency exceeded");
            end
            if (cycles!=7) $fatal(1,"Unexpected latency");
            check_result();
            repeat(count%4) begin
                @(negedge clk);
                if (!out_valid || in_ready) $fatal(1,"Backpressure protocol failure");
                check_result();
            end
            out_ready=1; @(negedge clk); out_ready=0; count=count+1;
        end
        $fclose(fd);
        if (!count) $fatal(1,"No vectors");
        for(integer delay=0;delay<8;delay=delay+1) begin
            @(negedge clk); in_valid=1;
            @(negedge clk); in_valid=0;
            repeat(delay) @(negedge clk);
            rst=1; @(negedge clk);
            if(out_valid || in_ready) $fatal(1,"Reset failed");
            rst=0; @(negedge clk);
            if(out_valid || !in_ready) $fatal(1,"Reset recovery failed");
        end
        $display("INTERPOLATE_PASS vectors=%0d cycles=7 reset_positions=8",count);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"Watchdog"); end
endmodule
