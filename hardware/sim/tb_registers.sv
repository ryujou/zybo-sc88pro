// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_registers;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,reg_valid=0,reg_write=0;
    logic [11:0] reg_address=0;
    logic [31:0] reg_wdata=0,reg_rdata;
    logic [3:0] reg_wstrb=15;
    logic reg_ready,reg_error,ready=1,reset_busy=0,ended=0,finished=0,pause_ack=0;
    logic [21:0] fault=0;
    logic [31:0] completed=5,written=4,max_due_cycles=3075,max_frame_cycles=3073,cache_hits=50,cache_misses=2,axi_bursts=3,timeouts=0,overruns=0;
    logic [5:0] audio_level=2;
    logic [3:0] ownership=0;
    logic [1:0] completion=0;
    logic dma_idle=1,wave_idle=1,start,pause,reset_request,stop_request,active,irq;
    logic [63:0] descriptors,first_frame;
    logic [7:0] physical16;
    logic [31:0] bank_shifts,command_address,command_bytes,result_address,result_bytes;
    logic [15:0] initial_irq_status,irq_mask;
    logic initial_irq_interrupt;
    logic [5:0] highest_voice,left_cell,right_cell;
    logic submit,submit_slot,acknowledge,ack_slot,last_block,submit_error=0,acknowledge_error=0;
    logic [4:0] frame_count;
    pcm_registers dut(.*);
    integer checks=0,starts=0,submissions=0,acks=0,resets=0,stops=0;
    always @(posedge clk) if(!rst) begin
        if(start) starts=starts+1;
        if(submit) begin
            if(submit_slot!=1 || command_address!=32'h02001000 || command_bytes!=128 || result_address!=32'h06010000 ||
               result_bytes!=40960 || frame_count!=16 || first_frame!=352000 || !last_block) $fatal(1,"descriptor publication");
            submissions=submissions+1;
        end
        if(acknowledge) acks=acks+1;
        if(reset_request) resets=resets+1;
        if(stop_request) stops=stops+1;
    end
    task access(input logic write_enable,input logic [11:0] address,input logic [31:0] value,input logic expected_error,input logic [31:0] expected_read);
        @(negedge clk);reg_valid=1;reg_write=write_enable;reg_address=address;reg_wdata=value;
        do begin @(negedge clk);end while(!reg_ready);
        #1;if(reg_error!==expected_error || (!write_enable && !expected_error && reg_rdata!==expected_read))
            $fatal(1,"register access address=%h error=%b data=%h expected=%h",address,reg_error,reg_rdata,expected_read);
        @(negedge clk);reg_valid=0;checks=checks+1;
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        access(0,0,0,0,32'h53433430);access(0,12'h05c,0,0,32'h003f0100);
        access(1,12'h004,1,1,0);
        access(1,12'h040,32'h05040302,0,0);access(1,12'h044,32'h01010101,0,0);
        access(0,12'h040,0,0,32'h05040302);access(0,12'h044,0,0,32'h01010101);
        access(1,12'h05c,32'h003f0908,0,0);
        if(highest_voice!=63 || left_cell!=8 || right_cell!=9) $fatal(1,"route fields");
        access(1,12'h05c,32'h003e0908,1,0);
        reg_wstrb=3;access(1,12'h040,0,1,0);reg_wstrb=15;
        access(0,12'h041,0,1,0);access(0,12'h0fc,0,1,0);access(1,12'h018,0,1,0);
        access(0,12'h01c,0,0,3075);
        access(1,12'h120,32'h02001000,0,0);access(1,12'h124,128,0,0);
        access(1,12'h128,32'h06010000,0,0);access(1,12'h12c,40960,0,0);
        access(1,12'h130,16,0,0);access(1,12'h134,352000,0,0);access(1,12'h138,0,0,0);
        submit_error=1;access(1,12'h13c,257,1,0);submit_error=0;
        access(1,12'h13c,257,0,0);
        if(submissions!=1) $fatal(1,"submit strobe");
        ownership=4'b0101;
        access(1,12'h120,0,1,0);access(1,12'h040,0,1,0);
        access(1,12'h014,7,0,0);access(1,12'h004,1,0,0);
        access(1,12'h004,1,1,0);access(1,12'h004,2,0,0);
        if(starts!=1 || !active || !pause) $fatal(1,"start/pause semantics");
        access(1,12'h004,0,0,0);if(pause) $fatal(1,"resume");
        @(negedge clk);completion=1;@(negedge clk);completion=0;
        access(0,12'h010,0,0,1);if(!irq) $fatal(1,"block IRQ");
        access(1,12'h010,1,0,0);if(irq) $fatal(1,"IRQ W1C");
        @(negedge clk);completion=2;
        access(1,12'h010,2,0,0);completion=0;
        access(0,12'h010,0,0,2);
        fault=22'h100;repeat(2) @(negedge clk);
        access(1,12'h010,7,0,0);access(0,12'h010,0,0,4);
        fault=0;access(1,12'h010,7,0,0);
        ownership=4'b1101;access(1,12'h13c,2,0,0);if(acks!=1) $fatal(1,"ack strobe");
        acknowledge_error=1;access(1,12'h13c,2,1,0);
        access(1,12'h004,8,0,0);access(1,12'h004,4,0,0);
        repeat(2) @(negedge clk);if(stops!=1 || resets!=1) $fatal(1,"stop/reset strobes");
        reset_busy=1;access(1,12'h014,0,1,0);reset_busy=0;
        rst=1;repeat(2) @(negedge clk);rst=0;
        access(0,12'h010,0,0,0);if(active || pause || irq) $fatal(1,"reset registers");
        $display("REGISTERS_PASS checks=%0d descriptor=1 irq_w1c=1 control=1",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"watchdog");end
endmodule
