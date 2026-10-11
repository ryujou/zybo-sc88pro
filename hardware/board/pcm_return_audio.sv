// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_return_audio (
    input logic clk,rst,run,stop,
    input logic submit,submit_slot,
    input logic [31:0] address,
    input logic [4:0] frame_count,
    input logic [63:0] first_frame,
    input logic last_block,
    output logic submit_error,
    input logic acknowledge,ack_slot,
    output logic acknowledge_error,
    output logic [3:0] ownership,
    output logic [1:0] completion,
    output logic finished,idle,
    output logic [3:0] error,
    output logic [31:0] frames,
    output logic sample_valid,
    input logic sample_ready,
    output logic signed [23:0] sample_left,sample_right,
    output logic [63:0] sample_frame,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    output logic [31:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    input logic m_axi_rvalid,
    output logic m_axi_rready,
    input logic [63:0] m_axi_rdata,
    input logic [5:0] m_axi_rid,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast
);
    localparam [1:0] FREE=0,QUEUED=1,ACTIVE=2,DONE=3;
    logic [1:0] owner[0:1];
    logic [4:0] count[0:1];
    logic [63:0] first[0:1];
    logic final_block[0:1];
    logic submit_turn,read_turn,closed,submitted,read_active;
    logic [63:0] next_frame;
    logic [4:0] accepted;
    logic [3:0] format_error;
    wire [3:0] dma_error;
    wire read_valid,read_ready,rd_done;
    wire [63:0] read_data;
    wire valid_sample=read_data[31:24]=={8{read_data[23]}} && read_data[63:56]=={8{read_data[55]}};
    wire halt=stop || error!=0;
    wire rd_start=run && !halt && !finished && !read_active && idle && owner[read_turn]==QUEUED;
    assign error=format_error!=0 ? format_error : dma_error;
    assign ownership={owner[1],owner[0]};
    assign submit_error=closed || owner[submit_slot]!=FREE || submit_slot!=submit_turn ||
                        address!=(submit_slot ? 32'h07001000 : 32'h07000000) ||
                        frame_count==0 || frame_count>16 || (submitted && first_frame!=next_frame);
    assign acknowledge_error=owner[ack_slot]!=DONE;
    assign sample_valid=read_valid && !halt && valid_sample;
    assign read_ready=sample_ready && !halt && valid_sample;
    assign sample_left=read_data[23:0];
    assign sample_right=read_data[55:32];
    assign sample_frame=first[read_turn]+{59'd0,accepted};
    pcm_block_dma dma (
        .clk,.rst,.stop(halt),.rd_start,.wr_start(1'b0),
        .rd_base(read_turn ? 32'h07001000 : 32'h07000000),.rd_bytes({24'd0,count[read_turn],3'd0}),
        .wr_base(32'd0),.wr_bytes(32'd0),.rd_idle(idle),.wr_idle(),.rd_done,.wr_done(),.rd_error(dma_error),.wr_error(),
        .read_valid,.read_ready,.read_data,.write_valid(1'b0),.write_ready(),.write_data(64'd0),
        .m_axi_arvalid,.m_axi_arready,.m_axi_araddr,.m_axi_arlen,.m_axi_rvalid,.m_axi_rready,.m_axi_rdata,.m_axi_rid,.m_axi_rresp,.m_axi_rlast,
        .m_axi_awvalid(),.m_axi_awready(1'b0),.m_axi_awaddr(),.m_axi_awlen(),.m_axi_wvalid(),.m_axi_wready(1'b0),.m_axi_wdata(),.m_axi_wlast(),
        .m_axi_bvalid(1'b0),.m_axi_bready(),.m_axi_bid(6'd0),.m_axi_bresp(2'd0)
    );
    always_ff @(posedge clk) begin
        if(rst) begin
            submit_turn<=0;read_turn<=0;closed<=0;submitted<=0;read_active<=0;next_frame<=0;
            accepted<=0;completion<=0;finished<=0;format_error<=0;frames<=0;
            for(integer i=0;i<2;i=i+1) begin owner[i]<=FREE;count[i]<=0;first[i]<=0;final_block[i]<=0;end
        end else begin
            completion<=0;
            if(submit && !submit_error && !halt) begin
                owner[submit_slot]<=QUEUED;count[submit_slot]<=frame_count;first[submit_slot]<=first_frame;
                final_block[submit_slot]<=last_block;next_frame<=first_frame+{59'd0,frame_count};
                submitted<=1;submit_turn<=!submit_turn;
                if(last_block) closed<=1;
            end
            if(acknowledge && !acknowledge_error) owner[ack_slot]<=FREE;
            if(rd_start) begin owner[read_turn]<=ACTIVE;read_active<=1;accepted<=0;end
            if(read_valid && !valid_sample && !halt) format_error<=7;
            if(sample_valid && sample_ready) begin accepted<=accepted+1'b1;frames<=frames+1'b1;end
            if(rd_done && read_active) begin
                read_active<=0;
                if(!halt) begin
                    if(accepted!=count[read_turn]) format_error<=8;
                    else begin
                        owner[read_turn]<=DONE;completion[read_turn]<=1;
                        if(final_block[read_turn]) finished<=1;
                        read_turn<=!read_turn;
                    end
                end
            end
            if(stop) closed<=1;
        end
    end
endmodule
