// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_mixer;
    logic clk=0,rst=1,ready,frame_valid=0,frame_ready,voice_valid=0,voice_ready;
    logic [63:0] frame_id=0,voice_sends=0,send_frame;
    logic [5:0] frame_highest_voice=0,voice_index=0,send_voice,send_destination,mix_destination;
    logic signed [23:0] voice_prior=0,mix_sample;
    logic send_valid,send_ready=0,mix_valid,mix_ready=0,mix_seen,mix_last,done_valid,done_ready=0;
    logic [1:0] send_index;
    logic [7:0] send_slot;
    logic signed [24:0] send_contribution;
    integer fd,ncases,nvoices,nframes,fields,f,prior,c0,c1,c2,c3,slot,dest,contribution,value,seen;
    integer frames=0,sends=0,cells=0;
    integer active_voice,active_send,active_cell;
    logic damage;
    pcm_mixer dut(.*);
    always #5 clk=~clk;

    task automatic reset_core;
        @(negedge clk); rst=1; frame_valid=0;voice_valid=0;send_ready=0;mix_ready=0;done_ready=0;
        @(negedge clk);
        if(ready || frame_ready || voice_ready || send_valid || mix_valid || done_valid) $fatal(1,"Reset valid");
        rst=0;
        for(integer wait_cycle=0;!ready;wait_cycle=wait_cycle+1) begin
            if(wait_cycle>128) $fatal(1,"Reset scrub deadline");
            @(negedge clk);
        end
    endtask

    task automatic start_frame(input integer id,input integer count);
        if(!frame_ready) $fatal(1,"Frame not ready");
        frame_id=64'(id);frame_highest_voice=6'(count-1);frame_valid=1;
        @(negedge clk);frame_valid=0;
    endtask

    task automatic start_voice(input integer index,input integer sample,input logic [63:0] config_bits);
        if(!voice_ready) $fatal(1,"Voice not ready");
        voice_index=6'(index);voice_prior=24'(sample);voice_sends=config_bits;voice_valid=1;
        @(negedge clk);voice_valid=0;
    endtask

    task automatic check_send;
        if(!send_valid || send_frame!==frame_id || send_voice!==6'(active_voice) || send_index!==2'(active_send) ||
           send_slot!==8'(slot) || send_destination!==6'(dest) || send_contribution!==25'(contribution))
            $fatal(1,"MIXER_SEND_DIFFERENCE frame=%0d voice=%0d send=%0d value=%0d expected=%0d",f,active_voice,active_send,send_contribution,contribution);
    endtask

    task automatic check_cell;
        if(!mix_valid || mix_destination!==6'(active_cell) || mix_sample!==24'(value) || mix_seen!==1'(seen) || mix_last!==(active_cell==63))
            $fatal(1,"MIXER_CELL_DIFFERENCE frame=%0d cell=%0d value=%0d expected=%0d seen=%b/%0d",f,active_cell,mix_sample,value,mix_seen,seen);
    endtask

    task automatic silent_frame(input integer id);
        start_frame(id,1);start_voice(0,0,64'd0);send_ready=1;
        while(!mix_valid) @(negedge clk);
        for(active_cell=0;active_cell<64;active_cell=active_cell+1) begin
            value=0;seen=active_cell==0;check_cell();mix_ready=1;@(negedge clk);
        end
        mix_ready=0;send_ready=0;
        if(!done_valid) $fatal(1,"Silent frame incomplete");
        done_ready=1;@(negedge clk);done_ready=0;
    endtask

    initial begin
        damage=$test$plusargs("damage_send");
        fd=$fopen("vectors.txt","r");if(!fd) $fatal(1,"Missing vectors");
        fields=$fscanf(fd,"%d\n",ncases);if(fields!=1 || ncases!=48) $fatal(1,"Missing cases");
        for(integer testcase=0;testcase<ncases;testcase=testcase+1) begin
            fields=$fscanf(fd,"%d %d\n",nvoices,nframes);if(fields!=2) $fatal(1,"Malformed case");
            reset_core();
            for(integer frame=0;frame<nframes;frame=frame+1) begin
                fields=$fscanf(fd,"%d\n",f);if(fields!=1) $fatal(1,"Malformed frame");
                start_frame(f,nvoices);
                for(active_voice=0;active_voice<nvoices;active_voice=active_voice+1) begin
                    fields=$fscanf(fd,"%d %d %d %d %d\n",prior,c0,c1,c2,c3);if(fields!=5) $fatal(1,"Malformed voice");
                    start_voice(active_voice,prior,{16'(c3),16'(c2),16'(c1),16'(c0)});
                    for(active_send=0;active_send<4;active_send=active_send+1) begin
                        fields=$fscanf(fd,"%d %d %d\n",slot,dest,contribution);if(fields!=3) $fatal(1,"Malformed send");
                        if(damage && contribution!=0) contribution=contribution+1;
                        while(!send_valid) @(negedge clk);
                        check_send();
                        repeat((frames+active_send)%4) begin @(negedge clk);check_send();end
                        send_ready=1;@(negedge clk);send_ready=0;sends=sends+1;
                    end
                end
                for(active_cell=0;active_cell<64;active_cell=active_cell+1) begin
                    fields=$fscanf(fd,"%d %d\n",value,seen);if(fields!=2) $fatal(1,"Malformed mix");
                    check_cell();
                    repeat(active_cell%3) begin @(negedge clk);check_cell();end
                    mix_ready=1;@(negedge clk);mix_ready=0;cells=cells+1;
                end
                repeat(f%5) begin
                    if(!done_valid || frame_ready) $fatal(1,"Done backpressure");
                    @(negedge clk);
                end
                if(!done_valid) $fatal(1,"Missing done");
                done_ready=1;@(negedge clk);done_ready=0;frames=frames+1;
            end
        end
        $fclose(fd);
        for(integer offset=0;offset<128;offset=offset+1) begin
            reset_core();start_frame(0,1);start_voice(0,8388607,64'hffff_ffff_ffff_ffff);
            send_ready=1;mix_ready=1;
            repeat(offset) @(negedge clk);
            reset_core();silent_frame(0);silent_frame(1);
        end
        $display("MIXER_PASS frames=%0d sends=%0d cells=%0d reset_positions=128",frames,sends,cells);
        $finish;
    end
    initial begin #(64'd1000000000); $fatal(1,"Mixer watchdog");end
endmodule
