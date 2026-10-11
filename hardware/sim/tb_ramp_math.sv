// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_ramp_math;
    logic clk=0,rst=1,in_valid=0,in_ready,out_valid,out_ready=0;
    logic [1:0] operation;
    logic [19:0] current_value,target_value,scratch_value,next_current,next_scratch;
    logic [11:0] rate;
    logic parity,quantum4,curve3,terminal,trunk_complete;
    integer fd,fields,op,c,t,s,r,p,q,c3,nc,ns,term,complete,count=0,cycles;
    xp3_ramp_math dut(.*);
    always #5 clk=~clk;
    task automatic check_result;
        if(next_current!==20'(nc) || next_scratch!==20'(ns) || terminal!==1'(term) || trunk_complete!==1'(complete))
            $fatal(1,"RAMP_DIFFERENCE vector=%0d op=%0d current=%0d/%0d scratch=%0d/%0d terminal=%b/%0d complete=%b/%0d",
                count,op,next_current,nc,next_scratch,ns,terminal,term,trunk_complete,complete);
    endtask
    initial begin
        fd=$fopen("vectors.txt","r"); if(!fd) $fatal(1,"Missing vectors");
        repeat(2) @(negedge clk); rst=0;
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d\n",op,c,t,s,r,p,q,c3,nc,ns,term,complete);
            if(fields!=12) $fatal(1,"Malformed vector %0d",count);
            @(negedge clk); if(!in_ready) $fatal(1,"Not ready");
            operation=2'(op); current_value=20'(c); target_value=20'(t); scratch_value=20'(s); rate=12'(r);
            parity=1'(p); quantum4=1'(q); curve3=1'(c3); in_valid=1;
            @(negedge clk); in_valid=0; cycles=0;
            while(!out_valid) begin
                if(in_ready) $fatal(1,"Ready while busy");
                @(negedge clk); cycles=cycles+1;
                if(cycles>3) $fatal(1,"Latency exceeded");
            end
            if(cycles!=((op==0 || op==2) ? 3 : 1)) $fatal(1,"Incorrect latency");
            check_result();
            repeat(count%4) begin
                @(negedge clk); if(!out_valid || in_ready) $fatal(1,"Backpressure failed"); check_result();
            end
            out_ready=1; @(negedge clk); out_ready=0; count=count+1;
        end
        $fclose(fd); if(!count) $fatal(1,"No vectors");
        for(integer delay=0;delay<4;delay=delay+1) begin
            @(negedge clk); in_valid=1; operation=2;
            @(negedge clk); in_valid=0;
            repeat(delay) @(negedge clk);
            rst=1; @(negedge clk); if(out_valid || in_ready) $fatal(1,"Reset failed");
            rst=0; @(negedge clk); if(out_valid || !in_ready) $fatal(1,"Reset recovery failed");
        end
        $display("RAMP_MATH_PASS vectors=%0d multiply_cycles=3 direct_cycles=1 reset_positions=4",count);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Watchdog"); end
endmodule
