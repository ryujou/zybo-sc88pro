// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_wave_source;
    logic clk=0,rst=1,in_valid=0,in_ready,out_valid,out_ready=0;
    logic [63:0] frame;
    logic [5:0] voice_index;
    logic [2:0] runtime_phase,next_phase;
    logic [1:0] sample_format,next_format;
    logic [19:0] wave_control,sample_current,sample_loop,sample_end,fetch_state,next_control,next_address,next_fetch;
    logic [17:0] accumulator,pitch_increment,address_fraction,playback_config,next_accumulator,next_fraction,next_config;
    logic [95:0] fifo,next_fifo;
    logic bus16,physical16;
    logic [3:0] bank_shift;
    logic [15:0] irq_status,irq_mask,next_irq_status;
    logic irq_interrupt,irq_accepted,irq_blocked,next_irq_interrupt,next_irq_accepted,next_irq_blocked;
    logic rom_req_valid,rom_req_ready=0,rom_rsp_valid=0,rom_rsp_ready;
    logic [2:0] rom_req_cs;
    logic [23:0] rom_req_address;
    logic [7:0] rom_rsp_data=0;
    logic signed [19:0] sample;
    logic filter_due;
    integer fd,fields,nreads,req_index,rsp_count,pending_data,wait_left,delay_mode,count=0,total_reads=0,cycles,worst=0;
    integer main_reads, reset_checks=0, seek_result;
    integer cs[0:31],address[0:31],value[0:31];
    integer nc,na,nf,nd,nfrac,ncfg,np,nfmt,ns,ndue,nis,nii,nia,nib;
    logic [95:0] expected_fifo;
    logic pending=0;
    xp3_wave_source dut(.*);
    always #5 clk=~clk;

    task automatic read_vector;
            fields=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %h %d %d %d %d %d %d %d %d %d %d %d %d %d %d %h %d %d %d %d %d %d %d %d %d\n",
                frame,voice_index,runtime_phase,sample_format,wave_control,sample_current,sample_loop,sample_end,fetch_state,
                accumulator,pitch_increment,address_fraction,playback_config,fifo,bus16,physical16,bank_shift,irq_status,irq_mask,irq_interrupt,irq_accepted,irq_blocked,
                nc,na,nf,nd,nfrac,ncfg,expected_fifo,np,nfmt,ns,ndue,nis,nii,nia,nib,nreads);
            if(fields!=38 || nreads>32) $fatal(1,"Malformed vector %0d fields=%0d",count,fields);
            for(integer i=0;i<nreads;i=i+1) begin
                fields=$fscanf(fd,"%d %d %d\n",cs[i],address[i],value[i]);
                if(fields!=3) $fatal(1,"Truncated ROM list");
            end
    endtask

    task automatic check_result;
        if(next_control!==20'(nc) || next_address!==20'(na) || next_fetch!==20'(nf) || next_accumulator!==18'(nd) ||
           next_fraction!==18'(nfrac) || next_config!==18'(ncfg) || next_fifo!==expected_fifo || next_phase!==3'(np) ||
           next_format!==2'(nfmt) || sample!==20'(ns) || filter_due!==1'(ndue) || next_irq_status!==16'(nis) ||
           next_irq_interrupt!==1'(nii) || next_irq_accepted!==1'(nia) || next_irq_blocked!==1'(nib))
            $fatal(1,"SOURCE_DIFFERENCE vector=%0d phase=%0d control=%h/%h addr=%h/%h fetch=%h/%h acc=%h/%h frac=%h/%h cfg=%h/%h fifo=%h/%h sample=%0d/%0d due=%b/%0d irq=%h/%h flags=%b%b%b/%0d%0d%0d",
                count,runtime_phase,next_control,20'(nc),next_address,20'(na),next_fetch,20'(nf),next_accumulator,18'(nd),
                next_fraction,18'(nfrac),next_config,18'(ncfg),next_fifo,expected_fifo,sample,ns,filter_due,ndue,
                next_irq_status,16'(nis),next_irq_interrupt,next_irq_accepted,next_irq_blocked,nii,nia,nib);
    endtask

    // Request and response may handshake on the same edge, but there is never more than one outstanding read.
    always @(posedge clk) begin
        if(rst) begin pending=0;rom_rsp_valid=0; end
        else begin
            if(rom_rsp_valid && rom_rsp_ready) begin pending=0;rsp_count=rsp_count+1; end
            if(rom_req_valid && rom_req_ready) begin
                if(pending || req_index>=nreads) $fatal(1,"Unexpected/duplicate ROM request vector=%0d index=%0d",count,req_index);
                if(rom_req_cs!==3'(cs[req_index]) || rom_req_address!==24'(address[req_index]))
                    $fatal(1,"ROM_DIFFERENCE vector=%0d read=%0d got=%0d:%h expected=%0d:%h",count,req_index,rom_req_cs,rom_req_address,cs[req_index],24'(address[req_index]));
                pending_data=value[req_index];
                if($test$plusargs("damage_rom") && count==0 && req_index==0) pending_data=pending_data^1;
                req_index=req_index+1;total_reads=total_reads+1;pending=1;wait_left=delay_mode;
            end
        end
    end
    always @(negedge clk) begin
        rom_rsp_valid=0;
        if(pending) begin
            if(wait_left==0) begin rom_rsp_valid=1;rom_rsp_data=8'(pending_data); end
            else wait_left=wait_left-1;
        end
    end

    initial begin
        fd=$fopen("vectors.txt","r");if(!fd) $fatal(1,"Missing vectors");
        repeat(2) @(negedge clk); #1;rst=0;
        while(!$feof(fd)) begin
            read_vector();
            case(count%4) 0:delay_mode=0;1:delay_mode=1;2:delay_mode=7;3:delay_mode=31;endcase
            if($test$plusargs("nominal")) delay_mode=0;
            req_index=0;rsp_count=0;
            @(negedge clk);#1;if(!in_ready) $fatal(1,"Not ready");in_valid=1;rom_req_ready=1;
            @(negedge clk);#1;in_valid=0;cycles=0;
            while(!out_valid) begin
                if(in_ready) $fatal(1,"Ready while busy");
                @(negedge clk);#1;cycles=cycles+1;
                // Also stall request acceptance, independently of the byte-return delay.
                rom_req_ready=$test$plusargs("nominal") || cycles%5!=0;
                if(cycles>2000) $fatal(1,"Source stalled indefinitely vector=%0d",count);
            end
            if(req_index!=nreads || rsp_count!=nreads || pending) $fatal(1,"Missing ROM transactions vector=%0d",count);
            if(cycles>worst) worst=cycles;
            check_result();
            repeat(count%4) begin @(negedge clk);#1;if(!out_valid || in_ready) $fatal(1,"Backpressure failure");check_result();end
            out_ready=1;@(negedge clk);#1;out_ready=0;rom_req_ready=0;count=count+1;
        end
        main_reads=total_reads;
        for(integer probe=0;probe<2;probe=probe+1) begin
            seek_result=$fseek(fd,0,0);
            if(seek_result!=0) $fatal(1,"Cannot rewind vectors");
            repeat(probe==0 ? 1 : 4) read_vector();
            for(integer position=0;position<64;position=position+1) begin
                req_index=0;rsp_count=0;delay_mode=probe==0 ? 1 : 7;
                @(negedge clk);#1;in_valid=1;rom_req_ready=1;
                @(negedge clk);#1;in_valid=0;
                repeat(position) begin @(negedge clk);#1;end
                rst=1;
                @(negedge clk);#1;
                if(out_valid || in_ready || rom_req_valid || rom_rsp_ready) $fatal(1,"Reset did not clear handshake");
                rst=0;req_index=0;rsp_count=0;delay_mode=0;
                @(negedge clk);#1;
                if(!in_ready || out_valid || rom_req_valid || pending) $fatal(1,"Stale operation after reset");
                in_valid=1;
                @(negedge clk);#1;in_valid=0;cycles=0;
                while(!out_valid) begin
                    @(negedge clk);#1;cycles=cycles+1;
                    if(cycles>200) $fatal(1,"Reset replay timeout");
                end
                check_result();
                if(req_index!=nreads || rsp_count!=nreads || pending) $fatal(1,"Reset replay ROM count");
                out_ready=1;@(negedge clk);#1;out_ready=0;rom_req_ready=0;
                reset_checks=reset_checks+1;
            end
        end
        $display("SOURCE_RESET_PASS checks=%0d",reset_checks);
        $fclose(fd);if(!count) $fatal(1,"No vectors");
        $display("WAVE_SOURCE_PASS vectors=%0d worst_cycles=%0d reads=%0d",count,worst,main_reads);
        $finish;
    end
    initial begin #2000000000;$fatal(1,"Watchdog");end
endmodule
