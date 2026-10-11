// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_audio_bridge #(parameter integer START_LEVEL=2);
    logic sys_clk=0,audio_clk=0;
    always #5 sys_clk=~sys_clk;
    always #40.69 audio_clk=~audio_clk;
    logic sys_reset=1,audio_reset=1,clear=0,run=0,pause=0,finish=0,sample_valid=0;
    logic signed [23:0] sample_left=0,sample_right=0;
    wire sample_ready,due,underrun,pause_ack,reset_busy,drained,bclk,lrclk,serial_data,mute_n,audio_accepted;
    wire [5:0] level;
    wire signed [23:0] native_left,native_right;
    pcm_audio_bridge #(.START_LEVEL(START_LEVEL)) dut(.*);
    integer offered=0,consumed=0,due_count=0,checks=0;
    logic checking=1;
    function automatic [23:0] left_value(input integer index);left_value=24'(index*32'h923457);endfunction
    function automatic [23:0] right_value(input integer index);right_value=~left_value(index);endfunction
    always @(posedge sys_clk) if(!sys_reset && !clear && due) due_count=due_count+1;
    always @(posedge audio_clk) begin
        #1;
        if(checking && audio_accepted && !audio_reset) begin
            if(native_left!==left_value(consumed) || native_right!==right_value(consumed)) $fatal(1,"CDC_SAMPLE_ORDER frame=%0d",consumed);
            consumed=consumed+1;
        end
    end
    task automatic send_sample;
        @(negedge sys_clk);sample_left=left_value(offered);sample_right=right_value(offered);sample_valid=1;
        @(posedge sys_clk);while(!sample_ready) @(posedge sys_clk);
        @(negedge sys_clk);sample_valid=0;offered=offered+1;
    endtask
    task automatic wait_count(input integer target);
        integer watchdog;
        watchdog=0;
        while(consumed<target) begin
            @(negedge sys_clk);watchdog=watchdog+1;
            if(watchdog>500000) $fatal(1,"CDC_CONSUMER_TIMEOUT");
        end
    endtask
    initial begin
        repeat(64) @(negedge sys_clk);sys_reset=0;audio_reset=0;
        while(reset_busy) @(negedge sys_clk);
        if(START_LEVEL==32) begin
            repeat(31) send_sample();run=1;
            repeat(10000) @(negedge sys_clk);
            if(consumed || due_count || mute_n || underrun) $fatal(1,"CDC_START_WATERMARK");
            send_sample();finish=1;wait_count(32);
            if(drained) $fatal(1,"CDC_EARLY_DRAIN");
            while(!drained) @(negedge sys_clk);
            if(mute_n || underrun || consumed!=32 || due_count!=32) $fatal(1,"CDC_DRAIN");
            checks=checks+1;checking=0;clear=1;run=0;finish=0;
            repeat(96) @(negedge sys_clk);clear=0;
            while(reset_busy) @(negedge sys_clk);
            repeat(100) @(negedge sys_clk);
            offered=0;consumed=0;due_count=0;checking=1;
        end
        // The asynchronous XPM FWFT interface accepts 33 words at configured depth 32.
        repeat(33) send_sample();
        repeat(20) @(negedge sys_clk);
        if(sample_ready || level!=33) $fatal(1,"CDC_FIFO_FULL ready=%b level=%0d",sample_ready,level);
        run=1;wait_count(5);
        pause=1;while(!pause_ack) @(negedge sys_clk);
        begin
            integer saved;saved=consumed;
            repeat(10000) @(negedge sys_clk);
            if(consumed!=saved || underrun || mute_n) $fatal(1,"CDC_PAUSE");
        end
        pause=0;wait_count(33);
        while(!underrun) @(negedge sys_clk);
        if(mute_n) $fatal(1,"CDC_UNDERRUN_MUTE");
        repeat(8) @(negedge sys_clk);
        if(due_count!=consumed) $fatal(1,"CDC_DUE_COUNT");
        checks=checks+1;
        for(integer position=0;position<8;position=position+1) begin
            checking=0;clear=1;run=0;sample_valid=0;
            repeat(96+position*7) @(negedge sys_clk);
            clear=0;while(reset_busy) @(negedge sys_clk);
            repeat(100) @(negedge sys_clk);
            if(underrun || mute_n || level!=0) $fatal(1,"CDC_CLEAR");
            offered=0;consumed=0;due_count=0;checking=1;
            repeat(START_LEVEL>4 ? START_LEVEL : 4) send_sample();run=1;
            wait_count(2);repeat(16) @(negedge sys_clk);
            if(due_count!=consumed || underrun) $fatal(1,"CDC_FRESH_FRAME");
            checks=checks+1;
        end
        checking=0;clear=1;run=0;
        repeat(96) @(negedge sys_clk);clear=0;
        while(reset_busy) @(negedge sys_clk);
        repeat(100) @(negedge sys_clk);
        offered=0;consumed=0;due_count=0;checking=1;
        send_sample();finish=1;run=1;
        wait_count(1);repeat(10000) @(negedge sys_clk);
        if(underrun || mute_n || consumed!=1 || due_count!=1 || !drained) $fatal(1,"CDC_FINITE_SINGLE_FRAME");
        checks=checks+1;
        $display("AUDIO_BRIDGE_PASS checks=%0d full_depth=33 pause_resume=1 reset_positions=8 due_order=1 finish=1",checks);
        $finish;
    end
    initial begin #20000000;$fatal(1,"AUDIO_BRIDGE_TIMEOUT offered=%0d consumed=%0d due=%0d level=%0d ready=%b run=%b pause=%b ack=%b error=%b clear=%b busy=%b",offered,consumed,due_count,level,sample_ready,run,pause,pause_ack,underrun,clear,reset_busy);end
endmodule

module tb_parameter_audio_bridge;
    tb_audio_bridge #(.START_LEVEL(32)) test();
endmodule
