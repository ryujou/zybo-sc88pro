// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_parameter_synth (
    input logic clk,rst,soft_reset,audio_clk,audio_reset,start,audio_start,stop,pause,
    input logic [63:0] first_frame,
    input logic sample_valid,audio_finish,
    output logic sample_ready,
    input logic signed [23:0] sample_left,sample_right,
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
    output logic [31:0] parameter_bursts,parameter_configs,parameter_packets,parameter_noops,
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
    wire frame_valid,frame_ready,done_valid,done_ready,metadata_valid,metadata_ready;
    wire parameter_desc_valid,parameter_desc_ready;
    wire [63:0] parameter_desc_frame,frame_descriptors;
    wire [31:0] parameter_desc_address,frame_bank_shifts;
    wire [14:0] parameter_desc_bytes;
    wire [5:0] frame_highest_voice;
    wire [15:0] frame_irq_mask;
    wire [7:0] frame_physical16;
    wire frame_last,command_ended,result_ended,drained,bridge_ready;
    wire [63:0] frame_id,done_frame;
    wire [15:0] frame_irq_status,done_irq_status;
    wire frame_irq_interrupt,done_irq_interrupt;
    wire out_valid,out_ready,out_first,out_last;
    wire [63:0] out_frame,out_data;
    wire bridge_mute;
    logic armed,audio_armed;
    assign sample_ready=bridge_ready && !halt;
    assign ended=command_ended && result_ended && audio_finish && drained && !halt;
    assign fault={audio_fault,result_fault,command_fault,core_fault};
    assign ready=core_ready && !audio_reset_busy && !local_reset && !armed;
    assign mute_n=bridge_mute && !halt;
    assign audio_mute_n=bridge_mute;
    always_ff @(posedge clk) begin
        if(local_reset) begin armed<=0;audio_armed<=0;end
        else begin
            if(start && ready) armed<=1;
            if(audio_start && armed && !halt) audio_armed<=1;
        end
    end
    pcm_parameter_commands commands (
        .clk,.rst(local_reset),.start(start && ready),.stop(halt),.pause,.due,.first_frame,
        .command_valid,.command_ready,.command_data,
        .parameter_desc_valid,.parameter_desc_ready,.parameter_desc_frame,.parameter_desc_address,.parameter_desc_bytes,
        .frame_valid,.frame_ready,.metadata_valid,.metadata_ready,.frame_id,.frame_descriptors,.frame_highest_voice,
        .frame_irq_status,.frame_irq_mask,.frame_irq_interrupt,.frame_last,.frame_physical16,.frame_bank_shifts,
        .done_valid,.done_ready,.done_frame,.done_irq_status,.done_irq_interrupt,
        .running(command_running),.ended(command_ended),.busy(command_busy),.error(command_fault),.completed,.max_due_cycles
    );
    pcm_parameter_voice_scheduler #(.VOICE_LIMIT(64)) core (
        .clk,.rst,.soft_reset,.ready(core_ready),.bus_idle(wave_idle),
        .parameter_desc_valid,.parameter_desc_ready,.parameter_desc_frame,.parameter_desc_address,.parameter_desc_bytes,
        .parameter_bursts,.parameter_configs,.parameter_packets,.parameter_noops,
        .frame_valid,.frame_ready,.frame_id,.frame_highest_voice,
        .frame_irq_status,.frame_irq_mask,.frame_irq_interrupt,
        .frame_descriptors,.frame_physical16,.frame_bank_shifts,
        .cfg_valid(1'b0),.cfg_write(1'b0),.cfg_rsp_ready(1'b1),.cfg_ready(),.cfg_rsp_valid(),
        .cfg_voice(6'd0),.cfg_word(6'd0),.cfg_wdata(32'd0),.cfg_rsp_data(),
        .done_valid,.done_ready,.done_frame,.done_cycles(),.done_irq_status,.done_irq_interrupt,.done_irq_blocked(),
        .out_valid,.out_ready,.out_frame,.out_data,.out_first,.out_last,.consume_tick(1'b0),.fault(core_fault),
        .frames(),.max_frame_cycles,.cache_hits,.cache_misses,.unmapped_reads(),
        .axi_bursts,.axi_errors(),.timeouts,.overruns,.output_underruns(),.fifo_level(),.fifo_high_water(),
        .m_axi_arvalid,.m_axi_arready,.m_axi_araddr,.m_axi_arid,.m_axi_arlen,.m_axi_arsize,.m_axi_arburst,
        .m_axi_arlock,.m_axi_arcache,.m_axi_arprot,.m_axi_rvalid,.m_axi_rready,.m_axi_rdata,.m_axi_rid,.m_axi_rresp,.m_axi_rlast
    );
    pcm_parameter_results results (
        .clk,.rst(local_reset),.start(start && ready),.stop(halt),.first_frame,
        .metadata_valid,.metadata_ready,.metadata_frame(frame_id),.metadata_highest_voice(frame_highest_voice),.metadata_last(frame_last),
        .out_valid,.out_ready,.out_frame,.out_data,.out_first,.out_last,.write_valid,.write_ready,.write_data,
        .frame_written(),.ended(result_ended),.frames(written),.level(),.error(result_fault)
    );
    pcm_audio_bridge #(.START_LEVEL(32)) audio (
        .sys_clk(clk),.sys_reset(rst),.audio_clk,.audio_reset,.clear(soft_reset),.run(audio_armed && !halt),.pause,.finish(audio_finish),
        .sample_valid(sample_valid && !halt),.sample_ready(bridge_ready),.sample_left,.sample_right,.level(audio_level),.due,.underrun(audio_fault),.pause_ack,
        .reset_busy(audio_reset_busy),.drained,.bclk,.lrclk,.serial_data,.mute_n(bridge_mute),.audio_accepted,.native_left,.native_right
    );
endmodule
