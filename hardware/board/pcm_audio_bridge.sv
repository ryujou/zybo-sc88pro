// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_audio_bridge #(parameter integer START_LEVEL=2) (
    input logic sys_clk,sys_reset,audio_clk,audio_reset,clear,run,pause,finish,
    input logic sample_valid,
    output logic sample_ready,
    input logic signed [23:0] sample_left,sample_right,
    output logic [5:0] level,
    output logic due,underrun,pause_ack,reset_busy,drained,
    output logic bclk,lrclk,serial_data,mute_n,
    output logic audio_accepted,
    output logic signed [23:0] native_left,native_right
);
    wire full,empty,wr_busy,rd_busy;
    wire [47:0] fifo_data;
    wire fifo_pop,sink_ready,sink_underrun,sink_tick;
    logic primed;
    wire run_audio,pause_audio,clear_audio,primed_audio,finish_audio;
    logic due_toggle;
    (* ASYNC_REG="TRUE" *) logic [2:0] due_sync,fault_sync,pause_sync,drained_sync;
    logic due_previous;
    logic paused_audio,drained_audio,read_seen;
    assign sample_ready=!full && !wr_busy && !sys_reset && !clear;
    assign fifo_pop=sink_ready && !empty && !rd_busy;
    assign due=due_sync[2]^due_previous;
    assign underrun=fault_sync[2];
    assign pause_ack=pause_sync[2];
    assign reset_busy=wr_busy || sys_reset || clear;
    assign drained=drained_sync[2] && finish && level==0 && !reset_busy;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"),.FIFO_WRITE_DEPTH(32),
        .WRITE_DATA_WIDTH(48),.READ_DATA_WIDTH(48),.WR_DATA_COUNT_WIDTH(6),.RD_DATA_COUNT_WIDTH(6),
        .READ_MODE("fwft"),.FIFO_READ_LATENCY(0),.CDC_SYNC_STAGES(3),.SIM_ASSERT_CHK(1),.USE_ADV_FEATURES("0707")
    ) samples (
        .rst(sys_reset || clear),.sleep(1'b0),.wr_clk(sys_clk),.rd_clk(audio_clk),
        .wr_en(sample_valid && sample_ready),.din({sample_left,sample_right}),.full,.wr_rst_busy(wr_busy),.wr_data_count(level),
        .rd_en(fifo_pop),.dout(fifo_data),.empty,.rd_rst_busy(rd_busy),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0),
        .prog_full(),.overflow(),.almost_full(),.wr_ack(),.prog_empty(),.rd_data_count(),.underflow(),.almost_empty(),.data_valid(),.sbiterr(),.dbiterr()
    );
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(1),.SIM_ASSERT_CHK(1)) run_cdc
        (.src_clk(sys_clk),.src_in(run),.dest_clk(audio_clk),.dest_out(run_audio));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.SIM_ASSERT_CHK(1)) pause_cdc
        (.src_clk(sys_clk),.src_in(pause),.dest_clk(audio_clk),.dest_out(pause_audio));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(1),.SIM_ASSERT_CHK(1)) clear_cdc
        (.src_clk(sys_clk),.src_in(clear),.dest_clk(audio_clk),.dest_out(clear_audio));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.SIM_ASSERT_CHK(1)) primed_cdc
        (.src_clk(sys_clk),.src_in(primed),.dest_clk(audio_clk),.dest_out(primed_audio));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(1),.SIM_ASSERT_CHK(1)) finish_cdc
        (.src_clk(sys_clk),.src_in(finish),.dest_clk(audio_clk),.dest_out(finish_audio));
    pcm_i2s transmitter (
        .clk(audio_clk),.rst(audio_reset || clear_audio || rd_busy),.enable(run_audio && primed_audio && !(finish_audio && empty)),.pause(pause_audio),
        .sample_valid(!empty && !rd_busy),.sample_ready(sink_ready),.sample_left(fifo_data[47:24]),.sample_right(fifo_data[23:0]),
        .bclk,.lrclk,.serial_data,.mute_n,.frame_tick(sink_tick),.underrun(sink_underrun),.native_left,.native_right
    );
    always_ff @(posedge sys_clk) begin
        if(sys_reset || clear) begin primed<=0;due_sync<=0;due_previous<=0;fault_sync<=0;pause_sync<=0;drained_sync<=0;end
        else begin
            if((level>=START_LEVEL || (finish && level!=0)) && !wr_busy) primed<=1;
            due_sync<={due_sync[1:0],due_toggle};due_previous<=due_sync[2];
            fault_sync<={fault_sync[1:0],sink_underrun};pause_sync<={pause_sync[1:0],paused_audio};
            drained_sync<={drained_sync[1:0],drained_audio};
        end
    end
    always_ff @(posedge audio_clk) begin
        if(audio_reset || clear_audio || rd_busy) begin due_toggle<=0;audio_accepted<=0;paused_audio<=0;drained_audio<=0;read_seen<=0;end
        else begin
            paused_audio<=pause_audio && !mute_n && !sink_underrun;
            drained_audio<=finish_audio && read_seen && empty && !mute_n && !sink_underrun;
            audio_accepted<=fifo_pop;
            if(fifo_pop) begin due_toggle<=!due_toggle;read_seen<=1;end
        end
    end
endmodule
