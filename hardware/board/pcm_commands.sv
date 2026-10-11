// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_commands (
    input logic clk,rst,start,stop,pause,due,
    input logic [63:0] first_frame,
    input logic [5:0] highest_voice,
    input logic [15:0] initial_irq_status,
    input logic initial_irq_interrupt,
    input logic command_valid,
    output logic command_ready,
    input logic [63:0] command_data,
    output logic cfg_valid,
    input logic cfg_ready,cfg_rsp_valid,
    output logic cfg_rsp_ready,
    output logic [5:0] cfg_voice,cfg_word,
    output logic [31:0] cfg_wdata,
    output logic frame_valid,
    input logic frame_ready,
    output logic [63:0] frame_id,
    output logic [15:0] frame_irq_status,
    output logic frame_irq_interrupt,
    input logic done_valid,
    output logic done_ready,
    input logic [63:0] done_frame,
    input logic [15:0] done_irq_status,
    input logic done_irq_interrupt,
    output logic running,ended,busy,
    output logic [3:0] error,
    output logic [31:0] completed,max_due_cycles
);
    logic [5:0] highest;
    logic [1:0] credits;
    logic cfg_pending,timed;
    logic [12:0] age;
    logic allowed,legal,take,frame_take,done_take,cfg_take;
    wire [3:0] opcode=command_data[63:60];
    assign allowed=running && !stop && error==0 && !busy;
    assign cfg_voice=command_data[37:32];
    assign cfg_word=command_data[45:40];
    assign cfg_wdata=command_data[31:0];
    always_comb begin
        case(opcode)
            0: legal=(command_data & 64'h0fffc0c000000000)==0 && cfg_word<51 && cfg_voice<=highest;
            1: legal=command_data[59:6]==0 && command_data[5:0]==highest;
            2,3: legal=command_data[59:0]==0;
            default: legal=0;
        endcase
    end
    assign cfg_valid=allowed && command_valid && legal && opcode==0;
    assign cfg_rsp_ready=1;
    assign frame_valid=allowed && command_valid && legal && opcode==1 && !cfg_pending && credits!=0 && !pause;
    assign command_ready=allowed && legal && ((opcode==0 && cfg_ready) ||
                         (opcode==1 && frame_valid && frame_ready) || (opcode>=2 && !cfg_pending));
    assign cfg_take=cfg_valid && cfg_ready;
    assign frame_take=frame_valid && frame_ready;
    assign take=command_valid && command_ready;
    assign done_ready=running && busy;
    assign done_take=done_valid && done_ready;

    always_ff @(posedge clk) begin
        if(rst) begin
            running<=0;ended<=0;busy<=0;error<=0;completed<=0;max_due_cycles<=0;
            highest<=0;credits<=0;cfg_pending<=0;timed<=0;age<=0;
            frame_id<=0;frame_irq_status<=0;frame_irq_interrupt<=0;
        end else if(start && !running && !ended && error==0) begin
            running<=1;highest<=highest_voice;credits<=2;
            frame_id<=first_frame;frame_irq_status<=initial_irq_status;
            frame_irq_interrupt<=initial_irq_interrupt;
        end else begin
            if(cfg_rsp_valid) cfg_pending<=0;
            if(cfg_take) cfg_pending<=1;
            if(frame_take) busy<=1;
            case({due && running && !ended,frame_take})
                2'b10: if(credits<3) credits<=credits+1'b1;
                2'b01: credits<=credits-1'b1;
                default: ;
            endcase
            if(done_take) begin
                busy<=0;frame_id<=frame_id+1'b1;completed<=completed+1'b1;
                frame_irq_status<=done_irq_status;frame_irq_interrupt<=done_irq_interrupt;
                if(done_frame!=frame_id) error<=2;
            end
            if(take && opcode==2) frame_irq_interrupt<=0;
            if(take && opcode==3) begin ended<=1;running<=0;timed<=0;end
            if(allowed && command_valid && !legal) error<=1;
            // Measure from audio consumption, including command starvation and configuration.
            if(timed) begin
                if(age<3126) age<=age+1'b1;
                if(done_take) begin
                    timed<=0;
                    if(age+1'b1>max_due_cycles) max_due_cycles<={19'd0,age}+1'b1;
                end else if(age>=3125) error<=3;
            end
            if(due && running && !(take && opcode==3)) begin
                if((timed && !done_take) || credits==3) error<=3;
                timed<=1;age<=0;
            end
            if(stop) begin running<=0;timed<=0;end
        end
    end
endmodule
