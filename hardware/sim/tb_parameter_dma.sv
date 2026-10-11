// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_parameter_dma;
    logic clk=0,rst=1,flush=0,fetch_idle=1,ready,desc_valid=0,desc_ready;
    logic [63:0] desc_frame=0,begin_frame=0,req_frame=0,param_frame;
    logic [31:0] desc_address=32'h12000000,fetch_address,cfg_data;
    logic [14:0] desc_bytes=0;
    logic fetch_valid,fetch_ready=1,line_valid=0,line_ready,begin_valid=0,begin_ready;
    logic [10:0] fetch_tag,line_tag;
    logic [255:0] line_data;
    logic [3:0] line_error=0;
    logic cfg_valid,cfg_ready=0,cfg_done,req_valid=0,param_valid,param_ready=0,param_terminal,audio_done=0,finish_valid=0,complete;
    logic [5:0] cfg_voice,cfg_word,req_voice=0,param_voice;
    logic [2:0] req_stage=0,param_stage,param_reason;
    logic [21:0] param_mask;
    logic [703:0] param_values;
    logic [7:0] fault;
    logic [31:0] bursts,config_words,packets,noops;
    logic [255:0] memory[0:511];
    logic [10:0] tags[0:511];
    integer issued=0,returned=0,cycles=0,fd,nlines,negative,reject_config,fields,a,b,c,expected_cfg=0,cfg_index=0,hooks,mask,terminal,cases=0;
    integer cfg_voices[0:63],cfg_words[0:63],cfg_values[0:63],expected_packets;
    logic [703:0] expected_values;
    logic [31:0] lane;
    pcm_parameter_dma dut(.*);
    always #5 clk=~clk;
    always @(posedge clk) begin
        if(rst) begin issued=0;returned=0;cycles=0;cfg_index=0;end
        else begin
            cycles=cycles+1;
            if(fetch_valid && fetch_ready) begin
                if(fetch_address!==32'h12000000+32'(issued*32) || fetch_tag!==11'h400+11'(issued)) $fatal(1,"DMA request differs");
                tags[issued]=fetch_tag;issued=issued+1;
            end
            if(line_valid && line_ready) returned=returned+1;
            if(reject_config && cfg_valid) $fatal(1,"Malformed configuration published case=%0d",cases);
            if(cfg_valid && cfg_ready && !negative) begin
                if(cfg_index>=expected_cfg || cfg_voice!==6'(cfg_voices[cfg_index]) || cfg_word!==6'(cfg_words[cfg_index]) || cfg_data!==32'(cfg_values[cfg_index])) $fatal(1,"DMA cfg differs index=%0d",cfg_index);
                cfg_index=cfg_index+1;
            end
        end
    end
    always @(negedge clk) begin
        line_valid=!rst && returned<issued && cycles%3!=0;
        if(line_valid) begin line_tag=tags[returned];line_data=memory[returned];end
        cfg_ready=!rst && cycles%7!=0;
    end
    initial begin
        fd=$fopen("vectors.txt","r");if(!fd) $fatal(1,"Missing DMA vectors");
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d %d %d %d\n",nlines,negative,desc_frame,reject_config);if(fields!=4) $fatal(1,"Malformed DMA test");
            begin_frame=desc_frame;req_frame=desc_frame;expected_packets=0;
            for(integer i=0;i<nlines;i=i+1) begin fields=$fscanf(fd,"%h\n",memory[i]);if(fields!=1) $fatal(1,"Malformed DMA data");end
            if(!negative) begin
                fields=$fscanf(fd,"%d\n",expected_cfg);
                for(integer i=0;i<expected_cfg;i=i+1) fields=$fscanf(fd,"%d %d %d\n",cfg_voices[i],cfg_words[i],cfg_values[i]);
            end
            @(negedge clk);#1;rst=1;desc_valid=0;begin_valid=0;req_valid=0;param_ready=0;audio_done=0;finish_valid=0;
            repeat(2) @(negedge clk);#1;rst=0;
            while(!ready) begin @(negedge clk);#1;end
            desc_bytes=15'(nlines*32);desc_valid=1;
            do begin @(posedge clk);end while(!desc_ready);
            @(negedge clk);#1;desc_valid=0;
            for(integer i=0;!begin_ready && !fault;i=i+1) begin
                if(i>2000) $fatal(1,"DMA fill stalled");@(negedge clk);#1;
            end
            if(!fault) begin
                begin_valid=1;@(posedge clk);@(negedge clk);#1;begin_valid=0;
            end
            if(negative) begin
                for(integer i=0;!fault;i=i+1) begin
                    if(i>2000 || complete) $fatal(1,"Malformed DMA accepted case=%0d state=%0d",cases,dut.parse_state);
                    if(dut.q_count!=0) begin req_valid=1;req_voice=dut.q_voice[dut.q_head];req_stage=dut.q_stage[dut.q_head];param_ready=1;end
                    else req_valid=0;
                    @(negedge clk);#1;
                end
            end else begin
                while(!cfg_done) begin if(fault) $fatal(1,"Valid DMA cfg fault=%h",fault);@(negedge clk);#1;end
                fields=$fscanf(fd,"%d\n",hooks);
                for(integer i=0;i<hooks;i=i+1) begin
                    fields=$fscanf(fd,"%d %d %d %d",a,b,mask,terminal);if(fields!=4) $fatal(1,"Malformed hook");
                    if(mask!=0 || terminal!=-1) expected_packets=expected_packets+1;
                    for(integer bit_index=0;bit_index<22;bit_index=bit_index+1) begin fields=$fscanf(fd,"%d",lane);expected_values[bit_index*32+:32]=lane;end
                    fields=$fscanf(fd,"\n");req_voice=6'(a);req_stage=3'(b);req_valid=1;param_ready=0;#1;
                    for(integer j=0;!param_valid;j=j+1) begin
                        if(fault || j>1000) $fatal(1,"Valid hook stalled fault=%h",fault);@(negedge clk);#1;
                    end
                    repeat(5) begin
                        if(!param_valid || param_mask!==22'(mask) || param_frame!==desc_frame || param_voice!==6'(a) || param_stage!==3'(b) || param_terminal!==(terminal!=-1) || param_reason!==3'(terminal==-1 ? 0 : terminal)) $fatal(1,"DMA hook differs hook=%0d frame=%0d/%0d terminal=%b/%0d",i,param_frame,desc_frame,param_terminal,terminal);
                        for(integer bit_index=0;bit_index<22;bit_index=bit_index+1) if(mask[bit_index] && param_values[bit_index*32+:32]!==expected_values[bit_index*32+:32]) $fatal(1,"DMA selected value differs hook=%0d field=%0d",i,bit_index);
                        @(negedge clk);#1;
                    end
                    param_ready=1;@(posedge clk);@(negedge clk);#1;param_ready=0;req_valid=0;
                end
                audio_done=1;
                while(!complete) begin if(fault) $fatal(1,"DMA completion fault=%h",fault);@(negedge clk);#1;end
                if(cfg_index!=expected_cfg || config_words!=expected_cfg || packets!=expected_packets || noops!=hooks-expected_packets || bursts!=nlines) $fatal(1,"DMA counters differ");
                finish_valid=1;@(posedge clk);@(negedge clk);#1;finish_valid=0;
                if(complete || dut.occupied!=0) $fatal(1,"DMA buffer not released");
            end
            cases=cases+1;
        end
        $display("PARAMETER_DMA_PASS cases=%0d",cases);$finish;
    end
    initial begin #10000000;$fatal(1,"DMA watchdog");end
endmodule
