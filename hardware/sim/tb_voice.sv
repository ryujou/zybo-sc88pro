// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_voice;
    logic clk=0;
    logic rst=0;
    logic cmd_valid=0;
    logic cmd_pair=0;
    logic cmd_irq_interrupt=0;
    logic cmd_irq_accepted=0;
    logic cmd_irq_blocked=0;
    logic done_ready=0;
    logic cfg_valid=0;
    logic cfg_write=0;
    logic cfg_rsp_ready=0;
    logic rom_req_ready=0;
    logic rom_rsp_valid=0;
    logic cmd_ready;
    logic done_valid;
    logic done_irq_interrupt;
    logic done_irq_accepted;
    logic done_irq_blocked;
    logic cfg_ready;
    logic cfg_rsp_valid;
    logic rom_req_valid;
    logic rom_rsp_ready;
    logic rom_req_partner;
    logic ready;
    logic [63:0] cmd_frame=0;
    logic [5:0] cmd_voice=0;
    logic [5:0] cfg_voice=0;
    logic [5:0] cfg_word=0;
    logic [15:0] cmd_irq_status=0;
    logic [15:0] cmd_irq_mask=0;
    logic [63:0] cmd_descriptors=0;
    logic [7:0] cmd_physical16=0;
    logic [7:0] rom_rsp_data=0;
    logic [31:0] cmd_bank_shifts=0;
    logic [31:0] cfg_wdata=0;
    logic [31:0] cfg_rsp_data;
    logic [63:0] done_frame;
    logic [5:0] done_voice;
    logic [15:0] done_irq_status;
    logic [1:0] done_filter_due;
    logic signed [23:0] done_prior_owner;
    logic signed [23:0] done_prior_partner;
    logic signed [23:0] done_output_owner;
    logic signed [23:0] done_output_partner;
    logic signed [19:0] done_sample_owner;
    logic signed [19:0] done_sample_partner;
    logic [39:0] done_source_owner,done_source_partner;
    logic [2:0] rom_req_cs;
    logic [23:0] rom_req_address;
    integer fd,fields,op,v,w,data,count=0,cases=0,cycles,single_worst=0,pair_worst=0;
    integer exp_status,exp_interrupt,exp_blocked,exp_due,exp_s0,exp_s1,exp_o0,exp_o1,nreads,index,responses;
    integer rcs[0:63],raddr[0:63],rpartner[0:63],rvalue[0:63];
    integer held_data,delay_left,delay_mode,readback;
    integer reset_seed[0:1][0:50],reset_nreads[0:1];
    integer reset_cs[0:1][0:31],reset_address[0:1][0:31],reset_value[0:1][0:31];
    integer reset_checks=0,fixture;
    logic [7:0] real_rom[0:20971519];
    integer rom_fd,rom_size;
    integer stage_count=0,stage_index=0,stage_total=0,stage_kind[0:7],stage_voice[0:7];
    longint stage_value[0:7][0:7];
    logic stage_enable=0,single_stage_tva,pair_stage_tva;
    logic pending=0;
    logic [23:0] prior0=0,prior1=0;
    xp3_voice dut(.*);
    always #5 clk=~clk;
    task automatic config_access(input bit write_flag,input integer voice,word,value);
        @(negedge clk);#1;
        if(!cfg_ready) $fatal(1,"Config not ready");
        cfg_valid=1;cfg_write=write_flag;cfg_voice=6'(voice);cfg_word=6'(word);cfg_wdata=32'(value);
        @(negedge clk);#1;cfg_valid=0;
        while(!cfg_rsp_valid) begin @(negedge clk);#1;end
        readback=cfg_rsp_data;cfg_rsp_ready=1;
        @(negedge clk);#1;cfg_rsp_ready=0;
    endtask
    task automatic reset_core;
        @(negedge clk);#1;rst=1;cmd_valid=0;cfg_valid=0;rom_req_ready=0;done_ready=0;
        @(negedge clk);#1;
        if(ready || done_valid || cfg_rsp_valid || rom_req_valid) $fatal(1,"Reset handshake");
        rst=0;cycles=0;
        while(!ready) begin @(negedge clk);#1;cycles=cycles+1;if(cycles>513) $fatal(1,"Scrub timeout");end
        cmd_irq_status=0;cmd_irq_interrupt=0;cmd_irq_accepted=0;cmd_irq_blocked=0;
        prior0=0;prior1=0;
    endtask
    task automatic check_stage(input bit tva,input integer voice,input logic signed [23:0] x,result,bp,lp,hp,input logic [1:0] mode,input logic [19:0] f,q,g);
        if(stage_enable) begin
            if(stage_index>=stage_count || stage_kind[stage_index]!=integer'(tva) || stage_voice[stage_index]!=voice) $fatal(1,"VOICE_STAGE_ORDER frame=%0d index=%0d",count,stage_index);
            if(x!==24'(stage_value[stage_index][0])) $fatal(1,"VOICE_STAGE_INPUT frame=%0d index=%0d",count,stage_index);
            if(tva) begin
                if(g!==20'(stage_value[stage_index][1]) || result!==24'(stage_value[stage_index][2])) $fatal(1,"VOICE_TVA_STAGE frame=%0d index=%0d",count,stage_index);
            end else if(mode!==2'(stage_value[stage_index][1]) || lp!==24'(stage_value[stage_index][2]) || hp!==24'(stage_value[stage_index][3]) || bp!==24'(stage_value[stage_index][4]) ||
                        result!==24'(stage_value[stage_index][5]) || f!==20'(stage_value[stage_index][6]) || q!==20'(stage_value[stage_index][7])) $fatal(1,"VOICE_FILTER_STAGE frame=%0d index=%0d",count,stage_index);
            stage_index=stage_index+1;stage_total=stage_total+1;
        end
    endtask
    always @(posedge clk) if(!rst) begin
        if(dut.filter.in_valid && dut.filter.in_ready) single_stage_tva<=dut.filter.tva;
        if(dut.pair_filter.unit.in_valid && dut.pair_filter.unit.in_ready) pair_stage_tva<=dut.pair_filter.unit.tva;
        if(dut.filter.out_valid) check_stage(single_stage_tva,cmd_voice,dut.filter.x,dut.filter.result,dut.filter.next_bp,dut.filter.next_lp,dut.filter.high_pass,dut.filter.selected_mode,dut.filter.f,dut.filter.q,dut.filter.g);
        if(dut.pair_filter.unit.out_valid && dut.pair_filter.unit_out_ready) check_stage(pair_stage_tva,integer'(cmd_voice)+(dut.pair_filter.issued_owner ? 0 : 1),dut.pair_filter.unit.x,dut.pair_filter.unit.result,dut.pair_filter.unit.next_bp,dut.pair_filter.unit.next_lp,dut.pair_filter.unit.high_pass,dut.pair_filter.unit.selected_mode,dut.pair_filter.unit.f,dut.pair_filter.unit.q,dut.pair_filter.unit.g);
    end
    always @(posedge clk) begin
        if(rst) begin pending=0;rom_rsp_valid=0;end
        else begin
            if(rom_rsp_valid && rom_rsp_ready) begin pending=0;responses=responses+1;end
            if(rom_req_valid && rom_req_ready) begin
                if(pending || index>=nreads) $fatal(1,"Unexpected ROM transaction frame=%0d index=%0d",count,index);
                if(rom_req_cs!==3'(rcs[index]) || rom_req_address!==24'(raddr[index]) || rom_req_partner!==1'(rpartner[index]))
                    $fatal(1,"VOICE_ROM_DIFFERENCE frame=%0d read=%0d got=%0d:%h/%b expected=%0d:%h/%0d",count,index,rom_req_cs,rom_req_address,rom_req_partner,rcs[index],raddr[index],rpartner[index]);
                if($test$plusargs("trace")) begin
                    if(rom_req_cs>=5 || rom_req_address>=4194304) held_data=0;
                    else held_data=real_rom[rom_req_cs*4194304+rom_req_address];
                end else if(rom_req_cs!=0 || rom_req_address>=1048576) held_data=0;
                else if(rom_req_address<32768) held_data=(rom_req_address%11)|(((rom_req_address+3)%11)<<4);
                else held_data=(rom_req_address*73+(rom_req_address>>8)+19)&255;
                if(held_data!=rvalue[index]) $fatal(1,"ROM responder disagrees with fixed synthetic ROM");
                if($test$plusargs("damage_rom") && cases==2 && index==0) held_data=held_data^1;
                pending=1;delay_left=delay_mode;index=index+1;
            end
        end
    end
    always @(negedge clk) begin
        rom_rsp_valid=0;
        if(pending) begin
            if(delay_left==0) begin rom_rsp_valid=1;rom_rsp_data=8'(held_data);end
            else delay_left=delay_left-1;
        end
    end
    initial begin
        if($test$plusargs("trace")) begin
            cmd_voice=63;rom_fd=$fopen("decoded-wave.bin","rb");if(!rom_fd) $fatal(1,"Missing decoded ROM");
            rom_size=$fread(real_rom,rom_fd);$fclose(rom_fd);if(rom_size!=20971520) $fatal(1,"Wrong decoded ROM size");
        end
        fd=$fopen("vectors.txt","r");if(!fd) $fatal(1,"Missing vectors");
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d",op);if(fields!=1) $fatal(1,"Malformed operation");
            case(op)
                0:begin
                    reset_core();
                    fields=$fscanf(fd,"%d %d %d %d %d\n",cmd_irq_status,cmd_irq_mask,cmd_irq_interrupt,cmd_descriptors,cmd_physical16);
                    if(fields!=5) $fatal(1,"Malformed reset");cases=cases+1;
                end
                1:begin
                    fields=$fscanf(fd,"%d %d %d\n",v,w,data);if(fields!=3) $fatal(1,"Malformed write");
                    config_access(1,v,w,($test$plusargs("damage_state") && cases==2 && w==31) ? data^1 : data);
                    if(cases==2 && v==0 && w<51) reset_seed[0][w]=data;
                end
                2:begin
                    fields=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d\n",cmd_frame,cmd_pair,exp_status,exp_interrupt,exp_blocked,exp_due,exp_s0,exp_s1,exp_o0,exp_o1,nreads);
                    if(fields!=11 || nreads>64) $fatal(1,"Malformed command");
                    for(integer n=0;n<nreads;n=n+1) begin
                        fields=$fscanf(fd,"%d %d %d %d\n",rcs[n],raddr[n],rpartner[n],rvalue[n]);if(fields!=4) $fatal(1,"Malformed ROM row");
                    end
                    if(cases==2 && cmd_frame==0 && $test$plusargs("duplicate_rom")) begin
                        for(integer n=nreads;n>0;n=n-1) begin rcs[n]=rcs[n-1];raddr[n]=raddr[n-1];rpartner[n]=rpartner[n-1];rvalue[n]=rvalue[n-1];end
                        nreads=nreads+1;
                    end
                    if(cases==2 && cmd_frame==0 && $test$plusargs("missing_rom")) nreads=nreads-1;
                    if(cases==2 && (cmd_frame==0 || cmd_frame==3)) begin
                        fixture=cmd_frame==0 ? 0 : 1;reset_nreads[fixture]=nreads;
                        for(integer n=0;n<nreads;n=n+1) begin reset_cs[fixture][n]=rcs[n];reset_address[fixture][n]=raddr[n];reset_value[fixture][n]=rvalue[n];end
                    end
                    index=0;responses=0;case(count%4) 0:delay_mode=0;1:delay_mode=1;2:delay_mode=7;3:delay_mode=31;endcase
                    if(!$test$plusargs("stalls")) delay_mode=0;
                    @(negedge clk);#1;if(!cmd_ready) $fatal(1,"Command not ready");
                    if($test$plusargs("phase_error")) cmd_frame=cmd_frame^64'd8;
                    cmd_valid=1;rom_req_ready=1;cmd_irq_accepted=0;cmd_irq_blocked=0;
                    @(negedge clk);#1;cmd_valid=0;cycles=0;
                    while(!done_valid) begin
                        if(cmd_ready || cfg_ready) $fatal(1,"Core accepted overlapping transaction");
                        @(negedge clk);#1;cycles=cycles+1;
                        rom_req_ready=!$test$plusargs("stalls") || cycles%5!=0;
                        if(cycles>1000) $fatal(1,"Voice timeout");
                    end
                    if(stage_enable && stage_index!=stage_count) $fatal(1,"Missing numeric stage frame=%0d",count);
                    if(index!=nreads || responses!=nreads || pending) $fatal(1,"ROM count mismatch");
                    if(cmd_pair) begin if(cycles>pair_worst) pair_worst=cycles;end
                    else if(cycles>single_worst) begin single_worst=cycles;$display("VOICE_CYCLE_PEAK frame=%0d cycles=%0d",cmd_frame,cycles);end
                    if(done_frame!==cmd_frame || done_voice!==cmd_voice || done_irq_status!==16'(exp_status) || done_irq_interrupt!==1'(exp_interrupt) || done_irq_blocked!==1'(exp_blocked) ||
                       done_filter_due!==2'(exp_due) || done_sample_owner!==20'(exp_s0) || done_sample_partner!==20'(exp_s1) || done_output_owner!==24'(exp_o0) || done_output_partner!==24'(exp_o1) ||
                       done_prior_owner!==prior0 || done_prior_partner!==(cmd_pair ? prior1 : 24'd0))
                        $fatal(1,"VOICE_RESULT_DIFFERENCE frame=%0d time=%0d pair=%b irq=%h/%h flags=%b%b/%0d%0d sample=%h,%h/%h,%h output=%h,%h/%h,%h prior=%h,%h/%h,%h",count,cmd_frame,cmd_pair,done_irq_status,16'(exp_status),done_irq_interrupt,done_irq_blocked,exp_interrupt,exp_blocked,done_sample_owner,done_sample_partner,20'(exp_s0),20'(exp_s1),done_output_owner,done_output_partner,24'(exp_o0),24'(exp_o1),done_prior_owner,done_prior_partner,prior0,prior1);
                    cmd_irq_status=done_irq_status;cmd_irq_interrupt=done_irq_interrupt;prior0=done_output_owner;prior1=done_output_partner;
                    repeat(count%4) begin @(negedge clk);#1;if(!done_valid || cmd_ready) $fatal(1,"Done backpressure");end
                    done_ready=1;@(negedge clk);#1;done_ready=0;rom_req_ready=0;count=count+1;
                end
                3:begin
                    fields=$fscanf(fd,"%d %d %d\n",v,w,data);if(fields!=3) $fatal(1,"Malformed assertion");
                    config_access(0,v,w,0);
                    if(cases==2 && count==259 && v==0 && w<51) reset_seed[1][w]=readback;
                    if(readback!==data) $fatal(1,"VOICE_STATE_DIFFERENCE frame=%0d voice=%0d word=%0d got=%h expected=%h",count-1,v,w,readback,data);
                    if(w<2 && v==cmd_voice && (w==0 ? done_source_owner[39:20] : done_source_owner[19:0])!==20'(data)) $fatal(1,"Owner source feedback differs from final state");
                    if(w<2 && cmd_pair && v==cmd_voice+1 && (w==0 ? done_source_partner[39:20] : done_source_partner[19:0])!==20'(data)) $fatal(1,"Partner source feedback differs from final state");
                end
                4:begin fields=$fscanf(fd,"%d\n",data);cmd_irq_interrupt=0;end
                5:begin
                    fields=$fscanf(fd,"%d\n",data);
                    config_access(0,0,47,0);
                    if(readback!=0 && data==0) begin config_access(1,0,46,0);config_access(1,0,49,0);end
                    config_access(1,0,47,data);
                end
                6:begin
                    fields=$fscanf(fd,"%d\n",data);config_access(0,0,47,0);
                    if(readback!=0) begin
                        config_access(0,0,46,0);
                        if(readback==0) begin config_access(1,0,46,1);config_access(1,0,49,1);end
                    end
                end
                7:begin fields=$fscanf(fd,"%d\n",data);reset_core();cmd_irq_mask=0;cmd_descriptors=0;end
                8:begin
                    fields=$fscanf(fd,"%d\n",stage_count);if(fields!=1 || stage_count>8) $fatal(1,"Malformed stage count");
                    stage_index=0;stage_enable=1;
                    for(integer n=0;n<stage_count;n=n+1) begin
                        fields=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d\n",stage_kind[n],stage_voice[n],stage_value[n][0],stage_value[n][1],stage_value[n][2],stage_value[n][3],stage_value[n][4],stage_value[n][5],stage_value[n][6],stage_value[n][7]);
                        if(fields!=10) $fatal(1,"Malformed stage row");
                    end
                end
                default:$fatal(1,"Unknown operation");
            endcase
        end
        $fclose(fd);stage_enable=0;
        if(!$test$plusargs("trace") && !$test$plusargs("pressure")) for(integer seed=0;seed<2;seed=seed+1) for(integer pair_mode=0;pair_mode<2;pair_mode=pair_mode+1) for(integer position=0;position<128;position=position+1) begin
            reset_core();cmd_irq_mask=0;cmd_descriptors=1;cmd_physical16=1;
            for(integer voice=0;voice<=pair_mode;voice=voice+1) for(integer word=0;word<51;word=word+1) config_access(1,voice,word,reset_seed[seed][word]);
            if(pair_mode!=0) config_access(1,0,23,20'h01010);
            nreads=reset_nreads[seed]*(pair_mode+1);
            for(integer voice=0;voice<=pair_mode;voice=voice+1) for(integer n=0;n<reset_nreads[seed];n=n+1) begin
                rcs[voice*reset_nreads[seed]+n]=reset_cs[seed][n];raddr[voice*reset_nreads[seed]+n]=reset_address[seed][n];
                rvalue[voice*reset_nreads[seed]+n]=reset_value[seed][n];rpartner[voice*reset_nreads[seed]+n]=voice;
            end
            index=0;responses=0;delay_mode=position%8;
            @(negedge clk);#1;cmd_frame=seed==0 ? 0 : 3;cmd_pair=1'(pair_mode);cmd_valid=1;rom_req_ready=1;
            @(negedge clk);#1;cmd_valid=0;
            repeat(position) begin @(negedge clk);#1;end
            reset_core();
            for(integer voice=0;voice<2;voice=voice+1) for(integer word=0;word<64;word=word+1) begin
                config_access(0,voice,word,0);if(readback!==0) $fatal(1,"Reset state not cleared voice=%0d word=%0d",voice,word);
            end
            @(negedge clk);#1;cmd_pair=0;cmd_valid=1;
            @(negedge clk);#1;cmd_valid=0;cycles=0;
            while(!done_valid) begin @(negedge clk);#1;cycles=cycles+1;if(cycles>44) $fatal(1,"Reset recovery timeout");end
            if(done_output_owner!==0 || done_output_partner!==0 || done_sample_owner!==0 || done_filter_due!==0 || done_irq_interrupt || rom_req_valid) $fatal(1,"Reset leaked old work");
            done_ready=1;@(negedge clk);#1;done_ready=0;reset_checks=reset_checks+1;
        end
        if(!$test$plusargs("trace") && !$test$plusargs("pressure")) begin
            config_access(1,63,0,-1);if(readback!==32'hfffff) $fatal(1,"Config mask failed");
            config_access(0,63,0,0);if(readback!==32'hfffff) $fatal(1,"Config readback failed");
            config_access(1,63,63,-1);if(readback!==0) $fatal(1,"Reserved write response");
            config_access(0,63,63,0);if(readback!==0) $fatal(1,"Reserved word changed");
            @(negedge clk);#1;cfg_valid=1;cfg_write=1;cfg_voice=63;cfg_word=0;cfg_wdata=0;cmd_valid=1;
            #1;if(cmd_ready || !cfg_ready) $fatal(1,"Config priority failed");
            @(negedge clk);#1;cfg_valid=0;cmd_valid=0;
            repeat(4) begin
                @(negedge clk);#1;if(!cfg_rsp_valid || cfg_ready || cmd_ready || cfg_rsp_data!==0 || done_valid) $fatal(1,"Config response backpressure");
            end
            cfg_rsp_ready=1;@(negedge clk);#1;cfg_rsp_ready=0;
            if(!cmd_ready) $fatal(1,"Config did not release command port");
            $display("VOICE_CONFIG_PASS");
        end
        $display("VOICE_STAGES_PASS count=%0d",stage_total);
        $display("VOICE_RESET_PASS checks=%0d",reset_checks);
        $display("VOICE_SYNTHETIC_PASS cases=%0d frames=%0d single_cycles=%0d pair_cycles=%0d",cases,count,single_worst,pair_worst);$finish;
    end
    initial begin #(64'd3000000000);$fatal(1,"Watchdog");end
endmodule
