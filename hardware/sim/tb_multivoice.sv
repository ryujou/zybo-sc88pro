// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_multivoice # (parameter integer VOICE_LIMIT=1);
    logic clk=0,rst=1,soft_reset=0,ready,bus_idle,frame_valid=0,frame_ready;
    logic [63:0] frame_id=0,frame_descriptors=0,done_frame,out_frame,out_data;
    logic [5:0] frame_highest_voice=0,cfg_voice=0,cfg_word=0;
    logic [15:0] frame_irq_status=0,frame_irq_mask=0,done_irq_status;
    logic frame_irq_interrupt=0,done_irq_interrupt,done_irq_blocked;
    logic [7:0] frame_physical16=8'h1f,fault;
    logic [31:0] frame_bank_shifts=0,cfg_wdata=0,cfg_rsp_data;
    logic cfg_valid=0,cfg_write=0,cfg_rsp_ready=0,cfg_ready,cfg_rsp_valid;
    logic done_valid,done_ready=0,out_valid,out_ready,out_first,out_last,consume_tick=0,output_enable=0;
    logic [12:0] done_cycles;
    logic [31:0] frames,max_frame_cycles,cache_hits,cache_misses,unmapped_reads;
    logic [31:0] axi_bursts,axi_errors,timeouts,overruns,output_underruns;
    logic [1:0] fifo_level,fifo_high_water;
    logic m_axi_arvalid,m_axi_arready=0,m_axi_arlock;
    logic [31:0] m_axi_araddr;
    logic [5:0] m_axi_arid,m_axi_rid=0;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize,m_axi_arprot;
    logic [1:0] m_axi_arburst,m_axi_rresp=0;
    logic [3:0] m_axi_arcache;
    logic m_axi_rvalid=0,m_axi_rready,m_axi_rlast=0;
    logic [63:0] m_axi_rdata=0;
    integer fd,fields,command,a,b,c,d,e,nreads,nrecords,case_count=0,frame_count=0,read_count=0,record_count=0,worst=0;
    logic [63:0] descriptor_value,expected_records [0:1][0:319],expected_record_frame[0:1];
    integer expected_record_count[0:1],record_index[0:1];
    logic [63:0] output_frame_expected=0;
    integer expected_voice [0:4095],expected_cs [0:4095],expected_address [0:4095],expected_byte [0:4095];
    integer read_index=0,pending_byte,case_reads=0;
    integer ncommands,command_index=0,expected_command_voice[0:63],expected_pair[0:63],start_cycle=0;
    logic pending_rom=0,checking=0;
    logic [31:0] queue [0:65535];
    integer earliest [0:65535];
    integer accepted_cycle [0:65535];
    integer issued=0,responded=0,bus_cycles=0,beat=0,gap=0;
    logic r_fire=0;
    logic recovery_mode=0;
    logic address_injected=0;
    integer latency_override=0;
    integer ar_wait=0,last_r_cycle=0,max_ar_wait=0,max_r_latency=0,max_r_gap=0;
    integer output_pause=0,output_stalls=0;
    logic stress_latency=0,stress_gaps=0,stress_mixed=0,output_stalled=0;
    logic [129:0] held_output;
    logic periodic=0;
    integer next_due=-1,due_cycle=0;
    logic frame_due_seen=0;
    logic lifecycle_mode=0;
    assign out_ready=output_enable && !((stress_latency || stress_gaps || stress_mixed) && out_valid && out_first && output_pause<8);
    pcm_voice_scheduler #(.VOICE_LIMIT(VOICE_LIMIT)) dut(.*);
    always #5 clk=~clk;
    function automatic logic [7:0] byte_for(input logic [31:0] offset);
        byte_for=8'((offset*73+(offset>>7)*19+32'h35)^(offset>>13));
    endfunction
    function automatic logic [31:0] state_word(input integer voice,input integer word);
        integer address;
        address=voice*8+word/8;
        case(word%8)
            0:state_word=dut.voice_core.storage.banks[0].words[address];
            1:state_word=dut.voice_core.storage.banks[1].words[address];
            2:state_word=dut.voice_core.storage.banks[2].words[address];
            3:state_word=dut.voice_core.storage.banks[3].words[address];
            4:state_word=dut.voice_core.storage.banks[4].words[address];
            5:state_word=dut.voice_core.storage.banks[5].words[address];
            6:state_word=dut.voice_core.storage.banks[6].words[address];
            7:state_word=dut.voice_core.storage.banks[7].words[address];
        endcase
    endfunction
    always @(posedge clk) begin
        if(rst) begin issued=0;bus_cycles=0;r_fire=0;pending_rom=0;case_reads=0;ar_wait=0;last_r_cycle=0;output_pause<=0;output_stalled=0;output_frame_expected=0;frame_due_seen=0;end
        else begin
            bus_cycles=bus_cycles+1;
            if(m_axi_arvalid && !m_axi_arready) ar_wait=ar_wait+1;
            if(m_axi_arvalid && m_axi_arready) begin
                if(m_axi_araddr<32'h10000000 || m_axi_araddr>=32'h11400000 || m_axi_araddr[4:0]!=0 || m_axi_arlen!=3 || m_axi_arsize!=3 || m_axi_arid!=0) $fatal(1,"AXI mapping/protocol");
                if(ar_wait>max_ar_wait) max_ar_wait=ar_wait;
                if((stress_latency || stress_gaps || stress_mixed) && ar_wait>7) $fatal(1,"BFM exceeded AR stall envelope");
                ar_wait=0;accepted_cycle[issued]=bus_cycles;
                queue[issued]=m_axi_araddr;earliest[issued]=bus_cycles+(latency_override!=0 ? latency_override : (stress_latency || stress_mixed) ? 31 : stress_gaps ? 0 : 8);issued=issued+1;
            end
            r_fire=m_axi_rvalid && m_axi_rready;
            if(r_fire && !recovery_mode) begin
                if(beat==0) begin
                    if(bus_cycles-accepted_cycle[responded]>max_r_latency) max_r_latency=bus_cycles-accepted_cycle[responded];
                    if((stress_latency || stress_gaps || stress_mixed) && bus_cycles-accepted_cycle[responded]>32) $fatal(1,"BFM exceeded first R latency envelope");
                end else begin
                    if(bus_cycles-last_r_cycle-1>max_r_gap) max_r_gap=bus_cycles-last_r_cycle-1;
                    if((stress_latency || stress_gaps || stress_mixed) && bus_cycles-last_r_cycle-1>3) $fatal(1,"BFM exceeded interbeat envelope");
                end
                last_r_cycle=bus_cycles;
            end
            if(out_valid && out_first && !out_ready && output_enable) begin output_pause<=output_pause+1;output_stalls=output_stalls+1;end
            else if(out_valid && out_last && out_ready) output_pause<=0;
            if(output_stalled && !soft_reset && (!out_valid || {out_frame,out_data,out_first,out_last}!==held_output)) $fatal(1,"Output changed under backpressure");
            output_stalled=out_valid && !out_ready && !soft_reset;
            held_output={out_frame,out_data,out_first,out_last};
            if(frame_valid && !frame_due_seen) begin start_cycle=bus_cycles;frame_due_seen=1;end
            if(!frame_valid) frame_due_seen=0;
            if(dut.voice_core.cmd_valid && dut.voice_core.cmd_ready && !recovery_mode) begin
                if(!checking || command_index>=ncommands || dut.voice_core.cmd_frame!==frame_id ||
                   dut.voice_core.cmd_voice!==6'(expected_command_voice[command_index]) || dut.voice_core.cmd_pair!==1'(expected_pair[command_index]))
                    $fatal(1,"VOICE_COMMAND_DIFFERENCE frame=%0d index=%0d voice=%0d",frame_id,command_index,dut.voice_core.cmd_voice);
                command_index=command_index+1;
            end
            if(dut.rom_rsp_valid && dut.rom_rsp_ready && !recovery_mode) begin
                if(!pending_rom || dut.rom_rsp_data!==8'(pending_byte)) $fatal(1,"ROM byte mismatch");
                pending_rom=0;
            end
            if(dut.rom_req_valid && dut.rom_req_ready && !recovery_mode) begin
                if(!checking || read_index>=nreads || pending_rom) $fatal(1,"Unexpected logical ROM request");
                if(dut.active_voice+integer'(dut.rom_req_partner)!=expected_voice[read_index] || dut.rom_req_cs!==3'(expected_cs[read_index]) || dut.rom_req_address!==24'(expected_address[read_index]))
                    $fatal(1,"ROM_ADDRESS_DIFFERENCE frame=%0d index=%0d voice=%0d cs=%0d address=%h expected=%h",frame_id,read_index,dut.active_voice,dut.rom_req_cs,dut.rom_req_address,expected_address[read_index]);
                pending_byte=expected_byte[read_index];pending_rom=1;read_index=read_index+1;read_count=read_count+1;case_reads=case_reads+1;
            end
            if(out_valid && out_ready) begin
                if(!checking || record_index[out_frame[0]]>=expected_record_count[out_frame[0]] || out_frame!==expected_record_frame[out_frame[0]] || out_frame!==output_frame_expected ||
                   out_data!==expected_records[out_frame[0]][record_index[out_frame[0]]] || out_first!==(record_index[out_frame[0]]==0) || out_last!==(record_index[out_frame[0]]==expected_record_count[out_frame[0]]-1))
                    $fatal(1,"FRAME_RECORD_DIFFERENCE frame=%0d record=%0d got=%h expected=%h",out_frame,record_index[out_frame[0]],out_data,expected_records[out_frame[0]][record_index[out_frame[0]]]);
                record_index[out_frame[0]]=record_index[out_frame[0]]+1;record_count=record_count+1;
                if(out_last) output_frame_expected=output_frame_expected+1;
            end
            if(checking && fault!=0 && !lifecycle_mode) $fatal(1,"SCHEDULER_FAULT case=%0d frame=%0d voice=%0d fault=%h elapsed=%0d",case_count,frame_id,dut.active_voice,fault,dut.elapsed);
        end
    end
    always @(negedge clk) begin
        #1;
        if(checking && fault!=0 && $test$plusargs("one_cycle_overrun")) begin
            if(fault!=1 || bus_cycles-start_cycle!=3126 || overruns!=1 || out_valid) $fatal(1,"Incorrect single-cycle deadline detector");
            $fatal(1,"ONE_CYCLE_OVERRUN_DETECTED elapsed=%0d",bus_cycles-start_cycle);
        end
    end
    always @(negedge clk) begin
        if(rst) begin responded=0;beat=0;gap=0;m_axi_arready=0;m_axi_rvalid=0;m_axi_rlast=0;end
        else begin
            m_axi_arready=(stress_latency || stress_gaps || stress_mixed) ? ar_wait>=7 : bus_cycles%5>=1;
            if(r_fire) begin
                if(m_axi_rlast) begin responded=responded+1;beat=0;end
                else beat=beat+1;
                gap=stress_latency ? 0 : stress_gaps ? (beat==0 ? 0 : issued-responded>2 ? 1 : 3) : beat%2;m_axi_rvalid=0;
                if(stress_mixed) begin
                    gap=beat==0 ? 0 : 3;
                    // Keep room for remaining beats and the next accepted burst's first-R deadline.
                    if(beat!=0 && responded+1<issued && accepted_cycle[responded+1]+32-bus_cycles-(4-beat)-1<gap)
                        gap=accepted_cycle[responded+1]+32-bus_cycles-(4-beat)-1;
                    if(gap<0) gap=0;
                end
            end
            if(!m_axi_rvalid) begin
                if(gap>0) gap=gap-1;
                else if(responded<issued && bus_cycles>=earliest[responded]) begin
                    m_axi_rvalid=1;m_axi_rlast=beat==3;
                    for(integer lane=0;lane<8;lane=lane+1) m_axi_rdata[lane*8+:8]=byte_for(queue[responded]-32'h10000000+32'(beat*8+lane));
                end
            end
        end
    end
    task automatic config_access(input logic write_enable,input integer voice,input integer word,input integer value);
        cfg_rsp_ready=1;
        cfg_valid=1;cfg_write=write_enable;cfg_voice=6'(voice);cfg_word=6'(word);cfg_wdata=32'(value);
        do begin @(posedge clk);end while(!cfg_ready);
        @(negedge clk);#1;cfg_valid=0;
        if(write_enable) begin
            if(!cfg_rsp_valid || cfg_rsp_data!==32'(value)) $fatal(1,"Pipelined configuration response differs");
        end else begin
            cfg_rsp_ready=0;
            while(!cfg_rsp_valid) begin @(negedge clk);#1;end
            if(cfg_rsp_data!==32'(value)) $fatal(1,"VOICE_STATE_DIFFERENCE frame=%0d voice=%0d word=%0d got=%h expected=%h",frame_id,voice,word,cfg_rsp_data,32'(value));
            cfg_rsp_ready=1;@(negedge clk);#1;cfg_rsp_ready=0;
        end
    endtask
    task automatic local_restart;
        checking=0;recovery_mode=1;output_enable=0;frame_valid=0;done_ready=0;cfg_valid=0;cfg_rsp_ready=0;
        soft_reset=1;@(negedge clk);#1;soft_reset=0;
        for(integer i=0;!ready;i=i+1) begin
            if(i>1800 || out_valid || done_valid) $fatal(1,"Local restart did not drain and clear responses");
            @(negedge clk);#1;
        end
        if(fault || frames || max_frame_cycles || cache_hits || cache_misses || unmapped_reads || axi_bursts || axi_errors || timeouts || overruns || output_underruns || fifo_level || fifo_high_water || !dut.fetch_idle || issued!=responded)
            $fatal(1,"Local restart retained traffic or statistics");
        for(integer voice=0;voice<64;voice=voice+1)
            for(integer word=0;word<51;word=word+1)
                if(state_word(voice,word)!==0) $fatal(1,"Local restart retained Voice state");
        for(integer bank=0;bank<2;bank=bank+1) begin record_index[bank]=0;expected_record_count[bank]=0;end
        output_frame_expected=0;
    endtask
    task automatic silent_frame(input integer id,input logic drain);
        integer slot;
        frame_id=64'(id);frame_highest_voice=6'(VOICE_LIMIT-1);frame_irq_status=0;frame_irq_interrupt=0;
        frame_irq_mask=0;frame_descriptors=0;nreads=0;read_index=0;ncommands=VOICE_LIMIT;command_index=0;nrecords=4*VOICE_LIMIT+64;
        expected_record_frame[id%2]=64'(id);expected_record_count[id%2]=nrecords;record_index[id%2]=0;
        for(integer voice=0;voice<VOICE_LIMIT;voice=voice+1) begin
            expected_command_voice[voice]=voice;expected_pair[voice]=0;
            for(integer send=0;send<4;send=send+1) begin
                slot=4*voice+(send==0 ? 0 : send==3 ? 3 : 2);
                expected_records[id%2][4*voice+send]=(64'(slot)<<54)|(64'(voice)<<48)|(64'(send)<<46);
            end
        end
        for(integer dest=0;dest<64;dest=dest+1)
            expected_records[id%2][4*VOICE_LIMIT+dest]=(64'd1<<63)|(64'(dest==0)<<62)|(64'(dest)<<40);
        checking=1;recovery_mode=0;frame_valid=1;output_enable=drain;
        do begin @(posedge clk);end while(!frame_ready);
        @(negedge clk);#1;frame_valid=0;
        for(integer i=0;!done_valid;i=i+1) begin
            if(i>3125 || fault) $fatal(1,"Silent frame did not complete");
            @(negedge clk);#1;
        end
        if(command_index!=ncommands || done_frame!==64'(id) || done_irq_status || done_irq_interrupt || done_irq_blocked || done_cycles>3125)
            $fatal(1,"Silent completion differs");
        done_ready=1;@(negedge clk);#1;done_ready=0;
        if(drain) begin
            while(record_index[id%2]<nrecords) begin @(negedge clk);#1;end
            checking=0;output_enable=0;
        end
    endtask
    task automatic lifecycle_test;
        logic reached;
        lifecycle_mode=1;stress_latency=1;
        repeat(2) @(negedge clk);#1;rst=0;
        while(!ready) begin @(negedge clk);#1;end
        silent_frame(0,0);silent_frame(1,0);
        if(fifo_level!=2 || fifo_high_water!=2 || frames!=2) $fatal(1,"Whole-frame FIFO did not fill");
        frame_id=2;frame_valid=1;ncommands=0;command_index=0;
        for(integer i=0;fault==0;i=i+1) begin
            if(frame_ready || i>3128) $fatal(1,"Full FIFO admitted or hid a due frame");
            @(negedge clk);#1;
        end
        if(fault!=1 || overruns!=1 || frames!=2 || fifo_level!=2 || bus_cycles-start_cycle!=3126)
            $fatal(1,"Full FIFO deadline accounting differs");
        frame_valid=0;output_enable=1;
        for(integer i=0;record_index[0]<nrecords || record_index[1]<nrecords;i=i+1) begin
            if(i>1400) $fatal(1,"Committed frames could not drain after admission failure");
            @(negedge clk);#1;
        end
        if(!dut.fifo_empty || fifo_level!=0) $fatal(1,"Drained FIFO was not empty");
        local_restart();
        consume_tick=1;@(negedge clk);#1;consume_tick=0;
        if(output_underruns!=1 || fault || frames) $fatal(1,"Empty consumer request statistics differ");
        for(integer position=0;position<8;position=position+1) begin
            local_restart();
            if(position==7) begin
                cfg_valid=1;cfg_write=0;cfg_voice=0;cfg_word=0;cfg_rsp_ready=0;
                do begin @(posedge clk);end while(!cfg_ready);
                @(negedge clk);#1;cfg_valid=0;
                while(!cfg_rsp_valid) begin @(negedge clk);#1;end
            end else begin
                frame_descriptors=64'h0101010101;frame_irq_mask=16'h1ff;
                config_access(1,0,1,20'h40030);config_access(1,0,2,20'h40040);config_access(1,0,3,20'h4007f);
                config_access(1,0,46,1);config_access(1,0,47,1);config_access(1,0,49,1);
                frame_id=0;frame_highest_voice=6'(VOICE_LIMIT-1);frame_valid=1;
                do begin @(posedge clk);end while(!frame_ready);
                @(negedge clk);#1;frame_valid=0;reached=0;
                for(integer i=0;!reached;i=i+1) begin
                    case(position)
                        0:reached=dut.core_done_ready && !dut.core_done_valid;
                        1:reached=m_axi_arvalid && !m_axi_arready;
                        2:reached=m_axi_rvalid && !m_axi_rlast;
                        3:reached=dut.cache.fill_busy;
                        4:reached=dut.send_valid;
                        5:reached=dut.mix_valid;
                        6:reached=out_valid && !out_ready;
                    endcase
                    if(fault || i>3125) $fatal(1,"Reset position was not reached position=%0d",position);
                    if(!reached) begin @(negedge clk);#1;end
                end
            end
            local_restart();silent_frame(0,1);
        end
        $display("MULTIVOICE_LIFECYCLE_PASS full_fifo_frames=2 admission_deadline=3126 reset_positions=8 fresh_frames=8 underrun=1");
    endtask
    task automatic recovery_test;
        recovery_mode=1;latency_override=1500;
        repeat(2) @(negedge clk);#1;rst=0;
        while(!ready) begin @(negedge clk);#1;end
        frame_descriptors=64'h0101010101;frame_irq_mask=16'h1ff;
        config_access(1,0,1,20'h40030);config_access(1,0,2,20'h40040);config_access(1,0,3,20'h4007f);
        config_access(1,0,46,1);config_access(1,0,47,1);config_access(1,0,49,1);
        frame_valid=1;
        do begin @(posedge clk);end while(!frame_ready);
        @(negedge clk);#1;frame_valid=0;
        for(integer i=0;fault==0;i=i+1) begin
            if(i>1200) $fatal(1,"Missing timeout fault");
            @(negedge clk);#1;
        end
        if(timeouts!=1 || done_valid || out_valid) $fatal(1,"Timeout published a frame");
        soft_reset=1;@(negedge clk);#1;soft_reset=0;latency_override=0;
        for(integer i=0;!ready;i=i+1) begin
            if(i>1800) $fatal(1,"LOCAL_RESET_RECOVERY_FAILED state=%0d bus_fault=%h cache_ready=%b",dut.state,dut.bus_fault,dut.cache_ready);
            if(done_valid || out_valid) $fatal(1,"Old frame exposed after reset");
            @(negedge clk);#1;
        end
        if(fault || timeouts || overruns || frames || fifo_level) $fatal(1,"Reset status not cleared fault=%h timeouts=%0d overruns=%0d frames=%0d level=%0d",fault,timeouts,overruns,frames,fifo_level);
        for(integer word=0;word<51;word=word+1) config_access(0,0,word,0);
        frame_id=0;frame_highest_voice=0;frame_irq_status=0;frame_irq_interrupt=0;
        nreads=0;nrecords=68;read_index=0;record_index[0]=0;expected_record_count[0]=68;expected_record_frame[0]=0;ncommands=1;command_index=0;expected_command_voice[0]=0;expected_pair[0]=0;checking=1;recovery_mode=0;
        for(integer send=0;send<4;send=send+1)
            expected_records[0][send]=(64'(send==0 ? 0 : send==3 ? 3 : 2)<<54)|(64'(send)<<46);
        for(integer destination=0;destination<64;destination=destination+1)
            expected_records[0][4+destination]=(64'd1<<63)|(64'(destination==0)<<62)|(64'(destination)<<40);
        frame_valid=1;output_enable=1;
        do begin @(posedge clk);end while(!frame_ready);
        @(negedge clk);#1;frame_valid=0;
        while(!done_valid) begin @(negedge clk);#1;end
        done_ready=1;@(negedge clk);#1;done_ready=0;
        while(record_index[0]<nrecords) begin @(negedge clk);#1;end
        $display("MULTIVOICE_RECOVERY_PASS timeout_drain_and_fresh_frame=1");
    endtask
    initial begin
        stress_latency=$test$plusargs("stress_latency");stress_gaps=$test$plusargs("stress_gaps");
        stress_mixed=$test$plusargs("stress_mixed");
        periodic=$test$plusargs("periodic");
        for(integer bank=0;bank<2;bank=bank+1) begin record_index[bank]=0;expected_record_count[bank]=0;expected_record_frame[bank]=0;end
        if($test$plusargs("lifecycle")) begin lifecycle_test();$finish;end
        if($test$plusargs("recovery")) begin recovery_test();$finish;end
        if($test$plusargs("missing_voice")) begin
            force dut.voice_core.cmd_valid=0;force dut.core_done_valid=1;
            fork begin
                wait(dut.core_done_ready);@(posedge clk);@(negedge clk);
                release dut.voice_core.cmd_valid;release dut.core_done_valid;
            end join_none
        end
        if($test$plusargs("one_cycle_overrun")) force dut.mixer_done=0;
        fd=$fopen("vectors.txt","r");if(!fd) $fatal(1,"Missing vectors");
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d",command);if(fields!=1) $fatal(1,"Malformed command");
            case(command)
                0:begin
                    fields=$fscanf(fd,"%d %d %d %d\n",a,b,c,descriptor_value);if(fields!=4) $fatal(1,"Malformed reset");
                    for(integer bank=0;bank<2;bank=bank+1) begin
                        while(record_index[bank]<expected_record_count[bank]) begin @(negedge clk);#1;end
                        record_index[bank]=0;expected_record_count[bank]=0;
                    end
                    next_due=-1;
                    @(negedge clk);#1;rst=1;checking=0;output_enable=0;done_ready=0;
                    frame_irq_status=16'(a);frame_irq_mask=16'(b);frame_irq_interrupt=1'(c);frame_descriptors=descriptor_value;
                    repeat(2) @(negedge clk);#1;rst=0;
                    while(!ready) begin @(negedge clk);#1;end
                    case_count=case_count+1;
                end
                1,3:begin
                    fields=$fscanf(fd,"%d %d %d\n",a,b,c);if(fields!=3) $fatal(1,"Malformed config");
                    if(command==3 && periodic) begin
                        if(state_word(a,b)!==32'(c)) $fatal(1,"VOICE_STATE_DIFFERENCE frame=%0d voice=%0d word=%0d got=%h expected=%h",frame_id,a,b,state_word(a,b),32'(c));
                    end else config_access(command==1,a,b,c);
                end
                4:begin fields=$fscanf(fd,"%d\n",a);frame_irq_interrupt=1'(a);end
                2:begin
                    fields=$fscanf(fd,"%d %d %d %d %d %d %d %d\n",a,b,c,d,e,nreads,nrecords,ncommands);if(fields!=8) $fatal(1,"Malformed frame");
                    for(integer i=0;i<nreads;i=i+1) begin
                        fields=$fscanf(fd,"%d %d %d %d\n",expected_voice[i],expected_cs[i],expected_address[i],expected_byte[i]);if(fields!=4) $fatal(1,"Malformed ROM expectations");
                    end
                    for(integer i=0;i<ncommands;i=i+1) begin
                        fields=$fscanf(fd,"%d %d\n",expected_command_voice[i],expected_pair[i]);if(fields!=2) $fatal(1,"Malformed schedule");
                    end
                    if(record_index[a%2]!=expected_record_count[a%2]) $fatal(1,"Expected-result bank reused before consumption");
                    expected_record_count[a%2]=nrecords;expected_record_frame[a%2]=64'(a);record_index[a%2]=0;
                    for(integer i=0;i<nrecords;i=i+1) begin fields=$fscanf(fd,"%h\n",expected_records[a%2][i]);if(fields!=1) $fatal(1,"Malformed record");end
                    frame_id=64'(a);frame_highest_voice=6'(b);read_index=0;command_index=0;checking=1;
                    if($test$plusargs("wrong_address") && nreads>0 && !address_injected) begin
                        address_injected=1;force dut.fetch_address=32'h10000020;
                        fork begin
                            wait(dut.fetch_valid && dut.fetch_ready);@(posedge clk);@(negedge clk);release dut.fetch_address;
                        end join_none
                    end
                    if(periodic) begin
                        if(next_due<0) next_due=bus_cycles+1;
                        while(bus_cycles+1<next_due) begin @(negedge clk);#1;end
                        if(bus_cycles+1!=next_due) $fatal(1,"PERIODIC_ADMISSION_LATE case=%0d frame=%0d due=%0d now=%0d",case_count,frame_id,next_due,bus_cycles+1);
                        due_cycle=next_due;next_due=next_due+3125;
                    end
                    frame_valid=1;output_enable=1;
                    do begin @(posedge clk);end while(!frame_ready);
                    @(negedge clk);#1;frame_valid=0;
                    while(!done_valid) begin @(negedge clk);#1;end
                    if(command_index!=ncommands) $fatal(1,"FRAME_COMMAND_COUNT_DIFFERENCE frame=%0d commands=%0d expected=%0d",frame_id,command_index,ncommands);
                    if(done_frame!==frame_id || done_irq_status!==16'(c) || done_irq_interrupt!==1'(d) || done_irq_blocked!==1'(e) || read_index!=nreads || pending_rom)
                        $fatal(1,"FRAME_COMPLETION_DIFFERENCE frame=%0d IRQ=%h/%h interrupt=%b/%0d blocked=%b/%0d reads=%0d/%0d",frame_id,done_irq_status,16'(c),done_irq_interrupt,d,done_irq_blocked,e,read_index,nreads);
                    if(done_cycles>3125) $fatal(1,"Frame deadline");
                    if(periodic && done_cycles!=bus_cycles-due_cycle) $fatal(1,"Deadline statistic excluded admission wait");
                    if(cache_hits+cache_misses+unmapped_reads!=case_reads) $fatal(1,"Cache request counters differ from logical reads");
                    if(done_cycles>worst) worst=done_cycles;
                    frame_irq_status=done_irq_status;frame_irq_interrupt=done_irq_interrupt;
                    done_ready=1;@(negedge clk);#1;done_ready=0;
                    if(!periodic) begin
                        while(record_index[frame_id[0]]<nrecords) begin @(negedge clk);#1;end
                        checking=0;output_enable=0;
                    end
                    frame_count=frame_count+1;
                end
                default:$fatal(1,"Unknown command");
            endcase
        end
        $fclose(fd);
        for(integer bank=0;bank<2;bank=bank+1)
            while(record_index[bank]<expected_record_count[bank]) begin @(negedge clk);#1;end
        if(periodic) $display("MULTIVOICE_PERIODIC frames=%0d period=3125",frame_count);
        $display("MULTIVOICE_BUS ar_stall_max=%0d first_r_max=%0d interbeat_gap_max=%0d output_stalls=%0d",max_ar_wait,max_r_latency,max_r_gap,output_stalls);
        $display("MULTIVOICE_PASS cases=%0d frames=%0d reads=%0d records=%0d worst_cycles=%0d",case_count,frame_count,read_count,record_count,worst);
        $finish;
    end
    initial begin #(64'd1000000000);$fatal(1,"Multivoice watchdog");end
endmodule
