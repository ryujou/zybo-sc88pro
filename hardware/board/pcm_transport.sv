// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_transport #(parameter bit PARAMETER_MODE=0) (
    input logic clk,rst,run,stop,
    input logic [5:0] highest_voice,
    input logic submit,submit_slot,
    input logic [31:0] command_address,command_bytes,result_address,result_bytes,
    input logic [4:0] frame_count,
    input logic [63:0] first_frame,
    input logic last_block,
    output logic submit_error,
    input logic acknowledge,ack_slot,
    output logic acknowledge_error,
    output logic [3:0] ownership,
    output logic [1:0] completion,
    output logic [63:0] session_first_frame,
    output logic finished,idle,ready,
    output logic [7:0] fault,
    output logic command_valid,
    input logic command_ready,
    output logic [63:0] command_data,
    input logic write_valid,
    output logic write_ready,
    input logic [63:0] write_data,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    output logic [31:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    input logic m_axi_rvalid,
    output logic m_axi_rready,
    input logic [63:0] m_axi_rdata,
    input logic [5:0] m_axi_rid,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast,
    output logic m_axi_awvalid,
    input logic m_axi_awready,
    output logic [31:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic m_axi_wvalid,
    input logic m_axi_wready,
    output logic [63:0] m_axi_wdata,
    output logic m_axi_wlast,
    input logic m_axi_bvalid,
    output logic m_axi_bready,
    input logic [5:0] m_axi_bid,
    input logic [1:0] m_axi_bresp
);
    wire rd_start,wr_start,rd_idle,wr_idle,rd_done,wr_done,read_valid,read_ready;
    wire [31:0] rd_base,rd_bytes,wr_base,wr_bytes;
    wire [63:0] read_data;
    wire full,empty,wr_busy,rd_busy;
    wire halt=stop || fault!=0;
    assign ready=!wr_busy && !rd_busy && !rst;
    assign idle=rd_idle && wr_idle;
    assign read_ready=!full && ready && !halt;
    assign command_valid=!empty && ready && !halt;
    pcm_block_queue #(.PARAMETER_MODE(PARAMETER_MODE)) queue (
        .clk,.rst,.run(run && ready),.stop(halt),.highest_voice,.submit,.submit_slot,
        .command_address,.command_bytes,.result_address,.result_bytes,.frame_count,.first_frame,.last_block,.submit_error,
        .acknowledge,.ack_slot,.acknowledge_error,.ownership,.completion,.session_first_frame,
        .rd_start,.wr_start,.rd_base,.rd_bytes,.wr_base,.wr_bytes,.rd_idle,.wr_idle,.rd_done,.wr_done,.finished
    );
    pcm_block_dma dma (
        .clk,.rst,.stop(halt),.rd_start,.wr_start,.rd_base,.rd_bytes,.wr_base,.wr_bytes,
        .rd_idle,.wr_idle,.rd_done,.wr_done,.rd_error(fault[3:0]),.wr_error(fault[7:4]),
        .read_valid,.read_ready,.read_data,.write_valid,.write_ready,.write_data,
        .m_axi_arvalid,.m_axi_arready,.m_axi_araddr,.m_axi_arlen,.m_axi_rvalid,.m_axi_rready,.m_axi_rdata,.m_axi_rid,.m_axi_rresp,.m_axi_rlast,
        .m_axi_awvalid,.m_axi_awready,.m_axi_awaddr,.m_axi_awlen,.m_axi_wvalid,.m_axi_wready,.m_axi_wdata,.m_axi_wlast,
        .m_axi_bvalid,.m_axi_bready,.m_axi_bid,.m_axi_bresp
    );
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(512),.WRITE_DATA_WIDTH(64),.READ_DATA_WIDTH(64),
        .WR_DATA_COUNT_WIDTH(10),.RD_DATA_COUNT_WIDTH(10),.READ_MODE("fwft"),.FIFO_READ_LATENCY(0),
        .SIM_ASSERT_CHK(1),.USE_ADV_FEATURES("0000")
    ) command_fifo (
        .rst,.sleep(1'b0),.wr_clk(clk),.wr_en(read_valid && read_ready),.din(read_data),.full,.wr_rst_busy(wr_busy),
        .rd_en(command_valid && command_ready),.dout(command_data),.empty,.rd_rst_busy(rd_busy),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0),.wr_data_count(),.rd_data_count(),
        .prog_full(),.overflow(),.almost_full(),.wr_ack(),.prog_empty(),.underflow(),.almost_empty(),.data_valid(),.sbiterr(),.dbiterr()
    );
endmodule
