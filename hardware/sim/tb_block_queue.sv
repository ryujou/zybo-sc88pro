// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_block_queue #(parameter bit PARAMETER_MODE=0);
    logic clk=0;always #5 clk=~clk;
    logic rst=1,run=0,stop=0,submit=0,submit_slot=0,acknowledge=0,ack_slot=0,last_block=0;
    logic [5:0] highest_voice=63;
    logic [31:0] command_address=32'h02000000,command_bytes=128,result_address=32'h06000000,result_bytes=40960;
    logic [4:0] frame_count=16;
    logic [63:0] first_frame=400,session_first_frame;
    logic submit_error,acknowledge_error,rd_start,wr_start,rd_idle=1,wr_idle=1,rd_done=0,wr_done=0,finished;
    logic [3:0] ownership;
    logic [1:0] completion;
    logic [31:0] rd_base,rd_bytes,wr_base,wr_bytes;
    pcm_block_queue #(.PARAMETER_MODE(PARAMETER_MODE)) dut(.*);
    integer reads=0,writes=0,completions=0,checks=0,read_delay=0,write_delay=0;
    logic automatic_dma=0;
    always @(posedge clk) begin
        if(rst) begin
            rd_idle<=1;wr_idle<=1;rd_done<=0;wr_done<=0;
            reads<=0;writes<=0;completions<=0;read_delay<=0;write_delay<=0;
        end else if(automatic_dma) begin
            rd_done<=0;wr_done<=0;
            if(rd_start) begin
                if(rd_base!=(PARAMETER_MODE ? 32'h05000000+(reads%2)*4096 : 32'h02000000+reads*1024) ||
                   rd_bytes!=(PARAMETER_MODE ? 1024 : 128)) $fatal(1,"read descriptor order");
                reads<=reads+1;rd_idle<=0;read_delay<=3;
            end
            if(wr_start) begin
                if(wr_base!=(writes%2 ? 32'h06010000 : 32'h06000000) || wr_bytes!=40960) $fatal(1,"write descriptor order");
                writes<=writes+1;wr_idle<=0;write_delay<=39;
            end
            if(read_delay>0) begin
                read_delay<=read_delay-1;
                if(read_delay==1) begin rd_done<=1;rd_idle<=1;end
            end
            if(write_delay>0) begin
                write_delay<=write_delay-1;
                if(write_delay==1) begin wr_done<=1;wr_idle<=1;end
            end
            if(completion) begin
                if(completion!==(completions%2 ? 2'b10 : 2'b01)) $fatal(1,"completion ordering");
                completions<=completions+1;
            end
        end
    end
    task reset_all;
        @(negedge clk);rst=1;run=0;stop=0;submit=0;acknowledge=0;automatic_dma=0;
        repeat(3) @(negedge clk);rst=0;
    endtask
    task descriptor(input integer block_index,input logic final_value);
        @(negedge clk);
        submit_slot=1'(block_index%2);command_address=PARAMETER_MODE ? 32'h05000000+(block_index%2)*4096 : 32'h02000000+block_index*1024;
        command_bytes=PARAMETER_MODE ? 1024 : 128;result_address=block_index%2 ? 32'h06010000 : 32'h06000000;
        result_bytes=40960;frame_count=16;first_frame=400+block_index*16;last_block=final_value;
        #1;if(submit_error) $fatal(1,"valid descriptor rejected block=%d",block_index);
        submit=1;@(negedge clk);submit=0;
    endtask
    task ack(input logic slot);
        @(negedge clk);ack_slot=slot;#1;
        if(acknowledge_error) $fatal(1,"completed slot not CPU-owned");
        acknowledge=1;@(negedge clk);acknowledge=0;
    endtask
    initial begin
        reset_all();descriptor(0,0);descriptor(1,0);
        if(ownership!=4'b0101 || session_first_frame!=400) $fatal(1,"queued ownership");
        automatic_dma=1;run=1;
        wait(reads==2);repeat(3) @(negedge clk);
        if(writes!=1 || completions!=0 || ownership[1:0]!=2 || ownership[3:2]!=2) $fatal(1,"read-ahead ownership");
        ack_slot=0;#1;if(!acknowledge_error) $fatal(1,"early CPU reuse");checks=checks+1;
        for(integer b=2;b<8;b=b+1) begin
            wait(ownership[(b%2)*2+:2]==3);
            repeat(7) @(negedge clk);ack(1'(b%2));descriptor(b,b==7);
        end
        wait(finished);repeat(5) @(negedge clk);
        if(reads!=8 || writes!=8 || completions!=8) $fatal(1,"transfer counts");
        ack(0);ack(1);
        if(ownership!=0 || rd_start || wr_start) $fatal(1,"final descriptor closure");checks=checks+1;
        reset_all();
        submit_slot=0;first_frame=400;last_block=0;command_address=PARAMETER_MODE ? 32'h05000000 : 32'h02000000;result_address=32'h06000000;
        command_bytes=PARAMETER_MODE ? 1024 : 128;result_bytes=40960;frame_count=16;
        #1;if(submit_error) $fatal(1,"fresh descriptor");
        command_address=32'h02000008;#1;if(!submit_error) $fatal(1,"alignment");checks=checks+1;
        command_address=32'h03ffffc0;#1;if(!submit_error) $fatal(1,"command region end");checks=checks+1;
        command_address=PARAMETER_MODE ? 32'h05000000 : 32'h02000000;result_bytes=40952;#1;if(!submit_error) $fatal(1,"result count");checks=checks+1;
        result_bytes=40960;frame_count=17;#1;if(!submit_error) $fatal(1,"block size");checks=checks+1;
        frame_count=16;submit_slot=1;#1;if(!submit_error) $fatal(1,"slot order");checks=checks+1;
        descriptor(0,0);#1;if(!submit_error) $fatal(1,"duplicate submission");checks=checks+1;
        submit_slot=1;result_address=32'h06010000;first_frame=417;#1;if(!submit_error) $fatal(1,"frame continuity");checks=checks+1;
        reset_all();descriptor(0,1);automatic_dma=1;run=1;
        wait(reads==1 && writes==1);@(negedge clk);stop=1;
        repeat(80) @(negedge clk);
        if(completion || finished || rd_start || wr_start || ownership[1:0]!=2) $fatal(1,"stop exposed partial results");checks=checks+1;
        reset_all();#1;if(ownership!=0 || finished) $fatal(1,"reset ownership");checks=checks+1;
        submit_slot=0;command_address=PARAMETER_MODE ? 32'h05000000 : 32'h02000000;
        command_bytes=128;result_address=32'h06000000;first_frame=400;
        for(integer mode=0;mode<4;mode=mode+1) begin
            case(mode)
                0: highest_voice=0;
                1: highest_voice=7;
                2: highest_voice=31;
                3: highest_voice=63;
            endcase
            for(integer frames=1;frames<=16;frames=frames+1) begin
                frame_count=5'(frames);result_bytes=frames*(int'(highest_voice)+17)*32;
                if(PARAMETER_MODE) command_bytes=frames*64;
                #1;if(submit_error) $fatal(1,"result length voices=%0d frames=%0d",highest_voice+1,frames);
                result_bytes=result_bytes+8;
                #1;if(!submit_error) $fatal(1,"incorrect result length accepted");checks=checks+1;
            end
        end
        if(PARAMETER_MODE) begin
            for(integer frames=1;frames<=16;frames=frames+1) begin
                frame_count=5'(frames);command_bytes=frames*64;result_bytes=frames*544+32*(frames-1);
                #1;if(submit_error) $fatal(1,"variable Voice count result length");checks=checks+1;
                result_bytes=frames*544-32;#1;if(!submit_error) $fatal(1,"short result block");checks=checks+1;
                result_bytes=frames*2560+32;#1;if(!submit_error) $fatal(1,"long result block");checks=checks+1;
            end
        end
        $display("BLOCK_QUEUE_PASS checks=%0d blocks=8 read_ahead=1 cpu_reuse=1",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"watchdog");end
endmodule

module tb_parameter_block_queue;
    tb_block_queue #(.PARAMETER_MODE(1)) test();
endmodule
