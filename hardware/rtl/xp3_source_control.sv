// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module xp3_source_control (
    input logic clk,rst,in_valid,
    output logic in_ready,
    input logic [63:0] frame,
    input logic [2:0] runtime_phase,playback_counter,
    input logic [17:0] pitch_current,f_current,amp_current,
    input logic [17:0] pitch_destination,f_destination,amp_destination,
    input logic [17:0] pitch_control,f_control,amp_control,pitch_increment,
    input logic [19:0] f_coefficient,
    output logic out_valid,
    input logic out_ready,
    output logic [17:0] next_pitch,next_f,next_amp,next_increment,
    output logic [19:0] next_coefficient
);
    typedef enum logic [1:0] {IDLE,WORK,DONE} state_t;
    typedef enum logic [2:0] {DECODE_IDLE,PITCH_SEND,PITCH_WAIT,F_SEND,F_WAIT} decode_t;
    typedef enum logic [2:0] {RAMP_IDLE,RAMP_SEND,RAMP_WAIT,STEP_SEND,STEP_WAIT} ramp_t;
    state_t state;
    decode_t decode_state;
    ramp_t ramp_state;
    logic select_f,linear_ramp,parity;
    logic [17:0] current_reg,target_reg,control_reg,pitch_reg,f_reg;
    logic [19:0] scratch;
    logic [6:0] divider;
    logic [17:0] initial_pitch,initial_f,selected_current,selected_target,selected_control;
    logic active_ramp,refresh;
    logic math_ready,math_valid,math_out;
    logic [19:0] math_current,math_scratch;
    logic unused_terminal,unused_complete;
    logic decode_ready,decode_out;
    logic [19:0] decoded;

    always_comb begin
        in_ready=state==IDLE && !rst;
        out_valid=state==DONE && !rst;
        initial_pitch=pitch_current;
        initial_f=f_current;
        if(runtime_phase==2) begin
            if(pitch_control==18'h04005 && pitch_destination==pitch_current) initial_pitch[0]=0;
            if(f_control==18'h04005 && f_destination==f_current) initial_f[0]=0;
        end
        selected_current=runtime_phase==3 ? initial_f : initial_pitch;
        selected_target=(runtime_phase==3 ? f_destination : pitch_destination)&18'h3fffe;
        selected_control=runtime_phase==3 ? f_control : pitch_control;
        case(selected_control[13:12])
            0:divider=0;
            1:divider=7;
            2:divider=31;
            default:divider=127;
        endcase
        active_ramp=(runtime_phase==2 || runtime_phase==3) && !selected_control[17] &&
                    (frame[9:3]&divider)==0 && selected_current!=selected_target;
        refresh=runtime_phase==2 || (runtime_phase==4 && playback_counter==5);
        math_valid=ramp_state==RAMP_SEND || ramp_state==STEP_SEND;
    end
    xp3_ramp_math math (
        .clk(clk),.rst(rst),.in_valid(math_valid),.in_ready(math_ready),
        .operation(ramp_state==STEP_SEND ? 2'd1 : linear_ramp ? 2'd0 : 2'd2),
        .current_value({2'b0,current_reg}),.target_value({2'b0,target_reg}),.scratch_value(scratch),
        .rate(control_reg[11:0]),.parity(parity),.quantum4(1'b0),.curve3(1'b0),
        .out_valid(math_out),.out_ready(1'b1),.next_current(math_current),.next_scratch(math_scratch),
        .terminal(unused_terminal),.trunk_complete(unused_complete)
    );
    xp3_control_math decode (
        .clk(clk),.rst(rst),.in_valid(decode_state==PITCH_SEND || decode_state==F_SEND),.in_ready(decode_ready),
        .combine_amp(1'b0),.pitch(decode_state==PITCH_SEND ? pitch_reg : f_reg),
        .amp(18'd0),.amp_mod(18'd0),.sum_mode(1'b0),.out_valid(decode_out),.out_ready(1'b1),.result(decoded)
    );
    always_ff @(posedge clk) begin
        if(rst) begin state<=IDLE;decode_state<=DECODE_IDLE;ramp_state<=RAMP_IDLE; end
        else begin
            case(state)
                IDLE: if(in_valid) begin
                    next_pitch<=initial_pitch;next_f<=initial_f;next_amp<=amp_current;
                    if(runtime_phase==2 && amp_control==18'h04005 && amp_destination==amp_current) next_amp[0]<=0;
                    next_increment<=pitch_increment;next_coefficient<=f_coefficient;
                    // Decode uses the pre-acknowledgement values, before the launch Ramp step.
                    pitch_reg<=pitch_current;f_reg<=f_current;
                    select_f<=runtime_phase==3;current_reg<=selected_current;target_reg<=selected_target;
                    control_reg<=selected_control;linear_ramp<=selected_control[15:14]==1;parity<=!frame[3];scratch<=0;
                    decode_state<=refresh ? PITCH_SEND : DECODE_IDLE;
                    ramp_state<=active_ramp ? RAMP_SEND : RAMP_IDLE;
                    state<=WORK;
                end
                WORK: if(decode_state==DECODE_IDLE && ramp_state==RAMP_IDLE) state<=DONE;
                DONE: if(out_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
            case(decode_state)
                PITCH_SEND: if(decode_ready) decode_state<=PITCH_WAIT;
                PITCH_WAIT: if(decode_out) begin next_increment<=decoded[17:0];decode_state<=F_SEND;end
                F_SEND: if(decode_ready) decode_state<=F_WAIT;
                F_WAIT: if(decode_out) begin next_coefficient<={decoded[17:0],2'b0};decode_state<=DECODE_IDLE;end
                default: begin end
            endcase
            case(ramp_state)
                RAMP_SEND: if(math_ready) ramp_state<=RAMP_WAIT;
                RAMP_WAIT: if(math_out) begin
                    if(linear_ramp) begin scratch<=math_scratch;ramp_state<=STEP_SEND;end
                    else begin
                        if(select_f) next_f<=math_current[17:0];else next_pitch<=math_current[17:0];
                        ramp_state<=RAMP_IDLE;
                    end
                end
                STEP_SEND: if(math_ready) ramp_state<=STEP_WAIT;
                STEP_WAIT: if(math_out) begin
                    if(select_f) next_f<=math_current[17:0];else next_pitch<=math_current[17:0];
                    ramp_state<=RAMP_IDLE;
                end
                default: begin end
            endcase
        end
    end
endmodule
