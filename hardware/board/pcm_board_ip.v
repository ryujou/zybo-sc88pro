// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_board_ip (
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER="XIL_INTERFACENAME clk, ASSOCIATED_BUSIF S_AXI:M_WAVE:M_BLOCK, ASSOCIATED_RESET resetn, FREQ_HZ 100000000" *)
    input wire clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 resetn RST", X_INTERFACE_PARAMETER="XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW" *)
    input wire resetn,
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 audio_clk CLK", X_INTERFACE_PARAMETER="XIL_INTERFACENAME audio_clk, ASSOCIATED_RESET audio_reset, FREQ_HZ 12288002" *)
    input wire audio_clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 audio_reset RST", X_INTERFACE_PARAMETER="XIL_INTERFACENAME audio_reset, POLARITY ACTIVE_HIGH" *)
    input wire audio_reset,
    output wire bclk,
    output wire lrclk,
    output wire serial_data,
    output wire mute_n,
    output wire irq,
    output wire [127:0] debug_sys0,
    output wire [127:0] debug_sys1,
    output wire [63:0] debug_audio,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input wire s_axi_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire s_axi_awready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    input wire [11:0] s_axi_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input wire [2:0] s_axi_awprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input wire s_axi_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire s_axi_wready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output wire s_axi_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input wire s_axi_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input wire s_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire s_axi_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12, READ_WRITE_MODE READ_WRITE" *)
    input wire [11:0] s_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input wire [2:0] s_axi_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output wire s_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input wire s_axi_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output wire [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARVALID" *)
    output wire m_wave_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARREADY" *)
    input wire m_wave_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_WAVE, PROTOCOL AXI4, DATA_WIDTH 64, ADDR_WIDTH 32, READ_WRITE_MODE READ_ONLY" *)
    output wire [31:0] m_wave_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARID" *)
    output wire [5:0] m_wave_arid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARLEN" *)
    output wire [7:0] m_wave_arlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARSIZE" *)
    output wire [2:0] m_wave_arsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARBURST" *)
    output wire [1:0] m_wave_arburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARLOCK" *)
    output wire m_wave_arlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARCACHE" *)
    output wire [3:0] m_wave_arcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARPROT" *)
    output wire [2:0] m_wave_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RVALID" *)
    input wire m_wave_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RREADY" *)
    output wire m_wave_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RDATA" *)
    input wire [63:0] m_wave_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RID" *)
    input wire [5:0] m_wave_rid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RRESP" *)
    input wire [1:0] m_wave_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RLAST" *)
    input wire m_wave_rlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARVALID" *)
    output wire m_block_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARREADY" *)
    input wire m_block_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_BLOCK, PROTOCOL AXI4, DATA_WIDTH 64, ADDR_WIDTH 32, READ_WRITE_MODE READ_WRITE" *)
    output wire [31:0] m_block_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARID" *)
    output wire [5:0] m_block_arid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARLEN" *)
    output wire [7:0] m_block_arlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARSIZE" *)
    output wire [2:0] m_block_arsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARBURST" *)
    output wire [1:0] m_block_arburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARLOCK" *)
    output wire m_block_arlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARCACHE" *)
    output wire [3:0] m_block_arcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARPROT" *)
    output wire [2:0] m_block_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RVALID" *)
    input wire m_block_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RREADY" *)
    output wire m_block_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RDATA" *)
    input wire [63:0] m_block_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RID" *)
    input wire [5:0] m_block_rid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RRESP" *)
    input wire [1:0] m_block_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RLAST" *)
    input wire m_block_rlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWVALID" *)
    output wire m_block_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWREADY" *)
    input wire m_block_awready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWADDR" *)
    output wire [31:0] m_block_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWID" *)
    output wire [5:0] m_block_awid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWLEN" *)
    output wire [7:0] m_block_awlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWSIZE" *)
    output wire [2:0] m_block_awsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWBURST" *)
    output wire [1:0] m_block_awburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWLOCK" *)
    output wire m_block_awlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWCACHE" *)
    output wire [3:0] m_block_awcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWPROT" *)
    output wire [2:0] m_block_awprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WVALID" *)
    output wire m_block_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WREADY" *)
    input wire m_block_wready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WDATA" *)
    output wire [63:0] m_block_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WSTRB" *)
    output wire [7:0] m_block_wstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WLAST" *)
    output wire m_block_wlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK BVALID" *)
    input wire m_block_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK BREADY" *)
    output wire m_block_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK BID" *)
    input wire [5:0] m_block_bid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK BRESP" *)
    input wire [1:0] m_block_bresp
);
    pcm_board implementation (
        .clk(clk),
        .resetn(resetn),
        .audio_clk(audio_clk),
        .audio_reset(audio_reset),
        .bclk(bclk),
        .lrclk(lrclk),
        .serial_data(serial_data),
        .mute_n(mute_n),
        .irq(irq),
        .debug_sys0(debug_sys0),
        .debug_sys1(debug_sys1),
        .debug_audio(debug_audio),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .m_wave_arvalid(m_wave_arvalid),
        .m_wave_arready(m_wave_arready),
        .m_wave_araddr(m_wave_araddr),
        .m_wave_arid(m_wave_arid),
        .m_wave_arlen(m_wave_arlen),
        .m_wave_arsize(m_wave_arsize),
        .m_wave_arburst(m_wave_arburst),
        .m_wave_arlock(m_wave_arlock),
        .m_wave_arcache(m_wave_arcache),
        .m_wave_arprot(m_wave_arprot),
        .m_wave_rvalid(m_wave_rvalid),
        .m_wave_rready(m_wave_rready),
        .m_wave_rdata(m_wave_rdata),
        .m_wave_rid(m_wave_rid),
        .m_wave_rresp(m_wave_rresp),
        .m_wave_rlast(m_wave_rlast),
        .m_block_arvalid(m_block_arvalid),
        .m_block_arready(m_block_arready),
        .m_block_araddr(m_block_araddr),
        .m_block_arid(m_block_arid),
        .m_block_arlen(m_block_arlen),
        .m_block_arsize(m_block_arsize),
        .m_block_arburst(m_block_arburst),
        .m_block_arlock(m_block_arlock),
        .m_block_arcache(m_block_arcache),
        .m_block_arprot(m_block_arprot),
        .m_block_rvalid(m_block_rvalid),
        .m_block_rready(m_block_rready),
        .m_block_rdata(m_block_rdata),
        .m_block_rid(m_block_rid),
        .m_block_rresp(m_block_rresp),
        .m_block_rlast(m_block_rlast),
        .m_block_awvalid(m_block_awvalid),
        .m_block_awready(m_block_awready),
        .m_block_awaddr(m_block_awaddr),
        .m_block_awid(m_block_awid),
        .m_block_awlen(m_block_awlen),
        .m_block_awsize(m_block_awsize),
        .m_block_awburst(m_block_awburst),
        .m_block_awlock(m_block_awlock),
        .m_block_awcache(m_block_awcache),
        .m_block_awprot(m_block_awprot),
        .m_block_wvalid(m_block_wvalid),
        .m_block_wready(m_block_wready),
        .m_block_wdata(m_block_wdata),
        .m_block_wstrb(m_block_wstrb),
        .m_block_wlast(m_block_wlast),
        .m_block_bvalid(m_block_bvalid),
        .m_block_bready(m_block_bready),
        .m_block_bid(m_block_bid),
        .m_block_bresp(m_block_bresp)
    );
endmodule
