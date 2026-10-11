// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_pair_filter;
    logic clk=0, rst=1, in_valid=0, in_ready, out_valid, out_ready=0;
    logic [19:0] filter_config;
    logic [47:0] samples, old_bp, old_lp, next_bp, next_lp;
    logic [39:0] frequencies, dampings;
    logic [31:0] gains;
    logic signed [23:0] result;
    integer fd,fields,cfg,x,y,b0,l0,f0,q0,g0,b1,l1,f1,q1,g1,r,nb0,nl0,nb1,nl1;
    integer count=0,cycles,worst=0;
    xp3_pair_filter dut(
        .clk(clk),.rst(rst),.in_valid(in_valid),.in_ready(in_ready),.filter_config(filter_config),
        .samples(samples),.old_bp(old_bp),.old_lp(old_lp),.frequencies(frequencies),.dampings(dampings),.gains(gains),
        .out_valid(out_valid),.out_ready(out_ready),.result(result),.next_bp(next_bp),.next_lp(next_lp)
    );
    always #5 clk=~clk;
    task automatic check_result;
        if(result !== 24'(r) || next_bp !== {24'(nb1),24'(nb0)} || next_lp !== {24'(nl1),24'(nl0)})
            $fatal(1,"PAIR_DIFFERENCE vector=%0d structure=%0d result=%0d/%0d bp=%h/%h lp=%h/%h",
                count,((cfg>>12)&15)+1,result,r,next_bp,{24'(nb1),24'(nb0)},next_lp,{24'(nl1),24'(nl0)});
    endtask
    initial begin
        fd=$fopen("vectors.txt","r");
        if(!fd) $fatal(1,"Missing vectors");
        repeat(2) @(negedge clk); rst=0;
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                cfg,x,y,b0,l0,f0,q0,g0,b1,l1,f1,q1,g1,r,nb0,nl0,nb1,nl1);
            if(fields!=18) $fatal(1,"Malformed vector %0d",count);
            @(negedge clk);
            if(!in_ready) $fatal(1,"Not ready");
            filter_config=20'(cfg); samples={24'(y),24'(x)}; old_bp={24'(b1),24'(b0)}; old_lp={24'(l1),24'(l0)};
            frequencies={20'(f1),20'(f0)}; dampings={20'(q1),20'(q0)}; gains={16'(g1),16'(g0)}; in_valid=1;
            @(negedge clk); in_valid=0; cycles=0;
            while(!out_valid) begin
                if(in_ready) $fatal(1,"Ready while busy");
                @(negedge clk); cycles=cycles+1;
                if(cycles>32) $fatal(1,"Pair latency exceeds 32 clocks");
            end
            if(cycles>worst) worst=cycles;
            check_result();
            repeat(count%4) begin
                @(negedge clk);
                if(!out_valid || in_ready) $fatal(1,"Backpressure failure");
                check_result();
            end
            out_ready=1; @(negedge clk); out_ready=0; count=count+1;
        end
        $fclose(fd);
        if(!count) $fatal(1,"No vectors");
        for(integer delay=0;delay<=worst;delay=delay+1) begin
            @(negedge clk); in_valid=1;
            @(negedge clk); in_valid=0;
            repeat(delay) @(negedge clk);
            rst=1; @(negedge clk);
            if(out_valid || in_ready) $fatal(1,"Reset failed");
            rst=0; @(negedge clk);
            if(out_valid || !in_ready) $fatal(1,"Reset recovery failed");
        end
        $display("PAIR_FILTER_PASS vectors=%0d worst_cycles=%0d reset_positions=%0d",count,worst,worst+1);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Watchdog"); end
endmodule
