// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module xp3_ramp_service (
    input logic clk,rst,in_valid,
    output logic in_ready,
    input logic [2:0] kind, // 0 Amp-Mod, 1 Q, 2 F, 3 Pitch, 4 Amp
    input logic [63:0] frame,
    input logic [2:0] playback_counter,
    input logic [5:0] voice_index,
    input logic [19:0] current_value,scratch_value,decoded_value,combined_amp,
    input logic [17:0] destination,control,amp_mod_current,
    input logic amp_mod_sum,curve2_entry,
    input logic [15:0] irq_status,irq_mask,
    input logic irq_interrupt,irq_accepted,irq_blocked,
    output logic out_valid,
    input logic out_ready,
    output logic [19:0] next_current,next_scratch,next_decoded,next_combined,
    output logic [17:0] next_destination,next_control,
    output logic next_entry,
    output logic [15:0] next_irq_status,
    output logic next_irq_interrupt,next_irq_accepted,next_irq_blocked
);
    typedef enum logic [2:0] {IDLE,DECIDE,WAIT_UNITS,COMMIT_IRQ,DONE} state_t;
    state_t state;
    logic [2:0] kind_reg,counter,reason;
    logic [9:0] frame_low;
    logic [5:0] voice_reg;
    logic [19:0] current_reg,scratch_reg,target;
    logic [17:0] destination_reg,control_reg,mod_reg;
    logic mod_sum,entry_reg;
    logic [15:0] mask_reg;
    logic [6:0] service_counter;
    logic held,pending,tick_due,parity_value;
    logic need_math,need_control,math_done,control_done,wants_terminal,terminal_pending;
    logic [1:0] math_operation,active_operation;
    logic math_valid,math_ready,math_out_valid,math_out_ready,math_terminal,math_complete;
    logic [19:0] math_current,math_scratch;
    logic control_valid,control_ready,control_out_valid,control_out_ready;
    logic [19:0] control_result;
    logic [17:0] decided_destination;
    logic reset_trunk;

    always_comb begin
        in_ready=state==IDLE && !rst;
        out_valid=state==DONE && !rst;
        pending=!destination_reg[0]; held=control_reg[17];
        target=kind_reg==1 ? {destination_reg[17:1],3'b0} : {2'b0,destination_reg[17:1],1'b0};
        service_counter=kind_reg==4 ? frame_low[7:1] : frame_low[9:3];
        case(control_reg[13:12])
            0: tick_due=1;
            1: tick_due=service_counter[2:0]==0;
            2: tick_due=service_counter[4:0]==0;
            3: tick_due=service_counter==0;
        endcase
        case(kind_reg)
            0: begin parity_value=frame_low[3]; reason=3; end
            1: begin parity_value=0; reason=0; end
            2: begin parity_value=!frame_low[3]; reason=1; end
            3: begin parity_value=!frame_low[3]; reason=2; end
            default: begin parity_value=counter[1]; reason=4; end
        endcase
        decided_destination=destination_reg;
        need_math=0; need_control=0; wants_terminal=0; math_operation=2; reset_trunk=0;
        if(kind_reg==4) begin
            need_control=1;
            if(control_reg[15:14]==2 && (entry_reg || pending)) begin
                decided_destination=(current_reg[17:0] >> 1) | 18'd1;
                reset_trunk=1;
            end else if(pending && control_reg[15:14]!=3 && !held && control_reg[15:14]==1) begin
                decided_destination=destination_reg | 18'd1;
                need_math=1; math_operation=0;
            end else begin
                if(pending && control_reg[15:14]!=3 && !held) decided_destination=destination_reg | 18'd1;
                if(!held && tick_due) begin
                    need_math=1; wants_terminal=1;
                    math_operation=control_reg[15:14]==0 ? 2 : control_reg[15:14]==1 ? 1 : 3;
                end
            end
        end else begin
            if(pending) decided_destination=destination_reg | 18'd1;
            need_control=(kind_reg==2 || kind_reg==3) && (pending || current_reg!=target);
            if((kind_reg==2 || kind_reg==3) && pending && control_reg[15:14]==1) begin
                need_math=1; math_operation=0;
            end else if(!held && tick_due) begin
                need_math=1; wants_terminal=1;
                math_operation=(kind_reg==2 || kind_reg==3) && control_reg[15:14]==1 ? 1 : 2;
            end
        end
        // Both subunits have returned to idle before a new service is admitted.
        math_valid=state==DECIDE && need_math && control_ready;
        control_valid=state==DECIDE && need_control && math_ready;
        math_out_ready=state==WAIT_UNITS && !math_done;
        control_out_ready=state==WAIT_UNITS && !control_done;
    end

    xp3_ramp_math math_unit (
        .clk(clk),.rst(rst),.in_valid(math_valid),.in_ready(math_ready),.operation(math_operation),
        .current_value(current_reg),.target_value(target),.scratch_value(scratch_reg),.rate(control_reg[11:0]),
        .parity(parity_value),.quantum4(kind_reg==1),.curve3(control_reg[15:14]==3),
        .out_valid(math_out_valid),.out_ready(math_out_ready),.next_current(math_current),.next_scratch(math_scratch),
        .terminal(math_terminal),.trunk_complete(math_complete)
    );
    xp3_control_math control_unit (
        .clk(clk),.rst(rst),.in_valid(control_valid),.in_ready(control_ready),.combine_amp(kind_reg==4),
        .pitch(current_reg[17:0]),.amp(current_reg[17:0]),.amp_mod(mod_reg),.sum_mode(mod_sum),
        .out_valid(control_out_valid),.out_ready(control_out_ready),.result(control_result)
    );
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;
            next_current<=0; next_scratch<=0; next_decoded<=0; next_combined<=0;
            next_destination<=0; next_control<=0; next_entry<=0;
            next_irq_status<=0; next_irq_interrupt<=0; next_irq_accepted<=0; next_irq_blocked<=0;
        end else case(state)
            IDLE: if(in_valid) begin
                kind_reg<=kind; frame_low<=frame[9:0]; counter<=playback_counter; voice_reg<=voice_index;
                current_reg<=current_value; scratch_reg<=scratch_value; destination_reg<=destination; control_reg<=control;
                mod_reg<=amp_mod_current; mod_sum<=amp_mod_sum; entry_reg<=curve2_entry; mask_reg<=irq_mask;
                next_current<=current_value; next_scratch<=scratch_value; next_decoded<=decoded_value; next_combined<=combined_amp;
                next_destination<=destination; next_control<=control; next_entry<=curve2_entry;
                next_irq_status<=irq_status; next_irq_interrupt<=irq_interrupt; next_irq_accepted<=irq_accepted; next_irq_blocked<=irq_blocked;
                terminal_pending<=0; state<=DECIDE;
            end
            DECIDE: if(math_ready && control_ready) begin
                next_destination<=decided_destination;
                if(reset_trunk) begin next_scratch<=0; next_entry<=0; end
                active_operation<=math_operation;
                math_done<=!need_math; control_done<=!need_control;
                state<=WAIT_UNITS;
            end
            WAIT_UNITS: begin
                if(math_out_valid && math_out_ready) begin
                    next_current<=math_current; next_scratch<=math_scratch; math_done<=1;
                    if(math_complete) next_control<=next_control | 18'h04000;
                    terminal_pending<=wants_terminal && (active_operation==3 ? math_terminal : math_current==target);
                end
                if(control_out_valid && control_out_ready) begin
                    control_done<=1;
                    if(kind_reg==4) next_combined<=control_result;
                    else next_decoded<=kind_reg==2 ? (control_result << 2) : control_result;
                end
                if(math_done && control_done) state<=COMMIT_IRQ;
            end
            COMMIT_IRQ: begin
                if(terminal_pending && control_reg[16] && mask_reg[reason]) begin
                    if(next_irq_interrupt || next_irq_accepted) next_irq_blocked<=1;
                    else begin
                        next_irq_status<={2'b0,voice_reg,5'b0,reason};
                        next_irq_interrupt<=1; next_irq_accepted<=1; next_control<=next_control | 18'h20000;
                    end
                end
                state<=DONE;
            end
            DONE: if(out_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
