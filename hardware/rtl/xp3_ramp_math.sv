// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module xp3_ramp_math (
    input logic clk, rst, in_valid,
    output logic in_ready,
    input logic [1:0] operation, // 0: linear scratch, 1: linear step, 2: log step, 3: amp trunk
    input logic [19:0] current_value, target_value, scratch_value,
    input logic [11:0] rate,
    input logic parity, quantum4, curve3,
    output logic out_valid,
    input logic out_ready,
    output logic [19:0] next_current, next_scratch,
    output logic terminal, trunk_complete
);
    typedef enum logic [2:0] {IDLE, PREPARE, MULTIPLY, APPLY, DONE} state_t;
    state_t state;
    logic [1:0] op;
    logic [19:0] current_reg, target_reg, scratch_reg;
    logic [11:0] rate_reg;
    logic parity_reg, q4, c3, ascending, equal_target;
    logic signed [20:0] difference, divided, multiply_value;
    logic signed [33:0] product;
    logic signed [31:0] step_value, next_value, scratch_signed, delta;
    logic [19:0] computed_current, computed_scratch;
    logic computed_terminal, computed_complete;

    always_comb begin
        in_ready=state==IDLE && !rst;
        out_valid=state==DONE && !rst;
        // TVF-Q divides by four toward zero before the separate arithmetic shift by three.
        divided=q4 && op==2 ? ((difference + (difference[20] ? 21'sd3 : 21'sd0)) >>> 2) : difference;
        scratch_signed={{12{scratch_reg[19]}},scratch_reg};
        step_value=product >>> 10;
        next_value=0; delta=0;
        computed_current=current_reg; computed_scratch=scratch_reg;
        computed_terminal=0; computed_complete=0;
        case(op)
            0: computed_scratch=(step_value <<< 1) + (difference>0 ? 32'sd1 : 32'sd0);
            1: if(!equal_target) begin
                delta=(scratch_signed + (ascending && parity_reg ? 32'sd1 : 32'sd0)) >>> 1;
                next_value=$signed({1'b0,current_reg})+delta;
                if((ascending && next_value>$signed({1'b0,target_reg})) ||
                   (!ascending && next_value<$signed({1'b0,target_reg}))) next_value=$signed({1'b0,target_reg});
                computed_current={2'b0,next_value[17:0]};
            end
            2: if(!equal_target) begin
                if(q4) step_value=step_value <<< 2;
                next_value=$signed({1'b0,current_reg})+step_value;
                if((ascending && next_value<$signed({1'b0,target_reg})) || rate_reg==0)
                    next_value=next_value+(q4 ? 32'sd2 : parity_reg ? 32'sd1 : 32'sd0);
                if(next_value<0) computed_current=0;
                else if(q4) computed_current={next_value[19:1],1'b0};
                else computed_current={2'b0,next_value[17:0]};
            end
            3: begin
                next_value=$signed({1'b0,current_reg})+((scratch_signed+(parity_reg ? 32'sd1 : 32'sd0)) >>> 1);
                computed_current=(next_value<0 || next_value>32'sh3ffff) ? 20'd0 : next_value[19:0];
                delta=!ascending && !equal_target ? -$signed({1'b0,rate_reg}) : $signed({1'b0,rate_reg});
                if(!c3) begin
                    computed_scratch=scratch_signed+delta;
                    if(current_reg!=0 && computed_current==0) begin computed_terminal=1; computed_complete=1; end
                end else if(current_reg==0) begin
                    computed_scratch=scratch_signed<0 ? scratch_signed+$signed({1'b0,rate_reg}) : 20'hfffff;
                    computed_terminal=1;
                end else if(computed_current==0) computed_terminal=1;
                else computed_scratch=scratch_signed+delta;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE; next_current<=0; next_scratch<=0; terminal<=0; trunk_complete<=0;
        end else case(state)
            IDLE: if(in_valid) begin
                op<=operation; current_reg<=current_value; target_reg<=target_value; scratch_reg<=scratch_value;
                rate_reg<=rate; parity_reg<=parity; q4<=quantum4; c3<=curve3;
                ascending<=current_value<target_value; equal_target<=current_value==target_value;
                difference<=$signed({1'b0,target_value})-$signed({1'b0,current_value});
                state<=(operation==0 || operation==2) ? PREPARE : APPLY;
            end
            PREPARE: begin multiply_value<=divided >>> 3; state<=MULTIPLY; end
            MULTIPLY: begin product<=multiply_value*$signed({1'b0,rate_reg}); state<=APPLY; end
            APPLY: begin
                next_current<=computed_current; next_scratch<=computed_scratch;
                terminal<=computed_terminal; trunk_complete<=computed_complete;
                state<=DONE;
            end
            DONE: if(out_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
