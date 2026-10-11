// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_i2s;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,enable=0,pause=0,sample_valid=0;
    wire sample_ready,bclk,lrclk,serial_data,mute_n,frame_tick,underrun;
    logic signed [23:0] sample_left=0,sample_right=0;
    wire signed [23:0] native_left,native_right;
    pcm_i2s dut(.*);
    integer cycles=0,last_tick=-1,slot_bit=0,frames=0,accepted=0,resets=0;
    integer rises=0,last_rise=-1;
    logic [15:0] left_word=0,right_word=0,expected_left=0,expected_right=0;
    logic corrupt=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(rst) begin last_tick=-1;last_rise=-1;slot_bit=0;rises=0;end
        else begin
            if(sample_ready && sample_valid) begin
                accepted=accepted+1;
                expected_left=sample_left[23:8];expected_right=sample_right[23:8];
                if(corrupt) expected_left=expected_left^1;
            end
            #1;
            if(frame_tick) begin
                if(last_tick>=0 && cycles-last_tick!=384) $fatal(1,"I2S_FRAME_PERIOD");
                last_tick=cycles;slot_bit=0;left_word=0;right_word=0;
                if(!mute_n) begin expected_left=0;expected_right=0;end
            end
            if(underrun && mute_n) $fatal(1,"UNDERRUN_NOT_MUTED");
        end
    end
    always @(posedge bclk) if(!rst) begin
        if(last_rise>=0 && cycles-last_rise!=6) $fatal(1,"I2S_BCLK_PERIOD");
        last_rise=cycles;rises=rises+1;
        if(lrclk!=(slot_bit>=32)) $fatal(1,"I2S_CHANNEL_BOUNDARY");
        if(slot_bit>=1 && slot_bit<=16) left_word={left_word[14:0],serial_data};
        else if(slot_bit>=33 && slot_bit<=48) right_word={right_word[14:0],serial_data};
        else if(serial_data!==0) $fatal(1,"I2S_DELAY_OR_PADDING");
        if(slot_bit==63) begin
            if(left_word!==expected_left || right_word!==expected_right)
                $fatal(1,"I2S_SAMPLE_DIFFERENCE left=%h/%h right=%h/%h",left_word,expected_left,right_word,expected_right);
            frames=frames+1;
        end
        slot_bit=slot_bit+1;
    end
    task automatic wait_frame;
        @(negedge clk);while(!frame_tick) @(negedge clk);
        repeat(383) @(negedge clk);
    endtask
    task automatic restart;
        @(negedge clk);rst=1;enable=0;pause=0;sample_valid=0;
        repeat(3) @(negedge clk);rst=0;
    endtask
    initial begin
        corrupt=$test$plusargs("damage_sample");
        restart();
        sample_left=24'h7fffff;sample_right=24'h800000;sample_valid=1;enable=1;
        repeat(3) wait_frame();
        sample_left=24'h123456;sample_right=-24'sh123456;
        repeat(3) wait_frame();
        pause=1;sample_valid=0;
        repeat(3) wait_frame();
        if(underrun || mute_n) $fatal(1,"PAUSE_STATE");
        pause=0;sample_valid=1;sample_left=24'd32;sample_right=-24'sd1;
        repeat(3) wait_frame();
        sample_valid=0;wait_frame();
        if(!underrun || mute_n) $fatal(1,"UNDERRUN_STATE");
        sample_valid=1;repeat(2) wait_frame();
        if(!underrun || mute_n) $fatal(1,"FAULT_NOT_STICKY");
        for(integer position=0;position<384;position=position+1) begin
            restart();enable=1;sample_valid=1;sample_left=24'h654321;sample_right=24'hfedcba;
            repeat(position+1) @(negedge clk);
            restart();
            if(underrun || mute_n || native_left!=0 || native_right!=0) $fatal(1,"RESET_STATE");
            enable=1;sample_valid=1;sample_left=24'hfedcba;sample_right=24'h654321;
            repeat(2) wait_frame();resets=resets+1;
        end
        $display("I2S_PASS frames=%0d accepted=%0d reset_positions=%0d period=384 bclk_divider=6",frames,accepted,resets);
        $finish;
    end
    initial begin #10000000;$fatal(1,"I2S_TIMEOUT");end
endmodule
