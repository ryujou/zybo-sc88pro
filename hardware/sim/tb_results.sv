// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_results;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,start=0,stop=0;
    logic [63:0] first_frame=100,out_frame=0,out_data=0,write_data,sample_frame;
    logic [5:0] highest_voice=63,left_cell=0,right_cell=63;
    logic out_valid=0,out_ready,out_first=0,out_last=0,write_valid,write_ready;
    logic sample_valid,sample_ready,frame_written,error;
    logic signed [23:0] sample_left,sample_right;
    logic [31:0] frames;
    pcm_results dut(.*);
    integer cycle=0,records=0,samples=0,checks=0,stalls=0;
    integer frame_index,record_index,words;
    logic compare=1,hold_audio=0,was_stalled=0,was_sample_stalled=0;
    logic [63:0] held_data,held_frame;
    logic [47:0] held_samples;
    assign write_ready=cycle%7>1;
    assign sample_ready=!hold_audio && cycle%1009==0;
    function automatic [63:0] record(input integer f,input integer r);
        integer destination,value,sends;
        begin
            sends=(highest_voice+1)*4;
            destination=r>=sends ? r-sends : r%64;
            value=(f*397+destination*9173-8388608);
            if(r>=sends) record={1'b1,1'b1,16'd0,6'(destination),15'd0,value[23],value[23:0]};
            else record={1'b0,1'b0,8'(r),6'(r/4),2'(r%4),6'(destination),15'd0,value[24:0]};
        end
    endfunction
    function automatic [23:0] pcm(input integer f,input integer cell_index);
        pcm=24'(f*397+cell_index*9173-8388608);
    endfunction
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(rst) begin records<=0;samples<=0;stalls<=0;was_stalled<=0;was_sample_stalled<=0;end
        else if(compare) begin
            if(was_stalled && (!write_valid || write_data!==held_data)) $fatal(1,"DMA backpressure stability");
            if(was_sample_stalled && (!sample_valid || {sample_left,sample_right}!==held_samples || sample_frame!=held_frame))
                $fatal(1,"audio backpressure stability");
            was_stalled<=write_valid && !write_ready;held_data<=write_data;
            was_sample_stalled<=sample_valid && !sample_ready;held_samples<={sample_left,sample_right};held_frame<=sample_frame;
            if(write_valid && write_ready) begin
                if(write_data!==record(records/words,records%words)) $fatal(1,"DMA record ordering %d",records);
                records<=records+1;
            end
            if(out_valid && !out_ready && out_last) stalls<=stalls+1;
            if(sample_valid && sample_ready) begin
                if(sample_frame!=first_frame+samples || sample_left!==pcm(samples,left_cell) || sample_right!==pcm(samples,right_cell))
                    $fatal(1,"native frame mismatch %d",samples);
                samples<=samples+1;
            end
        end
    end
    task reset_start;
        begin
            @(negedge clk);rst=1;start=0;stop=0;out_valid=0;
            repeat(4) @(negedge clk);rst=0;start=1;
            @(negedge clk);start=0;
            words=(highest_voice+1)*4+64;
        end
    endtask
    task send(input integer f,input integer r);
        begin
            @(negedge clk);out_valid=1;out_frame=first_frame+f;out_data=record(f,r);
            out_first=r==0;out_last=r==words-1;
            @(posedge clk);while(!out_ready) @(posedge clk);
            @(negedge clk);out_valid=0;
        end
    endtask
    task stream;
        begin
            reset_start();
            for(frame_index=0;frame_index<16;frame_index=frame_index+1)
                for(record_index=0;record_index<words;record_index=record_index+1) send(frame_index,record_index);
            wait(samples==16);@(negedge clk);
            if(error || records!=16*words || frames!=16 || stalls==0) $fatal(1,"stream totals");
            checks=checks+1;
        end
    endtask
    initial begin
        stream();highest_voice=7;left_cell=63;right_cell=0;stream();
        highest_voice=0;left_cell=3;right_cell=3;stream();
        compare=0;reset_start();@(negedge clk);out_valid=1;out_first=1;out_last=1;out_frame=first_frame;out_data=0;
        wait(error);@(negedge clk);if(sample_valid || out_ready) $fatal(1,"short frame");checks=checks+1;
        reset_start();@(negedge clk);out_valid=1;out_first=1;out_last=0;out_frame=first_frame+1;
        wait(error);@(negedge clk);if(sample_valid) $fatal(1,"wrong frame publication");checks=checks+1;
        compare=1;hold_audio=1;reset_start();
        for(record_index=0;record_index<words;record_index=record_index+1) send(0,record_index);
        if(!sample_valid) $fatal(1,"missing complete sample");
        reset_start();hold_audio=0;
        for(record_index=0;record_index<words;record_index=record_index+1) send(0,record_index);
        wait(samples==1);@(negedge clk);if(error || frames!=1) $fatal(1,"reset recovery");checks=checks+1;
        $display("RESULTS_PASS checks=%0d frames=49 routes=3",checks);$finish;
    end
    initial begin #20000000;$fatal(1,"watchdog");end
endmodule
