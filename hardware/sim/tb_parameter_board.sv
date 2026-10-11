// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_parameter_board #(parameter bit PLAYBACK=0);
    logic  clk='0;
    logic  resetn='0;
    logic  audio_clk='0;
    logic  audio_reset='0;
    wire  bclk;
    wire  lrclk;
    wire  serial_data;
    wire  mute_n;
    wire  irq;
    wire [127:0] debug_sys0;
    wire [127:0] debug_sys1;
    wire [63:0] debug_audio;
    logic  s_axi_awvalid='0;
    wire  s_axi_awready;
    logic [11:0] s_axi_awaddr='0;
    logic [2:0] s_axi_awprot='0;
    logic  s_axi_wvalid='0;
    wire  s_axi_wready;
    logic [31:0] s_axi_wdata='0;
    logic [3:0] s_axi_wstrb='0;
    wire  s_axi_bvalid;
    logic  s_axi_bready='0;
    wire [1:0] s_axi_bresp;
    logic  s_axi_arvalid='0;
    wire  s_axi_arready;
    logic [11:0] s_axi_araddr='0;
    logic [2:0] s_axi_arprot='0;
    wire  s_axi_rvalid;
    logic  s_axi_rready='0;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire  m_wave_arvalid;
    logic  m_wave_arready='0;
    wire [31:0] m_wave_araddr;
    wire [5:0] m_wave_arid;
    wire [7:0] m_wave_arlen;
    wire [2:0] m_wave_arsize;
    wire [1:0] m_wave_arburst;
    wire  m_wave_arlock;
    wire [3:0] m_wave_arcache;
    wire [2:0] m_wave_arprot;
    logic  m_wave_rvalid='0;
    wire  m_wave_rready;
    logic [63:0] m_wave_rdata='0;
    logic [5:0] m_wave_rid='0;
    logic [1:0] m_wave_rresp='0;
    logic  m_wave_rlast='0;
    wire  m_audio_arvalid;
    logic  m_audio_arready='0;
    wire [31:0] m_audio_araddr;
    wire [5:0] m_audio_arid;
    wire [7:0] m_audio_arlen;
    wire [2:0] m_audio_arsize;
    wire [1:0] m_audio_arburst;
    wire  m_audio_arlock;
    wire [3:0] m_audio_arcache;
    wire [2:0] m_audio_arprot;
    logic  m_audio_rvalid='0;
    wire  m_audio_rready;
    logic [63:0] m_audio_rdata='0;
    logic [5:0] m_audio_rid='0;
    logic [1:0] m_audio_rresp='0;
    logic  m_audio_rlast='0;
    wire  m_block_arvalid;
    logic  m_block_arready='0;
    wire [31:0] m_block_araddr;
    wire [5:0] m_block_arid;
    wire [7:0] m_block_arlen;
    wire [2:0] m_block_arsize;
    wire [1:0] m_block_arburst;
    wire  m_block_arlock;
    wire [3:0] m_block_arcache;
    wire [2:0] m_block_arprot;
    logic  m_block_rvalid='0;
    wire  m_block_rready;
    logic [63:0] m_block_rdata='0;
    logic [5:0] m_block_rid='0;
    logic [1:0] m_block_rresp='0;
    logic  m_block_rlast='0;
    wire  m_block_awvalid;
    logic  m_block_awready='0;
    wire [31:0] m_block_awaddr;
    wire [5:0] m_block_awid;
    wire [7:0] m_block_awlen;
    wire [2:0] m_block_awsize;
    wire [1:0] m_block_awburst;
    wire  m_block_awlock;
    wire [3:0] m_block_awcache;
    wire [2:0] m_block_awprot;
    wire  m_block_wvalid;
    logic  m_block_wready='0;
    wire [63:0] m_block_wdata;
    wire [7:0] m_block_wstrb;
    wire  m_block_wlast;
    logic  m_block_bvalid='0;
    wire  m_block_bready;
    logic [5:0] m_block_bid='0;
    logic [1:0] m_block_bresp='0;
    always #5 clk=~clk;
    always #40.690104 audio_clk=~audio_clk;
    pcm_parameter_board dut(.*);
    logic [31:0] value;
    integer checks=0;
    task write_reg(input logic [11:0] address,input logic [31:0] data);
        begin
            @(negedge clk);s_axi_awaddr=address;s_axi_awvalid=1;
            @(posedge clk);while(!s_axi_awready) @(posedge clk);
            @(negedge clk);s_axi_awvalid=0;
            repeat(2) @(negedge clk);s_axi_wdata=data;s_axi_wstrb=15;s_axi_wvalid=1;
            @(posedge clk);while(!s_axi_wready) @(posedge clk);
            @(negedge clk);s_axi_wvalid=0;s_axi_bready=1;
            @(posedge clk);while(!s_axi_bvalid) @(posedge clk);
            if(s_axi_bresp!=0) $fatal(1,"AXI write response address=%h response=%d",address,s_axi_bresp);
            @(negedge clk);s_axi_bready=0;checks=checks+1;
        end
    endtask
    task read_reg(input logic [11:0] address);
        begin
            @(negedge clk);s_axi_araddr=address;s_axi_arvalid=1;
            @(posedge clk);while(!s_axi_arready) @(posedge clk);
            @(negedge clk);s_axi_arvalid=0;s_axi_rready=1;
            @(posedge clk);while(!s_axi_rvalid) @(posedge clk);
            if(s_axi_rresp!=0) $fatal(1,"AXI read response");value=s_axi_rdata;
            @(negedge clk);s_axi_rready=0;checks=checks+1;
        end
    endtask
    task wait_ready;
        begin read_reg(8);while(!value[0]) read_reg(8);end
    endtask
    initial if(!PLAYBACK) begin
        resetn=0;audio_reset=1;m_wave_arready=1;
        repeat(64) @(negedge clk);resetn=1;audio_reset=0;
        wait_ready();read_reg(0);if(value!=32'h53435034) $fatal(1,"new board ID");
        read_reg('h84);if(value!=7) $fatal(1,"initial three bus idle");
        write_reg('h100,32'h05000000);write_reg('h104,64);write_reg('h108,32'h06000000);
        write_reg('h10c,2560);write_reg('h110,1);write_reg('h114,0);write_reg('h118,0);write_reg('h11c,257);
        write_reg('h180,32'h07000000);write_reg('h184,8);write_reg('h188,0);write_reg('h18c,0);
        write_reg('h190,1);write_reg('h194,0);write_reg('h198,0);write_reg('h19c,257);
        write_reg(4,1);wait(m_block_arvalid && m_audio_arvalid);
        if(m_block_araddr!=32'h05000000 || m_block_arlen!=7 || m_audio_araddr!=32'h07000000 || m_audio_arlen!=0)
            $fatal(1,"separate DMA port routing");
        write_reg(4,4);repeat(20) @(negedge clk);read_reg(8);
        if(!value[3] || !m_block_arvalid || !m_audio_arvalid || dut.control_reset)
            $fatal(1,"reset revoked outstanding AR");
        @(negedge clk);m_block_arready=1;m_audio_arready=1;
        @(posedge clk);@(negedge clk);m_block_arready=0;m_audio_arready=0;
        // Keep audio pending while input DMA drains, then release the third bus.
        for(integer n=0;n<8;n=n+1) begin
            m_block_rvalid=1;m_block_rlast=n==7;m_block_rdata=0;
            @(posedge clk);while(!m_block_rready) @(posedge clk);
            @(negedge clk);m_block_rvalid=0;
        end
        repeat(20) @(negedge clk);
        if(dut.control_reset || !dut.dma_idle || dut.audio_idle) $fatal(1,"reset ignored audio in-flight read");
        m_audio_rvalid=1;m_audio_rlast=1;m_audio_rdata=0;
        @(posedge clk);while(!m_audio_rready) @(posedge clk);
        @(negedge clk);m_audio_rvalid=0;
        wait_ready();read_reg('hc);if(value) $fatal(1,"fault did not clear");
        read_reg('h80);if(value) $fatal(1,"input owner did not clear");
        read_reg('h88);if(value) $fatal(1,"audio owner did not clear");
        read_reg('h84);if(value!=7 || mute_n || dut.synth.audio_accepted) $fatal(1,"reset final state");
        $display("PARAMETER_BOARD_PASS accesses=%0d independent_DMA=1 reset_drain=1",checks);$finish;
    end
    initial begin #10000000;$fatal(1,"board watchdog");end
endmodule
