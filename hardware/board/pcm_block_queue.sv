// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_block_queue #(parameter bit PARAMETER_MODE=0) (
    input logic clk,rst,run,stop,
    input logic [5:0] highest_voice,
    input logic submit,submit_slot,
    input logic [31:0] command_address,command_bytes,result_address,result_bytes,
    input logic [4:0] frame_count,
    input logic [63:0] first_frame,
    input logic last_block,
    output logic submit_error,
    input logic acknowledge,ack_slot,
    output logic acknowledge_error,
    output logic [3:0] ownership,
    output logic [1:0] completion,
    output logic [63:0] session_first_frame,
    output logic rd_start,wr_start,
    output logic [31:0] rd_base,rd_bytes,wr_base,wr_bytes,
    input logic rd_idle,wr_idle,rd_done,wr_done,
    output logic finished
);
    localparam [1:0] FREE=0,QUEUED=1,ACTIVE=2,DONE=3;
    logic [1:0] owner[0:1];
    logic [31:0] command_base[0:1],command_length[0:1],result_base[0:1],result_length[0:1];
    logic final_block[0:1],read_finished[0:1],write_finished[0:1];
    logic rd_turn,wr_turn,submit_turn,read_active,write_active,submitted,closed,read_closed,write_closed;
    logic [63:0] next_frame;
    logic [18:0] required_result_bytes;
    logic invalid_command,invalid_result;
    // The register interface admits exactly 1/8/32/64 Voice configurations.
    always_comb begin
        case(highest_voice)
            0: required_result_bytes=(19'(frame_count)<<9)+(19'(frame_count)<<5);
            7: required_result_bytes=(19'(frame_count)<<9)+(19'(frame_count)<<8);
            31: required_result_bytes=(19'(frame_count)<<10)+(19'(frame_count)<<9);
            63: required_result_bytes=(19'(frame_count)<<11)+(19'(frame_count)<<9);
            default: required_result_bytes=0;
        endcase
    end
    always_comb begin
        if(PARAMETER_MODE) begin
            invalid_command=command_address!=(submit_slot ? 32'h05001000 : 32'h05000000) ||
                            command_bytes!={21'd0,frame_count,6'd0};
            invalid_result=result_bytes[4:0]!=0 || result_bytes<32'(frame_count)*544 ||
                           result_bytes>32'(frame_count)*2560;
        end else begin
            invalid_command=command_address[5:0]!=0 || command_bytes==0 || command_bytes[2:0]!=0 ||
                            command_address<32'h02000000 || {1'b0,command_address}+{1'b0,command_bytes}>33'h004000000;
            invalid_result=result_bytes!={13'd0,required_result_bytes};
        end
    end
    assign submit_error=owner[submit_slot]!=FREE || submit_slot!=submit_turn || closed ||
                        frame_count==0 || frame_count>16 ||
                        invalid_command ||
                        result_address!=(submit_slot ? 32'h06010000 : 32'h06000000) ||
                        invalid_result ||
                        (submitted && first_frame!=next_frame);
    assign acknowledge_error=owner[ack_slot]!=DONE;
    assign ownership={owner[1],owner[0]};
    assign rd_base=command_base[rd_turn];
    assign rd_bytes=command_length[rd_turn];
    assign wr_base=result_base[wr_turn];
    assign wr_bytes=result_length[wr_turn];
    // Reads may run ahead of writes into the command FIFO; a slot is reusable only after both finish.
    assign rd_start=run && !stop && !read_closed && !read_active && rd_idle &&
                    (owner[rd_turn]==QUEUED || owner[rd_turn]==ACTIVE) && !read_finished[rd_turn];
    assign wr_start=run && !stop && !write_closed && !write_active && wr_idle &&
                    (owner[wr_turn]==QUEUED || owner[wr_turn]==ACTIVE) && !write_finished[wr_turn];
    always_ff @(posedge clk) begin
        if(rst) begin
            rd_turn<=0;wr_turn<=0;submit_turn<=0;read_active<=0;write_active<=0;
            submitted<=0;closed<=0;read_closed<=0;write_closed<=0;
            next_frame<=0;session_first_frame<=0;completion<=0;finished<=0;
            for(integer i=0;i<2;i=i+1) begin
                owner[i]<=FREE;command_base[i]<=0;command_length[i]<=0;result_base[i]<=0;result_length[i]<=0;
                final_block[i]<=0;read_finished[i]<=0;write_finished[i]<=0;
            end
        end else begin
            completion<=0;
            if(submit && !submit_error) begin
                owner[submit_slot]<=QUEUED;
                command_base[submit_slot]<=command_address;command_length[submit_slot]<=command_bytes;
                result_base[submit_slot]<=result_address;result_length[submit_slot]<=result_bytes;
                final_block[submit_slot]<=last_block;read_finished[submit_slot]<=0;write_finished[submit_slot]<=0;
                if(!submitted) session_first_frame<=first_frame;
                submitted<=1;next_frame<=first_frame+{59'd0,frame_count};submit_turn<=!submit_turn;
                if(last_block) closed<=1;
            end
            if(acknowledge && !acknowledge_error) owner[ack_slot]<=FREE;
            if(rd_start) begin read_active<=1;owner[rd_turn]<=ACTIVE;end
            if(wr_start) begin write_active<=1;owner[wr_turn]<=ACTIVE;end
            if(rd_done && read_active) begin
                read_finished[rd_turn]<=1;read_active<=0;
                if(final_block[rd_turn]) read_closed<=1;
                rd_turn<=!rd_turn;
            end
            if(wr_done && write_active) begin
                write_finished[wr_turn]<=1;write_active<=0;
                if(final_block[wr_turn]) write_closed<=1;
                wr_turn<=!wr_turn;
            end
            for(integer i=0;i<2;i=i+1) begin
                if(!stop && owner[i]==ACTIVE && read_finished[i] && write_finished[i]) begin
                    owner[i]<=DONE;completion[i]<=1;
                    if(final_block[i]) finished<=1;
                end
            end
        end
    end
endmodule
