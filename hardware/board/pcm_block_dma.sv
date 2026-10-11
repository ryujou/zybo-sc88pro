// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_block_dma (
    input logic clk,rst,stop,
    input logic rd_start,wr_start,
    input logic [31:0] rd_base,rd_bytes,wr_base,wr_bytes,
    output logic rd_idle,wr_idle,rd_done,wr_done,
    output logic [3:0] rd_error,wr_error,
    output logic read_valid,
    input logic read_ready,
    output logic [63:0] read_data,
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
    typedef enum logic [1:0] {R_IDLE,R_ADDRESS,R_DATA,R_DRAIN} rstate_t;
    typedef enum logic [2:0] {W_IDLE,W_GATHER,W_ADDRESS,W_DATA,W_RESPONSE} wstate_t;
    rstate_t rstate;
    wstate_t wstate;
    logic [31:0] read_address,write_address;
    logic [28:0] read_remaining,write_remaining;
    logic [4:0] read_beats,read_index,write_beats,gather_index,write_index;
    logic [9:0] read_wait,write_wait;
    logic [63:0] write_buffer [0:15];
    logic read_cancel,write_cancel;
    wire bad_read=m_axi_rresp!=0 || m_axi_rid!=0 || m_axi_rlast!=(read_index+1'b1==read_beats);
    function automatic [4:0] burst_words(input logic [31:0] address,input logic [28:0] remaining);
        logic [9:0] page_words;
        logic [28:0] amount;
        begin
            page_words=(13'd4096-{1'b0,address[11:0]})>>3;
            amount=remaining<16 ? remaining : 29'd16;
            if(amount>page_words) amount={19'd0,page_words};
            burst_words=amount[4:0];
        end
    endfunction
    assign rd_idle=rstate==R_IDLE;
    assign wr_idle=wstate==W_IDLE;
    assign m_axi_arvalid=rstate==R_ADDRESS && !rst;
    assign m_axi_araddr=read_address;
    assign m_axi_arlen={3'd0,read_beats}-1'b1;
    assign m_axi_rready=!rst && ((rstate==R_DATA && (read_ready || stop || read_cancel || rd_error!=0 || bad_read)) || rstate==R_DRAIN);
    assign read_valid=!rst && rstate==R_DATA && m_axi_rvalid && !stop && !read_cancel && rd_error==0 && !bad_read;
    assign read_data=m_axi_rdata;
    assign write_ready=!rst && !stop && !write_cancel && wr_error==0 && wstate==W_GATHER;
    assign m_axi_awvalid=!rst && wstate==W_ADDRESS;
    assign m_axi_awaddr=write_address;
    assign m_axi_awlen={3'd0,write_beats}-1'b1;
    assign m_axi_wvalid=!rst && wstate==W_DATA;
    assign m_axi_wdata=write_buffer[write_index[3:0]];
    assign m_axi_wlast=write_index+1'b1==write_beats;
    assign m_axi_bready=!rst && wstate==W_RESPONSE;

    always_ff @(posedge clk) begin
        if(rst) begin
            rstate<=R_IDLE;rd_done<=0;rd_error<=0;read_address<=0;read_remaining<=0;
            read_beats<=0;read_index<=0;read_wait<=0;read_cancel<=0;
        end else begin
            rd_done<=0;
            if(stop && rstate!=R_IDLE) begin read_cancel<=1;if(rd_error==0) rd_error<=6;end
            // A timeout reports failure but cannot revoke an exposed AR or accepted R burst.
            if((m_axi_arvalid && !m_axi_arready) ||
               ((rstate==R_DATA || rstate==R_DRAIN) && !m_axi_rvalid)) begin
                if(read_wait!=1023) read_wait<=read_wait+1'b1;
                else if(rd_error==0) rd_error<=5;
            end else read_wait<=0;
            case(rstate)
                R_IDLE:if(rd_start && !stop) begin
                    read_cancel<=0;rd_error<=0;read_wait<=0;
                    if(rd_base[2:0]!=0 || rd_bytes[2:0]!=0 || rd_bytes==0) begin rd_error<=1;rd_done<=1;end
                    else begin
                        read_address<=rd_base;read_remaining<=rd_bytes[31:3];
                        read_beats<=burst_words(rd_base,rd_bytes[31:3]);read_index<=0;rstate<=R_ADDRESS;
                    end
                end
                R_ADDRESS:if(m_axi_arready) begin read_index<=0;rstate<=R_DATA;end
                R_DATA:if(m_axi_rvalid && m_axi_rready) begin
                    if(m_axi_rresp!=0 && rd_error==0) rd_error<=2;
                    else if(m_axi_rid!=0 && rd_error==0) rd_error<=4;
                    else if(m_axi_rlast!=(read_index+1'b1==read_beats) && rd_error==0) rd_error<=3;
                    if(m_axi_rlast) begin
                        if(bad_read || rd_error!=0 || stop || read_cancel || read_remaining==read_beats) begin
                            rstate<=R_IDLE;rd_done<=1;
                        end else begin
                            read_address<=read_address+{24'd0,read_beats,3'b000};
                            read_remaining<=read_remaining-read_beats;
                            read_beats<=burst_words(read_address+{24'd0,read_beats,3'b000},read_remaining-read_beats);
                            read_index<=0;rstate<=R_ADDRESS;
                        end
                    end else if(read_index+1'b1==read_beats) rstate<=R_DRAIN;
                    else read_index<=read_index+1'b1;
                end
                R_DRAIN:if(m_axi_rvalid && m_axi_rlast) begin rstate<=R_IDLE;rd_done<=1;end
                default:rstate<=R_IDLE;
            endcase
        end
    end

    // Collect a complete burst before exposing AW so stop can still finish every accepted W beat.
    always_ff @(posedge clk) begin
        if(rst) begin
            wstate<=W_IDLE;wr_done<=0;wr_error<=0;write_address<=0;write_remaining<=0;
            write_beats<=0;gather_index<=0;write_index<=0;write_wait<=0;write_cancel<=0;
        end else begin
            wr_done<=0;
            if(stop && wstate!=W_IDLE) begin write_cancel<=1;if(wr_error==0) wr_error<=6;end
            if((m_axi_awvalid && !m_axi_awready) || (m_axi_wvalid && !m_axi_wready) || (m_axi_bready && !m_axi_bvalid)) begin
                if(write_wait!=1023) write_wait<=write_wait+1'b1;
                else if(wr_error==0) wr_error<=5;
            end else write_wait<=0;
            case(wstate)
                W_IDLE:if(wr_start && !stop) begin
                    write_cancel<=0;wr_error<=0;write_wait<=0;
                    if(wr_base[2:0]!=0 || wr_bytes[2:0]!=0 || wr_bytes==0) begin wr_error<=1;wr_done<=1;end
                    else begin
                        write_address<=wr_base;write_remaining<=wr_bytes[31:3];
                        write_beats<=burst_words(wr_base,wr_bytes[31:3]);gather_index<=0;wstate<=W_GATHER;
                    end
                end
                W_GATHER:begin
                    if(stop || write_cancel || wr_error!=0) begin wstate<=W_IDLE;wr_done<=1;end
                    else if(write_valid) begin
                        write_buffer[gather_index[3:0]]<=write_data;
                        if(gather_index+1'b1==write_beats) begin write_index<=0;wstate<=W_ADDRESS;end
                        else gather_index<=gather_index+1'b1;
                    end
                end
                W_ADDRESS:if(m_axi_awready) begin write_index<=0;wstate<=W_DATA;end
                W_DATA:if(m_axi_wready) begin
                    if(m_axi_wlast) wstate<=W_RESPONSE;
                    else write_index<=write_index+1'b1;
                end
                W_RESPONSE:if(m_axi_bvalid) begin
                    if(m_axi_bresp!=0 && wr_error==0) wr_error<=2;
                    else if(m_axi_bid!=0 && wr_error==0) wr_error<=4;
                    if(m_axi_bresp!=0 || m_axi_bid!=0 || wr_error!=0 || stop || write_cancel || write_remaining==write_beats) begin
                        wstate<=W_IDLE;wr_done<=1;
                    end else begin
                        write_address<=write_address+{24'd0,write_beats,3'b000};
                        write_remaining<=write_remaining-write_beats;
                        write_beats<=burst_words(write_address+{24'd0,write_beats,3'b000},write_remaining-write_beats);
                        gather_index<=0;wstate<=W_GATHER;
                    end
                end
                default:wstate<=W_IDLE;
            endcase
        end
    end
endmodule
