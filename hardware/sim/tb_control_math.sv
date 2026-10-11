// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_control_math;
    logic clk=0,rst=1,in_valid=0,in_ready,out_valid,out_ready=0,combine_amp,sum_mode;
    logic [17:0] pitch,amp,amp_mod;
    logic [19:0] result;
    integer fd,fields,op,p,a,m,s,r,count=0,cycles;
    xp3_control_math dut(.*);
    always #5 clk=~clk;
    initial begin
        fd=$fopen("vectors.txt","r"); if(!fd) $fatal(1,"Missing vectors");
        repeat(2) @(negedge clk); rst=0;
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d %d %d %d %d %d\n",op,p,a,m,s,r);
            if(fields!=6) $fatal(1,"Malformed vector %0d",count);
            @(negedge clk); if(!in_ready) $fatal(1,"Not ready");
            combine_amp=1'(op); pitch=18'(p); amp=18'(a); amp_mod=18'(m); sum_mode=1'(s); in_valid=1;
            @(negedge clk); in_valid=0; cycles=0;
            while(!out_valid) begin
                if(in_ready) $fatal(1,"Ready while busy");
                @(negedge clk); cycles=cycles+1;
                if(cycles>2) $fatal(1,"Latency exceeded");
            end
            if(cycles!=2 || result!==20'(r))
                $fatal(1,"CONTROL_DIFFERENCE vector=%0d result=%0d/%0d cycles=%0d",count,result,r,cycles);
            repeat(count%4) begin
                @(negedge clk);
                if(!out_valid || in_ready || result!==20'(r)) $fatal(1,"Backpressure failed");
            end
            out_ready=1; @(negedge clk); out_ready=0; count=count+1;
        end
        $fclose(fd); if(!count) $fatal(1,"No vectors");
        for(integer delay=0;delay<3;delay=delay+1) begin
            @(negedge clk); in_valid=1;
            @(negedge clk); in_valid=0;
            repeat(delay) @(negedge clk);
            rst=1; @(negedge clk); if(out_valid || in_ready) $fatal(1,"Reset failed");
            rst=0; @(negedge clk); if(out_valid || !in_ready) $fatal(1,"Reset recovery failed");
        end
        $display("CONTROL_MATH_PASS vectors=%0d cycles=2 reset_positions=3",count);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Watchdog"); end
endmodule
