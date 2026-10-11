// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_parameter_commands (
    input logic clk,rst,start,stop,pause,due,
    input logic [63:0] first_frame,
    input logic command_valid,
    output logic command_ready,
    input logic [63:0] command_data,
    output logic parameter_desc_valid,
    input logic parameter_desc_ready,
    output logic [63:0] parameter_desc_frame,
    output logic [31:0] parameter_desc_address,
    output logic [14:0] parameter_desc_bytes,
    output logic frame_valid,
    input logic frame_ready,metadata_ready,
    output logic metadata_valid,
    output logic [63:0] frame_id,frame_descriptors,
    output logic [5:0] frame_highest_voice,
    output logic [15:0] frame_irq_status,frame_irq_mask,
    output logic frame_irq_interrupt,frame_last,
    output logic [7:0] frame_physical16,
    output logic [31:0] frame_bank_shifts,
    input logic done_valid,
    output logic done_ready,
    input logic [63:0] done_frame,
    input logic [15:0] done_irq_status,
    input logic done_irq_interrupt,
    output logic running,ended,busy,
    output logic [3:0] error,
    output logic [31:0] completed,max_due_cycles
);
    logic [2:0] word_index;
    logic have_descriptor,parameter_sent,acknowledge,closed,active_last,timed;
    logic offline;
    logic [63:0] expected_frame,active_frame;
    logic [15:0] irq_status;
    logic irq_interrupt;
    logic [5:0] credits;
    logic [12:0] age;
    logic legal;
    wire command_take=command_valid && command_ready;
    wire parameter_take=parameter_desc_valid && parameter_desc_ready;
    wire frame_take=frame_valid && frame_ready;
    wire done_take=done_valid && done_ready;
    wire tick=due && running && !offline && !closed && !stop && error==0;

    assign command_ready=running && !closed && !have_descriptor && !stop && error==0;
    assign parameter_desc_valid=running && have_descriptor && !parameter_sent && !stop && error==0;
    assign parameter_desc_frame=frame_id;
    assign frame_valid=running && have_descriptor && parameter_sent && !busy && (offline || credits!=0) &&
                       metadata_ready && !pause && !stop && error==0;
    assign metadata_valid=frame_take;
    assign frame_irq_status=irq_status;
    assign frame_irq_interrupt=irq_interrupt && !acknowledge;
    assign done_ready=running && busy && !stop && error==0;

    always_comb begin
        legal=1;
        case(word_index)
            0: legal=command_data[31:0]==32'h53434431 && command_data[63:35]==0;
            1: legal=command_data==expected_frame;
            2: legal=command_data[31:0]>=32'h12000000 && command_data[31:0]<32'h12080000 &&
                     command_data[13:0]==0 && command_data[63:32]>=32 && command_data[63:32]<=16384 &&
                     command_data[36:32]==0;
            3: legal=1;
            4: legal=command_data[7:6]==0 && command_data[15:8]==8'h1f && command_data[63:32]==0;
            default: legal=command_data==0;
        endcase
    end

    always_ff @(posedge clk) begin
        if(rst) begin
            word_index<=0;have_descriptor<=0;parameter_sent<=0;acknowledge<=0;closed<=0;
            active_last<=0;timed<=0;offline<=0;expected_frame<=0;active_frame<=0;irq_status<=0;irq_interrupt<=0;
            credits<=0;age<=0;running<=0;ended<=0;busy<=0;error<=0;completed<=0;max_due_cycles<=0;
            frame_id<=0;frame_descriptors<=0;frame_highest_voice<=0;frame_irq_mask<=0;frame_last<=0;
            frame_physical16<=0;frame_bank_shifts<=0;parameter_desc_address<=0;parameter_desc_bytes<=0;
        end else if(start && !running && !closed && !ended && error==0) begin
            running<=1;credits<=32;expected_frame<=first_frame;
        end else begin
            if(command_take) begin
                if(!legal) error<=1;
                else begin
                    case(word_index)
                        0: begin acknowledge<=command_data[32];frame_last<=command_data[33];offline<=command_data[34];end
                        1: frame_id<=command_data;
                        2: begin parameter_desc_address<=command_data[31:0];parameter_desc_bytes<=command_data[46:32];end
                        3: frame_descriptors<=command_data;
                        4: begin
                            frame_highest_voice<=command_data[5:0];frame_physical16<=command_data[15:8];
                            frame_irq_mask<=command_data[31:16];frame_bank_shifts<=command_data[63:32];
                        end
                        default: ;
                    endcase
                    if(word_index==7) begin have_descriptor<=1;parameter_sent<=0;end
                    word_index<=word_index+1'b1;
                end
            end
            if(parameter_take) parameter_sent<=1;
            if(frame_take) begin
                have_descriptor<=0;parameter_sent<=0;busy<=1;
                active_frame<=frame_id;active_last<=frame_last;expected_frame<=expected_frame+1'b1;
                if(frame_last) closed<=1;
            end
            case({tick,frame_take && !offline})
                2'b10: if(credits<32) credits<=credits+1'b1;else error<=3;
                2'b01: credits<=credits-1'b1;
                default: ;
            endcase
            if(done_take) begin
                if(done_frame!=active_frame) error<=2;
                else begin
                    busy<=0;completed<=completed+1'b1;
                    irq_status<=done_irq_status;irq_interrupt<=done_irq_interrupt;
                    if(active_last) begin ended<=1;running<=0;end
                end
            end
            // Starvation, parameter wait and metadata backpressure all count from audio due.
            if(timed) begin
                if(age<3126) age<=age+1'b1;
                if(done_take) begin
                    timed<=0;
                    if(age+1'b1>max_due_cycles) max_due_cycles<={19'd0,age}+1'b1;
                    if(age>=3125) error<=3;
                end else if(age>=3125) error<=3;
            end
            if(tick) begin
                if(timed && !done_take) error<=3;
                timed<=1;age<=0;
            end
            if(stop) begin running<=0;closed<=1;timed<=0;end
        end
    end
endmodule
