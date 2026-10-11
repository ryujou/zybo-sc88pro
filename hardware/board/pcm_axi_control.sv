// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_axi_control (
    input logic clk,rst,
    input logic [11:0] s_axi_awaddr,s_axi_araddr,
    input logic [2:0] s_axi_awprot,s_axi_arprot,
    input logic s_axi_awvalid,s_axi_wvalid,s_axi_bready,s_axi_arvalid,s_axi_rready,
    output logic s_axi_awready,s_axi_wready,s_axi_bvalid,s_axi_arready,s_axi_rvalid,
    input logic [31:0] s_axi_wdata,
    input logic [3:0] s_axi_wstrb,
    output logic [1:0] s_axi_bresp,s_axi_rresp,
    output logic [31:0] s_axi_rdata,
    output logic reg_valid,reg_write,
    output logic [11:0] reg_address,
    output logic [31:0] reg_wdata,
    output logic [3:0] reg_wstrb,
    input logic reg_ready,reg_error,
    input logic [31:0] reg_rdata
);
    logic aw_held,w_held,ar_held;
    logic [11:0] aw_address,ar_address;
    logic [31:0] w_data;
    logic [3:0] w_strobe;
    assign s_axi_awready=!rst && !aw_held;
    assign s_axi_wready=!rst && !w_held;
    assign s_axi_arready=!rst && !ar_held;
    always_ff @(posedge clk) begin
        if(rst) begin
            aw_held<=0;w_held<=0;ar_held<=0;aw_address<=0;ar_address<=0;w_data<=0;w_strobe<=0;
            s_axi_bvalid<=0;s_axi_rvalid<=0;s_axi_bresp<=0;s_axi_rresp<=0;s_axi_rdata<=0;
            reg_valid<=0;reg_write<=0;reg_address<=0;reg_wdata<=0;reg_wstrb<=0;
        end else begin
            if(s_axi_awvalid && s_axi_awready) begin aw_held<=1;aw_address<=s_axi_awaddr;end
            if(s_axi_wvalid && s_axi_wready) begin w_held<=1;w_data<=s_axi_wdata;w_strobe<=s_axi_wstrb;end
            if(s_axi_arvalid && s_axi_arready) begin ar_held<=1;ar_address<=s_axi_araddr;end
            if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
            if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            if(!reg_valid) begin
                if(aw_held && w_held && !s_axi_bvalid) begin
                    reg_valid<=1;reg_write<=1;reg_address<=aw_address;reg_wdata<=w_data;reg_wstrb<=w_strobe;
                end else if(ar_held && !s_axi_rvalid) begin
                    reg_valid<=1;reg_write<=0;reg_address<=ar_address;reg_wdata<=0;reg_wstrb<=0;
                end
            end else if(reg_ready) begin
                reg_valid<=0;
                if(reg_write) begin
                    aw_held<=0;w_held<=0;s_axi_bvalid<=1;s_axi_bresp<=reg_error ? 2'b10 : 2'b00;
                end else begin
                    ar_held<=0;s_axi_rvalid<=1;s_axi_rresp<=reg_error ? 2'b10 : 2'b00;s_axi_rdata<=reg_rdata;
                end
            end
        end
    end
endmodule
