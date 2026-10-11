// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_commands;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,start=0,stop=0,pause=0,due=0;
    logic [63:0] first_frame=64'd900,command_data=0,frame_id,done_frame=0;
    logic [5:0] highest_voice=63,cfg_voice,cfg_word;
    logic [15:0] initial_irq_status=16'h3456,frame_irq_status,done_irq_status=0;
    logic initial_irq_interrupt=1,command_valid=0,command_ready;
    logic cfg_valid,cfg_ready,cfg_rsp_valid=0,cfg_rsp_ready;
    logic [31:0] cfg_wdata,completed,max_due_cycles;
    logic frame_valid,frame_ready,frame_irq_interrupt,done_valid=0,done_ready,done_irq_interrupt=0;
    logic running,ended,busy;
    logic [3:0] error;
    pcm_commands dut(.*);
    logic [63:0] words[0:32767];
    string input_path;
    integer count,wanted_frames,cycle=0,config_delay=0,frame_delay=0;
    integer configs=0,launches=0,responses=0,irq_clears=0,ticks=0,checks=0;
    integer delay_due=0,last_completed=0,word_index;
    logic automatic_due=0,automatic_core=1;
    logic [15:0] expected_irq;
    logic expected_interrupt;
    assign cfg_ready=config_delay==0 && cycle%5!=0;
    assign frame_ready=frame_delay==0 && !done_valid && cycle%7!=0;
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(rst) begin
            config_delay<=0;frame_delay<=0;cfg_rsp_valid<=0;done_valid<=0;
            configs<=0;launches<=0;responses<=0;irq_clears<=0;ticks<=0;
            expected_irq<=initial_irq_status;expected_interrupt<=initial_irq_interrupt;
        end else if(automatic_core) begin
            cfg_rsp_valid<=0;
            if(config_delay>0) begin
                config_delay<=config_delay-1;
                if(config_delay==1) begin cfg_rsp_valid<=1;responses<=responses+1;end
            end
            if(cfg_valid && cfg_ready) begin
                if(!command_valid || !command_ready || cfg_word>=51 || cfg_voice>highest_voice)
                    $fatal(1,"configuration handshake");
                config_delay<=2+cycle%3;configs<=configs+1;
            end
            if(frame_valid && frame_ready) begin
                if(responses!=configs || busy || frame_id!=first_frame+launches)
                    $fatal(1,"frame before configuration response or wrong frame");
                if(frame_irq_status!=expected_irq || frame_irq_interrupt!=expected_interrupt)
                    $fatal(1,"IRQ ordering");
                if(launches>=2+ticks) $fatal(1,"uncredited frame");
                if(pause) $fatal(1,"frame admitted while paused");
                launches<=launches+1;frame_delay<=12;done_frame<=frame_id;
                done_irq_status<=frame_irq_status+1'b1;done_irq_interrupt<=1;
            end
            if(frame_delay>0) begin
                frame_delay<=frame_delay-1;
                if(frame_delay==1) done_valid<=1;
            end
            if(done_valid && done_ready) begin
                done_valid<=0;expected_irq<=done_irq_status;expected_interrupt<=done_irq_interrupt;
            end
            if(command_valid && command_ready && command_data[63:60]==2) begin
                expected_interrupt<=0;irq_clears<=irq_clears+1;
            end
            if(due) ticks<=ticks+1;
        end
    end
    always @(negedge clk) begin
        if(automatic_due) begin
            due=0;
            if(completed>=2 && completed<wanted_frames && completed!=last_completed) begin
                if(delay_due==0) pause=1;
                delay_due=delay_due+1;
                if(delay_due==9) begin
                    pause=0;due=1;last_completed=completed;delay_due=0;
                end
            end
        end
    end
    task reset_start;
        begin
            @(negedge clk);rst=1;start=0;stop=0;due=0;pause=0;command_valid=0;
            automatic_due=0;repeat(4) @(negedge clk);
            rst=0;start=1;@(negedge clk);start=0;
        end
    endtask
    task send(input logic [63:0] data);
        begin
            @(negedge clk);command_data=data;command_valid=1;
            @(posedge clk);while(!command_ready) begin
                if(error!=0) $fatal(1,"unexpected command error %d",error);
                @(posedge clk);
            end
            @(negedge clk);command_valid=0;
        end
    endtask
    task bad(input logic [63:0] data);
        begin
            reset_start();@(negedge clk);command_valid=1;command_data=data;
            repeat(3) @(negedge clk);
            if(error!=1 || command_ready || cfg_valid || frame_valid) $fatal(1,"bad command not rejected");
            checks=checks+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("input=%s",input_path) || !$value$plusargs("count=%d",count) ||
           !$value$plusargs("frames=%d",wanted_frames)) $fatal(1,"input arguments");
        $readmemh(input_path,words,0,count-1);
        reset_start();automatic_due=1;
        for(word_index=0;word_index<count;word_index=word_index+1) send(words[word_index]);
        repeat(10) @(negedge clk);
        if(error || !ended || running || completed!=wanted_frames || launches!=wanted_frames || responses!=configs)
            $fatal(1,"stream completion frames=%d error=%d",completed,error);
        $display("COMMAND_STREAM frames=%0d configs=%0d irq_clears=%0d ticks=%0d max_due=%0d",completed,configs,irq_clears,ticks,max_due_cycles);
        checks=checks+1;
        bad(64'h0000330000000000); // Word 51.
        highest_voice=7;bad(64'h0000000800000000);highest_voice=63;
        bad(64'h0000400000000000);
        bad(64'h100000000000003e);
        bad(64'h2000000000000001);
        bad(64'h3000000000000001);
        bad(64'h4000000000000000);
        reset_start();@(negedge clk);due=1;@(negedge clk);due=0;
        repeat(3125) @(negedge clk);
        if(error) $fatal(1,"deadline fired before 3126");
        @(negedge clk);if(error!=3) $fatal(1,"starved commands deadline");checks=checks+1;
        reset_start();send(64'h0000020400000012);
        reset_start();send(64'h100000000000003f);
        wait(completed==1);send(64'h3000000000000000);
        if(!ended || error) $fatal(1,"reset with configuration pending");checks=checks+1;
        reset_start();send(64'h100000000000003f);
        force done_frame=64'd901;wait(error==2);release done_frame;checks=checks+1;
        reset_start();@(negedge clk);stop=1;@(negedge clk);stop=0;
        if(running || frame_valid || cfg_valid || command_ready) $fatal(1,"stop admission");checks=checks+1;
        $display("COMMANDS_PASS checks=%0d",checks);$finish;
    end
    initial begin #20000000;$fatal(1,"watchdog");end
endmodule
