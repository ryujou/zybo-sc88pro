// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_axi_control;
    logic clk=0;always #5 clk=~clk;
    logic rst=1;
    logic [11:0] s_axi_awaddr=0,s_axi_araddr=0;
    logic [2:0] s_axi_awprot=0,s_axi_arprot=0;
    logic s_axi_awvalid=0,s_axi_wvalid=0,s_axi_bready=0,s_axi_arvalid=0,s_axi_rready=0;
    wire s_axi_awready,s_axi_wready,s_axi_bvalid,s_axi_arready,s_axi_rvalid;
    logic [31:0] s_axi_wdata=0;
    logic [3:0] s_axi_wstrb=0;
    wire [1:0] s_axi_bresp,s_axi_rresp;
    wire [31:0] s_axi_rdata;
    wire reg_valid,reg_write;
    wire [11:0] reg_address;
    wire [31:0] reg_wdata;
    wire [3:0] reg_wstrb;
    wire reg_ready,reg_error;
    wire [31:0] reg_rdata;
    pcm_axi_control dut(.*);
    logic [31:0] memory [0:15],expected [0:15];
    integer cycles=0,transactions=0,writes=0,reads=0;
    assign reg_ready=cycles%4==3;
    assign reg_error=reg_address>=64 || reg_address[1:0]!=0;
    assign reg_rdata=reg_error ? 32'hbad00000 : memory[reg_address[5:2]];
    logic stalled=0;
    logic [48:0] held;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(rst) begin
            for(integer i=0;i<16;i=i+1) memory[i]<=0;
            stalled<=0;
        end else begin
            if(stalled && (!reg_valid || {reg_write,reg_address,reg_wdata,reg_wstrb}!==held)) $fatal(1,"REGISTER_REQUEST_CHANGED");
            stalled<=reg_valid && !reg_ready;held<={reg_write,reg_address,reg_wdata,reg_wstrb};
            if(reg_valid && reg_ready) begin
                transactions=transactions+1;
                if(reg_write && !reg_error)
                    for(integer lane=0;lane<4;lane=lane+1)
                        if(reg_wstrb[lane]) memory[reg_address[5:2]][lane*8+:8]<=reg_wdata[lane*8+:8];
            end
        end
    end
    task automatic aw(input integer address,input integer delay_cycles);
        repeat(delay_cycles) @(negedge clk);
        s_axi_awaddr=12'(address);s_axi_awvalid=1;
        @(posedge clk);while(!s_axi_awready) @(posedge clk);
        @(negedge clk);s_axi_awvalid=0;
    endtask
    task automatic wd(input logic [31:0] value,input logic [3:0] strobe,input integer delay_cycles);
        repeat(delay_cycles) @(negedge clk);
        s_axi_wdata=value;s_axi_wstrb=strobe;s_axi_wvalid=1;
        @(posedge clk);while(!s_axi_wready) @(posedge clk);
        @(negedge clk);s_axi_wvalid=0;
    endtask
    task automatic write_word(input integer address,input logic [31:0] value,input logic [3:0] strobe,input integer aw_delay,input integer w_delay);
        logic [1:0] response;
        @(negedge clk);
        fork aw(address,aw_delay);wd(value,strobe,w_delay);join
        while(!s_axi_bvalid) @(negedge clk);
        response=(address>=64 || address%4!=0) ? 2'b10 : 0;
        repeat(7) begin
            if(!s_axi_bvalid || s_axi_bresp!==response) $fatal(1,"WRITE_RESPONSE");
            @(negedge clk);
        end
        s_axi_bready=1;@(negedge clk);s_axi_bready=0;writes=writes+1;
        if(response==0) for(integer lane=0;lane<4;lane=lane+1)
            if(strobe[lane]) expected[address/4][lane*8+:8]=value[lane*8+:8];
    endtask
    task automatic read_word(input integer address);
        logic [31:0] value;
        logic [1:0] response;
        @(negedge clk);s_axi_araddr=12'(address);s_axi_arvalid=1;
        @(posedge clk);while(!s_axi_arready) @(posedge clk);
        @(negedge clk);s_axi_arvalid=0;
        while(!s_axi_rvalid) @(negedge clk);
        response=(address>=64 || address%4!=0) ? 2'b10 : 0;
        value=response==0 ? expected[address/4] : 32'hbad00000;
        repeat(9) begin
            if(!s_axi_rvalid || s_axi_rresp!==response || s_axi_rdata!==value) $fatal(1,"READ_RESPONSE");
            @(negedge clk);
        end
        s_axi_rready=1;@(negedge clk);s_axi_rready=0;reads=reads+1;
    endtask
    initial begin
        for(integer i=0;i<16;i=i+1) expected[i]=0;
        repeat(4) @(negedge clk);rst=0;
        for(integer i=0;i<64;i=i+1) begin
            write_word((i%16)*4,32'h81234567 ^ (32'(i)*32'h134679bd),4'(i),i%3,(i+1)%3);
            read_word((i%16)*4);
        end
        write_word(128,0,15,2,0);read_word(128);
        write_word(3,0,15,0,2);read_word(3);
        fork write_word(0,32'hfedcba98,15,0,5);read_word(4);join
        if(transactions!=writes+reads) $fatal(1,"DUPLICATE_OR_MISSING_REGISTER_TRANSACTION");
        @(negedge clk);s_axi_awaddr=4;s_axi_awvalid=1;
        @(negedge clk);s_axi_awvalid=0;rst=1;
        repeat(3) @(negedge clk);rst=0;
        for(integer i=0;i<16;i=i+1) expected[i]=0;
        write_word(8,32'h11223344,15,4,0);read_word(8);read_word(4);
        if(transactions!=writes+reads) $fatal(1,"RESET_TRANSACTION_LEAK");
        $display("AXI_CONTROL_PASS writes=%0d reads=%0d independent_channels=1 stalls=1 reset_partial=1",writes,reads);
        $finish;
    end
    initial begin #1000000;$fatal(1,"AXI_CONTROL_TIMEOUT");end
endmodule
