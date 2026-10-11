// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_source_control;
    logic clk=0,rst=1,in_valid=0,in_ready,out_valid,out_ready=0;
    logic [63:0] frame;
    logic [2:0] runtime_phase,playback_counter;
    logic [17:0] pitch_current,f_current,amp_current,pitch_destination,f_destination,amp_destination;
    logic [17:0] pitch_control,f_control,amp_control,pitch_increment,next_pitch,next_f,next_amp,next_increment;
    logic [19:0] f_coefficient,next_coefficient;
    integer fd,fields,np,nf,na,ni,nc,count=0,cycles,worst=0;
    xp3_source_control dut(.*);
    always #5 clk=~clk;
    task automatic check_result;
        if(next_pitch!==18'(np) || next_f!==18'(nf) || next_amp!==18'(na) || next_increment!==18'(ni) || next_coefficient!==20'(nc))
            $fatal(1,"SOURCE_CONTROL_DIFFERENCE vector=%0d phase=%0d p=%h/%h f=%h/%h a=%h/%h inc=%h/%h coef=%h/%h",
                   count,runtime_phase,next_pitch,18'(np),next_f,18'(nf),next_amp,18'(na),next_increment,18'(ni),next_coefficient,20'(nc));
    endtask
    initial begin
        fd=$fopen("vectors.txt","r");if(!fd) $fatal(1,"Missing vectors");
        repeat(2) @(negedge clk);rst=0;
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                frame,runtime_phase,playback_counter,pitch_current,f_current,amp_current,pitch_destination,f_destination,amp_destination,
                pitch_control,f_control,amp_control,pitch_increment,f_coefficient,np,nf,na,ni,nc);
            if(fields!=19) $fatal(1,"Malformed vector");
            @(negedge clk);if(!in_ready) $fatal(1,"Not ready");in_valid=1;
            @(negedge clk);in_valid=0;cycles=0;
            while(!out_valid) begin
                if(in_ready) $fatal(1,"Ready while busy");
                @(negedge clk);cycles=cycles+1;if(cycles>16) $fatal(1,"Control timeout");
            end
            if(cycles>worst) worst=cycles;
            check_result();
            repeat(count%4) begin @(negedge clk);if(!out_valid || in_ready) $fatal(1,"Backpressure failed");check_result();end
            out_ready=1;@(negedge clk);out_ready=0;count=count+1;
        end
        $fclose(fd);if(!count) $fatal(1,"No vectors");
        for(integer position=0;position<=worst;position=position+1) begin
            @(negedge clk);runtime_phase=2;pitch_control=18'h4001;frame=0;in_valid=1;
            @(negedge clk);in_valid=0;
            repeat(position) @(negedge clk);
            rst=1;@(negedge clk);if(out_valid || in_ready) $fatal(1,"Reset failed");
            rst=0;@(negedge clk);if(out_valid || !in_ready) $fatal(1,"Reset recovery failed");
        end
        $display("SOURCE_CONTROL_PASS vectors=%0d worst_cycles=%0d reset_positions=%0d",count,worst,worst+1);$finish;
    end
    initial begin #100000000;$fatal(1,"Watchdog");end
endmodule
