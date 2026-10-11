// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_parameter_registers;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,reg_valid=0,reg_write=0;
    logic [11:0] reg_address=0;
    logic [31:0] reg_wdata=0;
    logic [3:0] reg_wstrb=15;
    wire reg_ready,reg_error;
    wire [31:0] reg_rdata;
    logic ready=1,reset_busy=0,ended=0,finished=0,pause_ack=0;
    logic [25:0] fault=0;
    logic [31:0] completed=37,written=36,max_due_cycles=3099,max_frame_cycles=3088,cache_hits=100,cache_misses=5,axi_bursts=15,timeouts=0,overruns=0;
    logic [5:0] audio_level=0;
    logic [3:0] ownership=0,audio_ownership=0;
    logic [1:0] completion=0,audio_completion=0;
    logic dma_idle=1,wave_idle=1,audio_idle=1,audio_finished=0;
    logic [31:0] audio_frames=35,parameter_bursts=17,parameter_configs=8,parameter_packets=11,parameter_noops=150;
    wire start,audio_start,pause,reset_request,stop_request,active,audio_active,irq;
    wire submit,submit_slot,acknowledge,ack_slot,last_block;
    wire [31:0] command_address,command_bytes,result_address,result_bytes;
    wire [4:0] frame_count;
    wire [63:0] first_frame;
    logic submit_error=0,acknowledge_error=0,audio_submit_error=0,audio_acknowledge_error=0;
    wire audio_submit,audio_submit_slot,audio_acknowledge,audio_ack_slot,audio_last_block;
    wire [31:0] audio_address;
    wire [4:0] audio_frame_count;
    wire [63:0] audio_first_frame;
    pcm_parameter_registers dut(.*);
    integer checks=0,starts=0,audio_starts=0,submits=0,audio_submits=0,acks=0,audio_acks=0;
    integer resets=0,stops=0;
    logic [31:0] observed;
    always @(posedge clk) begin
        if(start) starts=starts+1;
        if(audio_start) audio_starts=audio_starts+1;
        if(reset_request) resets=resets+1;
        if(stop_request) stops=stops+1;
        if(submit) begin
            if(audio_submit || command_address!=32'h05001000 || command_bytes!=1024 ||
               result_address!=32'h06010000 || result_bytes!=40960 || frame_count!=16 || first_frame!=16 || !submit_slot || !last_block)
                $fatal(1,"input descriptor routing");
            submits=submits+1;
        end
        if(audio_submit) begin
            if(submit || audio_address!=32'h07000000 || audio_frame_count!=1 || audio_first_frame!=0 || audio_submit_slot || !audio_last_block)
                $fatal(1,"audio descriptor routing");
            audio_submits=audio_submits+1;
        end
        if(acknowledge) acks=acks+1;
        if(audio_acknowledge) audio_acks=audio_acks+1;
    end
    task access(input logic writing,input logic [11:0] addr,input logic [31:0] value,input logic bad);
        begin
            @(negedge clk);reg_valid=1;reg_write=writing;reg_address=addr;reg_wdata=value;
            @(posedge clk);while(!reg_ready) @(posedge clk);
            if(reg_error!=bad) $fatal(1,"register response address=%h write=%0d bad=%0d got=%0d",addr,writing,bad,reg_error);
            observed=reg_rdata;
            @(negedge clk);reg_valid=0;checks=checks+1;
        end
    endtask
    task read_value(input logic [11:0] addr,input logic [31:0] value);
        begin access(0,addr,0,0);if(observed!=value) $fatal(1,"register read address=%h got=%h expected=%h",addr,observed,value);end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        read_value(0,32'h53435034);read_value('h84,7);read_value('h18,37);read_value('ha0,17);read_value('ha4,8);read_value('ha8,11);read_value('hac,150);
        for(integer d=0;d<4;d=d+1) for(integer w=0;w<7;w=w+1)
            access(1,12'('h100+(d/2)*'h80+(d%2)*'h20+w*4),32'h5a000000+d*256+w,0);
        for(integer d=0;d<4;d=d+1) for(integer w=0;w<7;w=w+1)
            read_value(12'('h100+(d/2)*'h80+(d%2)*'h20+w*4),32'h5a000000+d*256+w);
        access(0,'h40,0,1);access(0,1,0,1);access(1,0,0,1);
        reg_wstrb=7;access(1,'h14,31,1);reg_wstrb=15;
        reset_busy=1;access(1,4,4,1);reset_busy=0;
        access(1,4,1,1);ownership=1;access(1,4,1,0);access(1,4,1,1);
        if(!active || starts!=1) $fatal(1,"start ownership");
        audio_level=31;access(1,4,16,1);audio_level=32;access(1,4,16,0);access(1,4,16,1);
        if(!audio_active || audio_starts!=1) $fatal(1,"audio start ownership");
        access(1,4,2,0);if(!pause) $fatal(1,"pause");access(1,4,0,0);if(pause) $fatal(1,"resume");
        access(1,'h120,32'h05001000,0);access(1,'h124,1024,0);access(1,'h128,32'h06010000,0);
        access(1,'h12c,40960,0);access(1,'h130,16,0);access(1,'h134,16,0);access(1,'h138,0,0);
        submit_error=1;access(1,'h13c,257,1);submit_error=0;access(1,'h13c,257,0);
        if(submits!=1) $fatal(1,"input submit pulse");
        ownership=9;access(1,'h120,0,1);acknowledge_error=1;access(1,'h13c,2,1);
        acknowledge_error=0;ownership=13;access(1,'h13c,2,0);if(acks!=1) $fatal(1,"input acknowledge");
        access(1,'h180,32'h07000000,0);access(1,'h184,8,0);access(1,'h188,0,0);access(1,'h18c,0,0);
        access(1,'h190,1,0);access(1,'h194,0,0);access(1,'h198,0,0);
        audio_submit_error=1;access(1,'h19c,257,1);audio_submit_error=0;
        access(1,'h184,16,0);access(1,'h19c,257,1);access(1,'h184,8,0);access(1,'h19c,257,0);
        if(audio_submits!=1) $fatal(1,"audio submit pulse");
        audio_ownership=2;access(1,'h180,0,1);audio_acknowledge_error=1;access(1,'h19c,2,1);
        audio_acknowledge_error=0;audio_ownership=3;access(1,'h19c,2,0);if(audio_acks!=1) $fatal(1,"audio acknowledge");
        access(1,'h14,31,0);@(negedge clk);completion=2;audio_completion=1;@(negedge clk);completion=0;audio_completion=0;
        read_value('h10,6);if(!irq) $fatal(1,"completion interrupt");access(1,'h10,2,0);read_value('h10,4);
        fault=26'h2000000;repeat(3) @(negedge clk);read_value('h10,20);read_value('hc,32'h02000000);
        access(1,'h10,31,0);read_value('h10,16);access(1,'h19c,257,0);
        access(1,'h180,32'h12345678,0);read_value('h180,32'h07000000);
        access(1,4,1,0);access(1,4,16,0);
        if(submits!=1 || audio_submits!=1 || starts!=1 || audio_starts!=1) $fatal(1,"fault writes must not publish");
        fault=0;
        fork
            access(1,'h19c,257,0);
            begin wait(dut.access_state==dut.LOAD);@(negedge clk);fault=26'h300;end
        join
        if(audio_submits!=1) $fatal(1,"fault during descriptor load must not publish");
        access(1,4,8,0);access(1,4,4,0);repeat(3) @(negedge clk);
        if(stops!=1 || resets!=1) $fatal(1,"fault stop/reset");
        @(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;fault=0;ownership=1;audio_ownership=0;
        for(integer d=0;d<4;d=d+1) for(integer w=0;w<7;w=w+1)
            read_value(12'('h100+(d/2)*'h80+(d%2)*'h20+w*4),0);
        audio_level=1;audio_finished=1;access(1,4,1,0);access(1,4,16,0);
        if(!audio_active) $fatal(1,"short EOF start");
        $display("PARAMETER_REGISTERS_PASS checks=%0d",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"watchdog");end
endmodule
