// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_parameter_board (
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER="XIL_INTERFACENAME clk, ASSOCIATED_BUSIF S_AXI:M_WAVE:M_BLOCK:M_AUDIO, ASSOCIATED_RESET resetn, FREQ_HZ 100000000" *)
    input logic clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 resetn RST", X_INTERFACE_PARAMETER="XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW" *)
    input logic resetn,
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 audio_clk CLK", X_INTERFACE_PARAMETER="XIL_INTERFACENAME audio_clk, ASSOCIATED_RESET audio_reset, FREQ_HZ 12288002" *)
    input logic audio_clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 audio_reset RST", X_INTERFACE_PARAMETER="XIL_INTERFACENAME audio_reset, POLARITY ACTIVE_HIGH" *)
    input logic audio_reset,
    output logic bclk,
    output logic lrclk,
    output logic serial_data,
    output logic mute_n,
    output logic irq,
    output logic [127:0] debug_sys0,
    output logic [127:0] debug_sys1,
    output logic [63:0] debug_audio,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input logic s_axi_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output logic s_axi_awready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    input logic [11:0] s_axi_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input logic [2:0] s_axi_awprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input logic s_axi_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output logic s_axi_wready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input logic [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input logic [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output logic s_axi_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input logic s_axi_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output logic [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input logic s_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output logic s_axi_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12, READ_WRITE_MODE READ_WRITE" *)
    input logic [11:0] s_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input logic [2:0] s_axi_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output logic s_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input logic s_axi_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output logic [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output logic [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARVALID" *)
    output logic m_wave_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARREADY" *)
    input logic m_wave_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_WAVE, PROTOCOL AXI4, DATA_WIDTH 64, ADDR_WIDTH 32, READ_WRITE_MODE READ_ONLY" *)
    output logic [31:0] m_wave_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARID" *)
    output logic [5:0] m_wave_arid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARLEN" *)
    output logic [7:0] m_wave_arlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARSIZE" *)
    output logic [2:0] m_wave_arsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARBURST" *)
    output logic [1:0] m_wave_arburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARLOCK" *)
    output logic m_wave_arlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARCACHE" *)
    output logic [3:0] m_wave_arcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE ARPROT" *)
    output logic [2:0] m_wave_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RVALID" *)
    input logic m_wave_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RREADY" *)
    output logic m_wave_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RDATA" *)
    input logic [63:0] m_wave_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RID" *)
    input logic [5:0] m_wave_rid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RRESP" *)
    input logic [1:0] m_wave_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_WAVE RLAST" *)
    input logic m_wave_rlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARVALID" *)
    output logic m_audio_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARREADY" *)
    input logic m_audio_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_AUDIO, PROTOCOL AXI4, DATA_WIDTH 64, ADDR_WIDTH 32, READ_WRITE_MODE READ_ONLY" *)
    output logic [31:0] m_audio_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARID" *)
    output logic [5:0] m_audio_arid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARLEN" *)
    output logic [7:0] m_audio_arlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARSIZE" *)
    output logic [2:0] m_audio_arsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARBURST" *)
    output logic [1:0] m_audio_arburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARLOCK" *)
    output logic m_audio_arlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARCACHE" *)
    output logic [3:0] m_audio_arcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO ARPROT" *)
    output logic [2:0] m_audio_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO RVALID" *)
    input logic m_audio_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO RREADY" *)
    output logic m_audio_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO RDATA" *)
    input logic [63:0] m_audio_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO RID" *)
    input logic [5:0] m_audio_rid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO RRESP" *)
    input logic [1:0] m_audio_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AUDIO RLAST" *)
    input logic m_audio_rlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARVALID" *)
    output logic m_block_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARREADY" *)
    input logic m_block_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_BLOCK, PROTOCOL AXI4, DATA_WIDTH 64, ADDR_WIDTH 32, READ_WRITE_MODE READ_WRITE" *)
    output logic [31:0] m_block_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARID" *)
    output logic [5:0] m_block_arid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARLEN" *)
    output logic [7:0] m_block_arlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARSIZE" *)
    output logic [2:0] m_block_arsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARBURST" *)
    output logic [1:0] m_block_arburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARLOCK" *)
    output logic m_block_arlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARCACHE" *)
    output logic [3:0] m_block_arcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK ARPROT" *)
    output logic [2:0] m_block_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RVALID" *)
    input logic m_block_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RREADY" *)
    output logic m_block_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RDATA" *)
    input logic [63:0] m_block_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RID" *)
    input logic [5:0] m_block_rid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RRESP" *)
    input logic [1:0] m_block_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK RLAST" *)
    input logic m_block_rlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWVALID" *)
    output logic m_block_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWREADY" *)
    input logic m_block_awready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWADDR" *)
    output logic [31:0] m_block_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWID" *)
    output logic [5:0] m_block_awid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWLEN" *)
    output logic [7:0] m_block_awlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWSIZE" *)
    output logic [2:0] m_block_awsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWBURST" *)
    output logic [1:0] m_block_awburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWLOCK" *)
    output logic m_block_awlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWCACHE" *)
    output logic [3:0] m_block_awcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK AWPROT" *)
    output logic [2:0] m_block_awprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WVALID" *)
    output logic m_block_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WREADY" *)
    input logic m_block_wready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WDATA" *)
    output logic [63:0] m_block_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WSTRB" *)
    output logic [7:0] m_block_wstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK WLAST" *)
    output logic m_block_wlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK BVALID" *)
    input logic m_block_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK BREADY" *)
    output logic m_block_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK BID" *)
    input logic [5:0] m_block_bid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_BLOCK BRESP" *)
    input logic [1:0] m_block_bresp
);

    wire rst=!resetn;
    typedef enum logic [1:0] {WAIT_READY,RUN,DRAIN,CLEAR} reset_state_t;
    reset_state_t reset_state;
    logic [6:0] clear_cycles;
    logic stopped;
    wire local_clear=reset_state==CLEAR;
    wire reset_busy=reset_state!=RUN;
    wire control_reset=rst || local_clear;
    wire [25:0] fault;
    wire halt=stopped || reset_state==DRAIN || local_clear || fault!=0;
    wire synth_ready,transport_ready,dma_idle,wave_idle,audio_idle;
    wire ready=synth_ready && transport_ready && !reset_busy;
    wire reg_valid,reg_write,reg_ready,reg_error;
    wire [11:0] reg_address;
    wire [31:0] reg_wdata,reg_rdata;
    wire [3:0] reg_wstrb;
    wire start,audio_start,pause,reset_request,stop_request,active,audio_active,ended,finished,pause_ack;
    wire input_finished,audio_finished;
    assign finished=input_finished && audio_finished;
    wire [63:0] first_frame,session_first_frame,published_frame;
    wire [5:0] audio_level;
    wire sample_valid,sample_ready;
    wire signed [23:0] sample_left,sample_right;
    wire audio_submit,audio_submit_slot,audio_acknowledge,audio_ack_slot,audio_submit_error,audio_acknowledge_error,audio_last_block;
    wire [31:0] audio_address,audio_frames,parameter_bursts,parameter_configs,parameter_packets,parameter_noops;
    wire [4:0] audio_frame_count;
    wire [63:0] audio_first_frame;
    wire [3:0] audio_ownership;
    wire [1:0] audio_completion;
    wire [31:0] completed,written,max_due_cycles,max_frame_cycles,cache_hits,cache_misses,axi_bursts,timeouts,overruns;
    wire submit,submit_slot,submit_error,acknowledge,ack_slot,acknowledge_error,last_block;
    wire [31:0] command_address,command_bytes,result_address,result_bytes;
    wire [4:0] frame_count;
    wire [3:0] ownership;
    wire [1:0] completion;
    wire command_valid,command_ready,write_valid,write_ready,audio_accepted;
    wire [63:0] command_data,write_data;
    wire signed [23:0] native_left,native_right;
    wire audio_mute_n;

    always_ff @(posedge clk) begin
        if(rst) begin reset_state<=WAIT_READY;clear_cycles<=0;stopped<=0;end
        else begin
            if(stop_request) stopped<=1;
            case(reset_state)
                WAIT_READY: if(synth_ready && transport_ready) reset_state<=RUN;
                RUN: if(reset_request) reset_state<=DRAIN;
                DRAIN: if(dma_idle && wave_idle && audio_idle) begin reset_state<=CLEAR;clear_cycles<=0;end
                CLEAR: begin
                    stopped<=0;
                    if(clear_cycles==95) reset_state<=WAIT_READY;
                    else clear_cycles<=clear_cycles+1'b1;
                end
            endcase
        end
    end
    pcm_axi_control control_bus (
        .clk,.rst,.s_axi_awvalid,.s_axi_awready,.s_axi_awaddr,.s_axi_awprot,.s_axi_wvalid,.s_axi_wready,.s_axi_wdata,.s_axi_wstrb,.s_axi_bvalid,.s_axi_bready,.s_axi_bresp,.s_axi_arvalid,.s_axi_arready,.s_axi_araddr,.s_axi_arprot,.s_axi_rvalid,.s_axi_rready,.s_axi_rdata,.s_axi_rresp,
        .reg_valid,.reg_write,.reg_address,.reg_wdata,.reg_wstrb,.reg_ready,.reg_error,.reg_rdata
    );
    pcm_parameter_registers registers (
        .clk,.rst(control_reset),.reg_valid,.reg_write,.reg_address,.reg_wdata,.reg_wstrb,.reg_ready,.reg_error,.reg_rdata,
        .ready,.reset_busy,.ended,.finished,.pause_ack,.fault,.completed,.written,.max_due_cycles,.max_frame_cycles,
        .cache_hits,.cache_misses,.axi_bursts,.timeouts,.overruns,.audio_level,.ownership,.completion,.dma_idle,.wave_idle,
        .start,.audio_start,.pause,.reset_request,.stop_request,.active,.audio_active,.irq,
        .audio_idle,.audio_ownership,.audio_completion,.audio_finished,.audio_frames,
        .parameter_bursts,.parameter_configs,.parameter_packets,.parameter_noops,
        .audio_submit,.audio_submit_slot,.audio_acknowledge,.audio_ack_slot,.audio_address,.audio_frame_count,
        .audio_first_frame,.audio_last_block,.audio_submit_error,.audio_acknowledge_error,
        .submit,.submit_slot,.command_address,.command_bytes,.result_address,.result_bytes,.frame_count,.first_frame,
        .last_block,.submit_error,.acknowledge,.ack_slot,.acknowledge_error
    );
    pcm_transport #(.PARAMETER_MODE(1)) transport (
        .clk,.rst(control_reset),.run(active),.stop(halt),.highest_voice(6'd63),
        .submit,.submit_slot,.command_address,.command_bytes,.result_address,.result_bytes,.frame_count,.first_frame,.last_block,.submit_error,
        .acknowledge,.ack_slot,.acknowledge_error,.ownership,.completion,.session_first_frame,
        .finished(input_finished),.idle(dma_idle),.ready(transport_ready),.fault(fault[21:14]),
        .command_valid,.command_ready,.command_data,.write_valid,.write_ready,.write_data,
        .m_axi_arvalid(m_block_arvalid),.m_axi_arready(m_block_arready),.m_axi_araddr(m_block_araddr),.m_axi_arlen(m_block_arlen),.m_axi_rvalid(m_block_rvalid),.m_axi_rready(m_block_rready),.m_axi_rdata(m_block_rdata),.m_axi_rid(m_block_rid),.m_axi_rresp(m_block_rresp),.m_axi_rlast(m_block_rlast),.m_axi_awvalid(m_block_awvalid),.m_axi_awready(m_block_awready),.m_axi_awaddr(m_block_awaddr),.m_axi_awlen(m_block_awlen),.m_axi_wvalid(m_block_wvalid),.m_axi_wready(m_block_wready),.m_axi_wdata(m_block_wdata),.m_axi_wlast(m_block_wlast),.m_axi_bvalid(m_block_bvalid),.m_axi_bready(m_block_bready),.m_axi_bid(m_block_bid),.m_axi_bresp(m_block_bresp)
    );
    pcm_parameter_synth synth (
        .clk,.rst,.soft_reset(local_clear),.audio_clk,.audio_reset,.start,.audio_start,.stop(halt),.pause,
        .first_frame(session_first_frame),.sample_valid,.sample_ready,.sample_left,.sample_right,.audio_finish(audio_finished),
        .command_valid,.command_ready,.command_data,.write_valid,.write_ready,.write_data,
        .ready(synth_ready),.ended,.pause_ack,.wave_idle,.fault(fault[13:0]),.completed,.written,.max_due_cycles,.max_frame_cycles,
        .cache_hits,.cache_misses,.axi_bursts,.timeouts,.overruns,.audio_level,.bclk,.lrclk,.serial_data,.mute_n,
        .audio_accepted,.audio_mute_n,.native_left,.native_right,.parameter_bursts,.parameter_configs,.parameter_packets,.parameter_noops,
        .m_axi_arvalid(m_wave_arvalid),.m_axi_arready(m_wave_arready),.m_axi_araddr(m_wave_araddr),.m_axi_arid(m_wave_arid),.m_axi_arlen(m_wave_arlen),.m_axi_arsize(m_wave_arsize),.m_axi_arburst(m_wave_arburst),.m_axi_arlock(m_wave_arlock),.m_axi_arcache(m_wave_arcache),.m_axi_arprot(m_wave_arprot),.m_axi_rvalid(m_wave_rvalid),.m_axi_rready(m_wave_rready),.m_axi_rdata(m_wave_rdata),.m_axi_rid(m_wave_rid),.m_axi_rresp(m_wave_rresp),.m_axi_rlast(m_wave_rlast)
    );
    pcm_return_audio return_audio (
        .clk,.rst(control_reset),.run(active),.stop(halt),.submit(audio_submit),.submit_slot(audio_submit_slot),
        .address(audio_address),.frame_count(audio_frame_count),.first_frame(audio_first_frame),.last_block(audio_last_block),
        .submit_error(audio_submit_error),.acknowledge(audio_acknowledge),.ack_slot(audio_ack_slot),.acknowledge_error(audio_acknowledge_error),
        .ownership(audio_ownership),.completion(audio_completion),.finished(audio_finished),.idle(audio_idle),.error(fault[25:22]),.frames(audio_frames),
        .sample_valid,.sample_ready,.sample_left,.sample_right,.sample_frame(published_frame),
        .m_axi_arvalid(m_audio_arvalid),.m_axi_arready(m_audio_arready),.m_axi_araddr(m_audio_araddr),.m_axi_arlen(m_audio_arlen),
        .m_axi_rvalid(m_audio_rvalid),.m_axi_rready(m_audio_rready),.m_axi_rdata(m_audio_rdata),.m_axi_rid(m_audio_rid),
        .m_axi_rresp(m_audio_rresp),.m_axi_rlast(m_audio_rlast)
    );
    assign m_audio_arid=0;
    assign m_audio_arsize=3;
    assign m_audio_arburst=1;
    assign m_audio_arlock=0;
    assign m_audio_arcache=4'b0011;
    assign m_audio_arprot=0;
    assign m_block_arid=0;
    assign m_block_arsize=3;
    assign m_block_arburst=1;
    assign m_block_arlock=0;
    assign m_block_arcache=4'b0011;
    assign m_block_arprot=0;
    assign m_block_awid=0;
    assign m_block_awsize=3;
    assign m_block_awburst=1;
    assign m_block_awlock=0;
    assign m_block_awcache=4'b0011;
    assign m_block_awprot=0;
    assign m_block_wstrb=8'hff;
    assign debug_sys0={fault,ownership,audio_level,max_due_cycles,completed,audio_ownership,16'd0,ready,active,reset_busy,ended,finished,pause_ack,dma_idle,wave_idle};
    assign debug_sys1={m_wave_araddr,m_wave_rdata,published_frame[15:0],9'd0,m_wave_arvalid,m_wave_arready,m_wave_rvalid,m_wave_rready,m_wave_rlast,m_wave_rresp};
    assign debug_audio={native_left,native_right,11'd0,audio_accepted,audio_mute_n,serial_data,lrclk,bclk};
endmodule
