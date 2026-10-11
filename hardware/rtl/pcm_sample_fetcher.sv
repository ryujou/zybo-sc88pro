// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_sample_fetcher #(parameter integer TAG_BITS=8) (
    input logic clk, rst, flush,
    output logic idle,
    input logic req_valid,
    output logic req_ready,
    input logic [31:0] req_address,
    input logic [TAG_BITS-1:0] req_tag,
    output logic line_valid,
    input logic line_ready,
    output logic [TAG_BITS-1:0] line_tag,
    output logic [255:0] line_data,
    output logic [3:0] line_error,
    output logic [3:0] fault,
    output logic [2:0] outstanding,
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
    logic [31:0] addresses [0:3];
    logic [TAG_BITS-1:0] tags [0:3];
    logic [255:0] data [0:3];
    logic [3:0] errors [0:3];
    logic [3:0] complete;
    logic [1:0] head,tail,issue,response;
    logic [2:0] allocated,queued,beat;
    logic flushing,accept_req,accept_ar,accept_r,retire,last_r;
    logic [10:0] ar_wait,r_wait;
    logic [3:0] beat_error,new_fault;

    assign idle=allocated==0 && !flushing && !flush && !rst;
    assign req_ready=allocated<4 && !flushing && !flush && fault==0 && !rst;
    assign line_valid=complete[head] && !flushing && !flush && !rst;
    assign line_tag=tags[head];
    assign line_data=data[head];
    assign line_error=errors[head];
    // Queued addresses remain issued during a local flush: an exposed ARVALID cannot be withdrawn.
    assign m_axi_arvalid=queued!=0 && !rst;
    assign m_axi_araddr=addresses[issue];
    assign m_axi_arid=0;
    assign m_axi_arlen=3;
    assign m_axi_arsize=3;
    assign m_axi_arburst=1;
    assign m_axi_arlock=0;
    assign m_axi_arcache=4'b0010;
    assign m_axi_arprot=0;
    assign m_axi_rready=outstanding!=0 && !rst;
    assign accept_req=req_valid && req_ready;
    assign accept_ar=m_axi_arvalid && m_axi_arready;
    assign accept_r=m_axi_rvalid && m_axi_rready;
    assign last_r=accept_r && m_axi_rlast;
    assign retire=complete[head] && (flushing || flush || line_ready) && !rst;
    assign beat_error={1'b0,(m_axi_rlast!=(beat==3)),(m_axi_rid!=0),(m_axi_rresp!=0)};
    assign new_fault=(accept_r ? beat_error : 4'b0000) |
                     (((ar_wait==1023 && m_axi_arvalid && !m_axi_arready) ||
                       (r_wait==1023 && outstanding!=0 && !accept_r)) ? 4'b1000 : 4'b0000);

    // Constant beat slices avoid a 256-bit variable write shifter for each queue entry.
    for(genvar slot=0;slot<4;slot=slot+1) begin: data_slot
        for(genvar lane=0;lane<4;lane=lane+1) begin: data_beat
            always_ff @(posedge clk) begin
                if(rst) data[slot][lane*64+:64]<=0;
                else begin
                    if(accept_req && tail==slot) data[slot][lane*64+:64]<=0;
                    if(accept_r && response==slot && beat==lane) data[slot][lane*64+:64]<=m_axi_rdata;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if(rst) begin
            complete<=0;head<=0;tail<=0;issue<=0;response<=0;
            allocated<=0;queued<=0;outstanding<=0;beat<=0;
            flushing<=0;fault<=0;ar_wait<=0;r_wait<=0;
            for(integer i=0;i<4;i=i+1) begin addresses[i]<=0;tags[i]<=0;errors[i]<=0;end
        end else begin
            allocated<=allocated+3'(accept_req)-3'(retire);
            queued<=queued+3'(accept_req)-3'(accept_ar);
            outstanding<=outstanding+3'(accept_ar)-3'(last_r);
            fault<=fault|new_fault;
            if(flush) flushing<=1;
            if(flushing && allocated==0) begin flushing<=0;fault<=0;end
            if(m_axi_arvalid && !m_axi_arready) begin
                if(ar_wait<1024) ar_wait<=ar_wait+1'b1;
            end else ar_wait<=0;
            if(outstanding!=0 && !accept_r) begin
                if(r_wait<1024) r_wait<=r_wait+1'b1;
            end else r_wait<=0;
            if(accept_req) begin
                addresses[tail]<=req_address;tags[tail]<=req_tag;errors[tail]<=0;
                tail<=tail+1'b1;
            end
            if(accept_ar) issue<=issue+1'b1;
            if(accept_r) begin
                errors[response]<=errors[response]|beat_error;
                if(m_axi_rlast) begin
                    complete[response]<=1;response<=response+1'b1;beat<=0;
                end else if(beat<7) beat<=beat+1'b1;
            end
            if(retire) begin complete[head]<=0;head<=head+1'b1;end
        end
    end
endmodule
