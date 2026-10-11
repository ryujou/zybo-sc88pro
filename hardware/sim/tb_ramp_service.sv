// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_ramp_service;
    logic clk=0,rst=1,in_valid=0,in_ready,out_valid,out_ready=0;
    logic [2:0] kind,playback_counter;
    logic [63:0] frame;
    logic [5:0] voice_index;
    logic [19:0] current_value,scratch_value,decoded_value,combined_amp,next_current,next_scratch,next_decoded,next_combined;
    logic [17:0] destination,control,amp_mod_current,next_destination,next_control;
    logic amp_mod_sum,curve2_entry,next_entry,irq_interrupt,irq_accepted,irq_blocked,next_irq_interrupt,next_irq_accepted,next_irq_blocked;
    logic [15:0] irq_status,irq_mask,next_irq_status;
    integer fd,fields,k,pc,v,c,s,d,a,dest,ctl,m,ms,entry,is,im,ii,ia,ib,nc,ns,nd,na,ndest,nctl,ne,nis,nii,nia,nib;
    integer count=0,cycles,worst=0;
    logic [63:0] clock_value;
    xp3_ramp_service dut(.*);
    always #5 clk=~clk;
    task automatic check_result;
        if(next_current!==20'(nc) || next_scratch!==20'(ns) || next_decoded!==20'(nd) || next_combined!==20'(na) ||
           next_destination!==18'(ndest) || next_control!==18'(nctl) || next_entry!==1'(ne) ||
           next_irq_status!==16'(nis) || next_irq_interrupt!==1'(nii) || next_irq_accepted!==1'(nia) || next_irq_blocked!==1'(nib))
            $fatal(1,"SERVICE_DIFFERENCE vector=%0d kind=%0d c=%0d/%0d s=%0d/%0d decoded=%0d/%0d amp=%0d/%0d dest=%0d/%0d ctl=%0d/%0d entry=%b/%0d irq=%h/%h flags=%b%b%b/%0d%0d%0d",
                count,k,next_current,nc,next_scratch,ns,next_decoded,nd,next_combined,na,next_destination,ndest,next_control,nctl,next_entry,ne,
                next_irq_status,16'(nis),next_irq_interrupt,next_irq_accepted,next_irq_blocked,nii,nia,nib);
    endtask
    initial begin
        fd=$fopen("vectors.txt","r"); if(!fd) $fatal(1,"Missing vectors");
        repeat(2) @(negedge clk); rst=0;
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                k,clock_value,pc,v,c,s,d,a,dest,ctl,m,ms,entry,is,im,ii,ia,ib,nc,ns,nd,na,ndest,nctl,ne,nis,nii,nia,nib);
            if(fields!=29) $fatal(1,"Malformed vector %0d (%0d fields)",count,fields);
            @(negedge clk); if(!in_ready) $fatal(1,"Not ready");
            kind=3'(k);frame=clock_value;playback_counter=3'(pc);voice_index=6'(v);
            current_value=20'(c);scratch_value=20'(s);decoded_value=20'(d);combined_amp=20'(a);
            destination=18'(dest);control=18'(ctl);amp_mod_current=18'(m);amp_mod_sum=1'(ms);curve2_entry=1'(entry);
            irq_status=16'(is);irq_mask=16'(im);irq_interrupt=1'(ii);irq_accepted=1'(ia);irq_blocked=1'(ib);in_valid=1;
            @(negedge clk);in_valid=0;cycles=0;
            while(!out_valid) begin
                if(in_ready) $fatal(1,"Ready while busy");
                @(negedge clk);cycles=cycles+1;
                if(cycles>9) $fatal(1,"Service latency exceeded");
            end
            if(cycles>worst) worst=cycles;
            check_result();
            repeat(count%4) begin @(negedge clk);if(!out_valid || in_ready) $fatal(1,"Backpressure failed");check_result();end
            out_ready=1;@(negedge clk);out_ready=0;count=count+1;
        end
        $fclose(fd);if(!count) $fatal(1,"No vectors");
        // Force a nonheld logarithmic operation for reset at every pipeline position.
        for(integer delay=0;delay<=worst;delay=delay+1) begin
            @(negedge clk);kind=0;control=1;frame=0;in_valid=1;
            @(negedge clk);in_valid=0;
            repeat(delay) @(negedge clk);
            rst=1;@(negedge clk);if(out_valid || in_ready) $fatal(1,"Reset failed");
            rst=0;@(negedge clk);if(out_valid || !in_ready) $fatal(1,"Reset recovery failed");
        end
        $display("RAMP_SERVICE_PASS vectors=%0d worst_cycles=%0d reset_positions=%0d",count,worst,worst+1);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Watchdog"); end
endmodule
