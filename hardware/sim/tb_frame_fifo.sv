// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_frame_fifo;
    logic clk=0,rst=1,begin_valid=0,begin_ready,record_valid=0,record_ready,commit_valid=0,commit_ready,abort_frame=0;
    logic [63:0] begin_frame=0,record_data=0,out_frame,out_data;
    logic out_valid,out_ready=0,out_first,out_last,empty;
    logic [1:0] level,high_water;
    integer checked=0;
    pcm_frame_fifo dut(.*);
    always #5 clk=~clk;
    task automatic reset_fifo;
        @(negedge clk);rst=1;begin_valid=0;record_valid=0;commit_valid=0;abort_frame=0;out_ready=0;
        @(negedge clk);rst=0;@(negedge clk);
        if(out_valid || level!=0 || high_water!=0 || !empty) $fatal(1,"FIFO reset");
    endtask
    task automatic begin_one(input integer id);
        begin_frame=64'(id);begin_valid=1;
        do begin @(posedge clk);end while(!begin_ready);
        @(negedge clk);begin_valid=0;
    endtask
    task automatic write_one(input integer id,input integer index);
        if(!record_ready) $fatal(1,"Record not ready");
        record_data={32'(id),32'(index)};record_valid=1;
        @(negedge clk);record_valid=0;#1;
    endtask
    task automatic write_frame(input integer id,input integer count);
        begin_one(id);
        for(integer i=0;i<count;i=i+1) write_one(id,i);
        if(!commit_ready) $fatal(1,"Commit not ready");
        commit_valid=1;@(negedge clk);commit_valid=0;
    endtask
    task automatic check_record(input integer id,input integer index,input integer count);
        if(!out_valid || out_frame!==64'(id) || out_data!=={32'(id),32'(index)} || out_first!==(index==0) || out_last!==(index==count-1))
            $fatal(1,"FIFO_RECORD_DIFFERENCE frame=%0d index=%0d out=%h",id,index,out_data);
    endtask
    task automatic read_frame(input integer id,input integer count);
        for(integer i=0;i<count;i=i+1) begin
            while(!out_valid) @(negedge clk);
            check_record(id,i,count);
            repeat(i%4) begin @(negedge clk);check_record(id,i,count);end
            out_ready=1;@(negedge clk);out_ready=0;checked=checked+1;
        end
    endtask
    initial begin
        reset_fifo();write_frame(0,320);write_frame(1,68);
        if(level!=2 || begin_ready || high_water!=2) $fatal(1,"FIFO capacity");
        repeat(8) begin @(negedge clk);check_record(0,0,320);end
        fork
            begin write_frame(2,192);end
            begin read_frame(0,320);read_frame(1,68);read_frame(2,192);end
        join
        if(level!=0 || !empty) $fatal(1,"FIFO not empty");
        begin_one(3);for(integer i=0;i<100;i=i+1) write_one(3,i);
        if(out_valid || !empty) $fatal(1,"Partial frame exposed");
        abort_frame=1;@(negedge clk);abort_frame=0;
        if(level!=0 || !begin_ready) $fatal(1,"Abort retained reservation");
        write_frame(4,68);read_frame(4,68);
        for(integer position=0;position<4;position=position+1) begin
            reset_fifo();begin_one(5);
            if(position>0) write_one(5,0);
            if(position>1) begin commit_valid=1;@(negedge clk);commit_valid=0;while(!out_valid) @(negedge clk);end
            if(position>2) begin out_ready=1;@(negedge clk);out_ready=0;end
            reset_fifo();write_frame(6+position,68);read_frame(6+position,68);
        end
        $display("FRAME_FIFO_PASS records=%0d reset_positions=4",checked);$finish;
    end
    initial begin #1000000;$fatal(1,"FIFO watchdog");end
endmodule
