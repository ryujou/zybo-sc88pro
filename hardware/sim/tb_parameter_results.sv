// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_parameter_results;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,start=0,stop=0,metadata_valid=0,metadata_ready,metadata_last=0;
    logic [63:0] first_frame=456,metadata_frame=0,out_frame=0,out_data=0,write_data;
    logic [5:0] metadata_highest_voice=0;
    logic out_valid=0,out_ready,out_first=0,out_last=0,write_valid,write_ready;
    logic frame_written,ended,error;
    logic [31:0] frames;
    logic [2:0] level;
    pcm_parameter_results dut(.*);
    integer cycle=0,accepted=0,expected_frame=0,expected_index=0,checks=0,negative_checks=0;
    logic enable_write=1,checking=1;
    assign write_ready=enable_write && cycle%9<5;
    function automatic integer highest(input integer n);highest=(n*17)%64;endfunction
    function automatic [63:0] value(input integer n,input integer i);value=(64'(n)<<32) | i;endfunction
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(rst) begin accepted<=0;expected_frame<=0;expected_index<=0;end
        else if(checking) begin
            if(write_valid && write_ready) begin
                if(!out_valid || !out_ready || write_data!=value(expected_frame,expected_index))
                    $fatal(1,"result ordering or corrupt forwarding");
                accepted<=accepted+1;
                if(expected_index==(highest(expected_frame)+1)*4+63) begin
                    expected_frame<=expected_frame+1;expected_index<=0;
                end else expected_index<=expected_index+1;
            end
        end
    end
    task reset_start;
        begin
            @(negedge clk);rst=1;start=0;stop=0;metadata_valid=0;out_valid=0;
            enable_write=1;checking=1;
            repeat(4) @(negedge clk);rst=0;start=1;@(negedge clk);start=0;
        end
    endtask
    task metadata(input integer n,input logic last);
        begin
            @(negedge clk);metadata_valid=1;metadata_frame=first_frame+n;
            metadata_highest_voice=highest(n);metadata_last=last;
            @(posedge clk);while(!metadata_ready) @(posedge clk);
            @(negedge clk);metadata_valid=0;
        end
    endtask
    task record(input integer n,input integer i);
        begin
            @(negedge clk);out_valid=1;out_frame=first_frame+n;out_data=value(n,i);
            out_first=i==0;out_last=i==(highest(n)+1)*4+63;
            @(posedge clk);while(!out_ready) begin
                if(error) $fatal(1,"unexpected result error");@(posedge clk);
            end
            @(negedge clk);out_valid=0;
        end
    endtask
    task bad_boundary(input integer kind);
        begin
            reset_start();metadata(0,1);
            @(negedge clk);out_valid=1;out_frame=first_frame;out_first=1;out_last=0;out_data=0;
            case(kind)
                0:out_frame=first_frame+1;
                1:out_first=0;
                2:out_last=1;
            endcase
            repeat(3) @(negedge clk);
            if(!error || accepted || write_valid || out_ready) $fatal(1,"invalid result escaped");
            negative_checks=negative_checks+1;
        end
    endtask
    initial begin
        reset_start();enable_write=0;
        for(integer n=0;n<4;n=n+1) metadata(n,0);
        repeat(10) @(negedge clk);
        if(metadata_ready || level!=4 || frames || accepted) $fatal(1,"metadata capacity");
        enable_write=1;
        fork
            begin for(integer n=4;n<40;n=n+1) metadata(n,n==39);end
            begin
                for(integer n=0;n<40;n=n+1)
                    for(integer i=0;i<(highest(n)+1)*4+64;i=i+1) record(n,i);
            end
        join
        repeat(4) @(negedge clk);
        if(!ended || error || frames!=40 || expected_frame!=40 || expected_index || level || metadata_ready)
            $fatal(1,"result stream completion");
        $display("PARAMETER_RESULT_STREAM frames=%0d words=%0d",frames,accepted);checks=checks+1;
        bad_boundary(0);bad_boundary(1);bad_boundary(2);
        reset_start();metadata(0,1);record(0,0);
        @(negedge clk);out_valid=1;out_frame=first_frame;out_data=1;out_first=1;out_last=0;
        repeat(3) @(negedge clk);
        if(!error || accepted!=1 || write_valid) $fatal(1,"repeated first escaped");negative_checks=negative_checks+1;
        reset_start();metadata(0,1);
        for(integer i=0;i<67;i=i+1) record(0,i);
        @(negedge clk);out_valid=1;out_frame=first_frame;out_data=67;out_first=0;out_last=0;
        repeat(3) @(negedge clk);
        if(!error || accepted!=67 || write_valid) $fatal(1,"missing last escaped");negative_checks=negative_checks+1;
        reset_start();metadata(1,0);repeat(3) @(negedge clk);
        if(!error || metadata_ready) $fatal(1,"wrong metadata frame");negative_checks=negative_checks+1;
        reset_start();metadata(0,1);record(0,0);
        @(negedge clk);stop=1;@(negedge clk);stop=0;start=1;@(negedge clk);start=0;
        if(metadata_ready || out_ready || write_valid || ended) $fatal(1,"stop/restart");checks=checks+1;
        reset_start();metadata(0,1);
        for(integer i=0;i<68;i=i+1) record(0,i);
        if(!ended || error || frames!=1) $fatal(1,"reset recovery");checks=checks+1;
        $display("PARAMETER_RESULTS_PASS checks=%0d negatives=%0d",checks,negative_checks);$finish;
    end
    initial begin #20000000;$fatal(1,"watchdog");end
endmodule
