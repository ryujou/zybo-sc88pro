// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_synth (
    input logic clk,rst,soft_reset,audio_clk,audio_reset,start,stop,pause,
    input logic [63:0] first_frame,descriptors,
    input logic [5:0] highest_voice,left_cell,right_cell,
    input logic [15:0] initial_irq_status,irq_mask,
    input logic initial_irq_interrupt,
    input logic [7:0] physical16,
    input logic [31:0] bank_shifts,
    input logic command_valid,
    output logic command_ready,
    input logic [63:0] command_data,
    output logic write_valid,
    input logic write_ready,
    output logic [63:0] write_data,
    output logic ready,ended,pause_ack,wave_idle,
    output logic [13:0] fault,
    output logic [31:0] completed,written,max_due_cycles,max_frame_cycles,
    output logic [31:0] cache_hits,cache_misses,axi_bursts,timeouts,overruns,
    output logic [5:0] audio_level,
    output logic bclk,lrclk,serial_data,mute_n,
    output logic audio_accepted,audio_mute_n,
    output logic signed [23:0] native_left,native_right,
    output logic [63:0] published_frame,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    output logic [31:0] m_axi_araddr,
    output logic [5:0] m_axi_arid,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arlock,
    output logic [3:0] m_axi_arcache,
    output logic [2:0] m_axi_arprot,
    input logic m_axi_rvalid,
    output logic m_axi_rready,
    input logic [63:0] m_axi_rdata,
    input logic [5:0] m_axi_rid,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast
);
    wire local_reset=rst || soft_reset;
    wire core_ready,audio_reset_busy,command_running,command_busy,due,audio_fault,result_fault;
    wire [3:0] command_fault;
    wire [7:0] core_fault;
    wire halt=stop || fault!=0;
    wire cfg_valid,cfg_ready,cfg_rsp_valid,cfg_rsp_ready,frame_valid,frame_ready,done_valid,done_ready;
    wire [5:0] cfg_voice,cfg_word;
    wire [31:0] cfg_wdata;
    wire [63:0] frame_id,done_frame;
    wire [15:0] frame_irq_status,done_irq_status;
    wire frame_irq_interrupt,done_irq_interrupt;
    wire out_valid,out_ready,out_first,out_last;
    wire [63:0] out_frame,out_data;
    wire sample_valid,sample_ready,bridge_mute;
    wire signed [23:0] sample_left,sample_right;
    wire finish=ended && written==completed && !sample_valid;
    logic armed;
    assign fault={audio_fault,result_fault,command_fault,core_fault};
    assign ready=core_ready && !audio_reset_busy && !local_reset && !armed;
    assign mute_n=bridge_mute && !halt;
    assign audio_mute_n=bridge_mute;
    always_ff @(posedge clk) begin
        if(local_reset) armed<=0;
        else if(start && ready) armed<=1;
    end
    pcm_commands commands (
        .clk,.rst(local_reset),.start(start && ready),.stop(halt),.pause,.due,
        .first_frame,.highest_voice,.initial_irq_status,.initial_irq_interrupt,
        .command_valid,.command_ready,.command_data,
        .cfg_valid,.cfg_ready,.cfg_rsp_valid,.cfg_rsp_ready,.cfg_voice,.cfg_word,.cfg_wdata,
        .frame_valid,.frame_ready,.frame_id,.frame_irq_status,.frame_irq_interrupt,
        .done_valid,.done_ready,.done_frame,.done_irq_status,.done_irq_interrupt,
        .running(command_running),.ended,.busy(command_busy),.error(command_fault),.completed,.max_due_cycles
    );
    pcm_voice_scheduler #(.VOICE_LIMIT(64)) core (
        .clk,.rst,.soft_reset,.ready(core_ready),.bus_idle(wave_idle),
        .frame_valid,.frame_ready,.frame_id,.frame_highest_voice(highest_voice),
        .frame_irq_status,.frame_irq_mask(irq_mask),.frame_irq_interrupt,
        .frame_descriptors(descriptors),.frame_physical16(physical16),.frame_bank_shifts(bank_shifts),
        .cfg_valid,.cfg_write(1'b1),.cfg_rsp_ready,.cfg_ready,.cfg_rsp_valid,.cfg_voice,.cfg_word,.cfg_wdata,.cfg_rsp_data(),
        .done_valid,.done_ready,.done_frame,.done_cycles(),.done_irq_status,.done_irq_interrupt,.done_irq_blocked(),
        .out_valid,.out_ready,.out_frame,.out_data,.out_first,.out_last,.consume_tick(1'b0),.fault(core_fault),
        .frames(),.max_frame_cycles,.cache_hits,.cache_misses,.unmapped_reads(),
        .axi_bursts,.axi_errors(),.timeouts,.overruns,.output_underruns(),.fifo_level(),.fifo_high_water(),
        .m_axi_arvalid,.m_axi_arready,.m_axi_araddr,.m_axi_arid,.m_axi_arlen,.m_axi_arsize,.m_axi_arburst,
        .m_axi_arlock,.m_axi_arcache,.m_axi_arprot,.m_axi_rvalid,.m_axi_rready,.m_axi_rdata,.m_axi_rid,.m_axi_rresp,.m_axi_rlast
    );
    pcm_results results (
        .clk,.rst(local_reset),.start(start && ready),.stop(halt),.first_frame,.highest_voice,.left_cell,.right_cell,
        .out_valid,.out_ready,.out_frame,.out_data,.out_first,.out_last,.write_valid,.write_ready,.write_data,
        .sample_valid,.sample_ready,.sample_left,.sample_right,.sample_frame(published_frame),.frame_written(),.frames(written),.error(result_fault)
    );
    pcm_audio_bridge audio (
        .sys_clk(clk),.sys_reset(rst),.audio_clk,.audio_reset,.clear(soft_reset),.run(armed && !halt),.pause,.finish,
        .sample_valid,.sample_ready,.sample_left,.sample_right,.level(audio_level),.due,.underrun(audio_fault),.pause_ack,
        .reset_busy(audio_reset_busy),.bclk,.lrclk,.serial_data,.mute_n(bridge_mute),.audio_accepted,.native_left,.native_right
    );
endmodule
