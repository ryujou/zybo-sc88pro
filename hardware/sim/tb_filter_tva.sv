// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_filter_tva;
    logic clk = 0, rst = 1, in_valid = 0, in_ready, tva;
    logic [1:0] mode;
    logic signed [23:0] sample, old_bp, old_lp, result, next_bp, next_lp, high_pass;
    logic [19:0] frequency, damping;
    logic [15:0] gain;
    logic out_valid, out_ready = 0;
    integer fd, count = 0, fields, op, m, sx, b, l, f, q, g, y, nb, nl, hp, cycles, stalls;
    xp3_filter_tva dut(.*);
    always #5 clk = ~clk;

    task automatic check_result;
        if (result !== 24'(y) || next_bp !== 24'(nb) || next_lp !== 24'(nl) || high_pass !== 24'(hp))
            $fatal(1, "DIFFERENCE vector=%0d result=%0d/%0d bp=%0d/%0d lp=%0d/%0d hp=%0d/%0d",
                count, result,y,next_bp,nb,next_lp,nl,high_pass,hp);
    endtask

    initial begin
        fd = $fopen("vectors.txt","r");
        if (!fd) $fatal(1,"Cannot open vectors");
        repeat (2) @(negedge clk);
        rst = 0;
        while (!$feof(fd)) begin
            fields = $fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d\n",op,m,sx,b,l,f,q,g,y,nb,nl,hp);
            if (fields != 12) $fatal(1,"Truncated vector %0d (%0d fields)",count,fields);
            @(negedge clk);
            if (!in_ready) $fatal(1,"Not ready before input");
            tva=1'(op); mode=2'(m); sample=24'(sx); old_bp=24'(b); old_lp=24'(l);
            frequency=20'(f); damping=20'(q); gain=16'(g); in_valid=1;
            @(negedge clk);
            in_valid=0;
            cycles=0;
            while (!out_valid) begin
                if (in_ready) $fatal(1,"Accepted a second command while busy");
                @(negedge clk);
                cycles=cycles+1;
                if (cycles>6) $fatal(1,"Latency exceeded");
            end
            if (cycles != (op ? 2 : 6)) $fatal(1,"Unexpected latency %0d",cycles);
            check_result();
            stalls=count%4;
            repeat (stalls) begin
                @(negedge clk);
                if (!out_valid || in_ready) $fatal(1,"Backpressure protocol failure");
                check_result();
            end
            out_ready=1;
            @(negedge clk);
            out_ready=0;
            count=count+1;
        end
        $fclose(fd);
        if (count == 0) $fatal(1,"No vectors");
        // Cancel at every operation pipeline stage, including the held response.
        for (integer delay=0; delay<7; delay=delay+1) begin
            @(negedge clk); in_valid=1; tva=0;
            @(negedge clk); in_valid=0;
            repeat(delay) @(negedge clk);
            rst=1;
            @(negedge clk);
            if (out_valid || in_ready) $fatal(1,"Reset did not cancel transaction");
            rst=0;
            @(negedge clk);
            if (!in_ready || out_valid) $fatal(1,"Reset recovery failed");
        end
        $display("FILTER_TVA_PASS vectors=%0d filter_cycles=6 tva_cycles=2 reset_positions=7",count);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"Watchdog"); end
endmodule
