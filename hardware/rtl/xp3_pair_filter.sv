// SPDX-License-Identifier: GPL-3.0-only
// Structures 2..10 preserve the fixed XP filter/TVA call order on one shared unit.
`timescale 1ns/1ps
module xp3_pair_filter #(
    parameter bit EXTERNAL_UNIT=0
) (
    input logic clk, rst, in_valid,
    output logic in_ready,
    input logic [19:0] filter_config,
    input logic [47:0] samples, old_bp, old_lp,
    input logic [39:0] frequencies, dampings,
    input logic [31:0] gains,
    output logic out_valid,
    input logic out_ready,
    output logic signed [23:0] result,
    output logic [47:0] next_bp, next_lp,
    output logic shared_valid, shared_out_ready, shared_tva,
    output logic [1:0] shared_mode,
    output logic signed [23:0] shared_sample, shared_old_bp, shared_old_lp,
    output logic [19:0] shared_frequency, shared_damping,
    output logic [15:0] shared_gain,
    input logic shared_ready, shared_done,
    input logic signed [23:0] shared_result, shared_bp, shared_lp
);
    typedef enum logic [2:0] {IDLE, ISSUE, WAIT_UNIT, RING_RESULT, DONE} state_t;
    typedef enum logic [2:0] {FINISH, FILTER, TVA, SUM, BOOST, RING} operation_t;
    typedef enum logic [1:0] {WORK, X, Y, SAVED} selector_t;
    state_t state;
    operation_t operation;
    selector_t select_a, select_b;
    logic owner, save_work, save_result,issued_owner,issued_filter,issued_save;
    logic [3:0] structure_code;
    logic [2:0] pc;
    logic [1:0] mode0, mode1, booster;
    logic signed [23:0] work_sample, x, y, saved, a, b;
    logic [23:0] bp [0:1], lp [0:1];
    logic [19:0] f [0:1], q [0:1];
    logic [15:0] gain [0:1];
    logic signed [39:0] ring_product, ring_scaled, sum_value, boost_value;
    logic unit_in_valid, unit_in_ready, unit_out_valid, unit_out_ready;
    logic signed [23:0] unit_result, unit_bp, unit_lp;
    logic local_in_ready, local_out_valid;
    logic signed [23:0] local_result, local_bp, local_lp;

    function automatic logic signed [23:0] sat24(input logic signed [39:0] value);
        if (value > 40'sd8388607) sat24=24'sh7fffff;
        else if (value < -40'sd8388608) sat24=24'sh800000;
        else sat24=value[23:0];
    endfunction
    function automatic logic signed [15:0] sat16(input logic signed [39:0] value);
        if (value > 40'sd32767) sat16=16'sh7fff;
        else if (value < -40'sd32768) sat16=16'sh8000;
        else sat16=value[15:0];
    endfunction

    always_comb begin
        operation=FINISH; owner=1; select_a=WORK; select_b=Y;
        save_work=0; save_result=0;
        case(structure_code)
            2: case(pc)
                0: operation=TVA;
                1: operation=SUM;
                2: operation=FILTER;
                3: begin operation=FILTER; owner=0; end
                4: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            3: case(pc)
                0: operation=TVA;
                1: operation=SUM;
                2: operation=FILTER;
                3: operation=BOOST;
                4: begin operation=FILTER; owner=0; end
                5: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            4: case(pc)
                0: operation=TVA;
                1: operation=SUM;
                2: operation=BOOST;
                3: operation=FILTER;
                4: begin operation=FILTER; owner=0; end
                5: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            5: case(pc)
                0: operation=TVA;
                1: operation=RING;
                2: operation=FILTER;
                3: begin operation=FILTER; owner=0; end
                4: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            6: case(pc)
                0: operation=TVA;
                1: operation=RING;
                2: operation=SUM;
                3: operation=FILTER;
                4: begin operation=FILTER; owner=0; end
                5: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            7: case(pc)
                0: operation=FILTER;
                1: operation=TVA;
                2: operation=RING;
                3: begin operation=FILTER; owner=0; end
                4: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            8: case(pc)
                0: operation=FILTER;
                1: operation=TVA;
                2: operation=RING;
                3: operation=SUM;
                4: begin operation=FILTER; owner=0; end
                5: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            9: case(pc)
                0: begin operation=FILTER; owner=0; select_a=Y; save_result=1; end
                1: begin operation=FILTER; select_a=X; end
                2: operation=TVA;
                3: begin operation=RING; select_b=SAVED; end
                4: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            10: case(pc)
                0: begin operation=FILTER; owner=0; select_a=Y; save_result=1; end
                1: begin operation=FILTER; select_a=X; end
                2: operation=TVA;
                3: begin operation=RING; select_b=SAVED; end
                4: begin operation=SUM; select_b=SAVED; end
                5: begin operation=TVA; owner=0; end
                default: operation=FINISH;
            endcase
            default: operation=FINISH;
        endcase
        case(select_a)
            WORK:a=state==WAIT_UNIT ? unit_result : work_sample; X:a=x; Y:a=y; SAVED:a=saved;
        endcase
        case(select_b)
            WORK:b=work_sample; X:b=x; Y:b=y; SAVED:b=saved;
        endcase
        in_ready=state==IDLE && !rst;
        out_valid=state==DONE && !rst;
        result=work_sample;
        next_bp={bp[1],bp[0]}; next_lp={lp[1],lp[0]};
        unit_in_valid=(state==ISSUE || (state==WAIT_UNIT && unit_out_valid)) && (operation==FILTER || operation==TVA);
        unit_out_ready=state==WAIT_UNIT;
        sum_value=$signed(a)+$signed(b);
        boost_value={{16{a[23]}},a};
        boost_value=boost_value <<< booster;
        ring_scaled=(ring_product >>> 15) + ((ring_product[39] && (|ring_product[14:0])) ? 40'sd1 : 40'sd0);
    end

    assign shared_valid=unit_in_valid;
    assign shared_out_ready=unit_out_ready;
    assign shared_tva=operation==TVA;
    assign shared_mode=owner ? mode0 : mode1;
    assign shared_sample=a;
    assign shared_old_bp=bp[owner ? 0 : 1];
    assign shared_old_lp=lp[owner ? 0 : 1];
    assign shared_frequency=f[owner ? 0 : 1];
    assign shared_damping=q[owner ? 0 : 1];
    assign shared_gain=gain[owner ? 0 : 1];
    assign unit_in_ready=EXTERNAL_UNIT ? shared_ready : local_in_ready;
    assign unit_out_valid=EXTERNAL_UNIT ? shared_done : local_out_valid;
    assign unit_result=EXTERNAL_UNIT ? shared_result : local_result;
    assign unit_bp=EXTERNAL_UNIT ? shared_bp : local_bp;
    assign unit_lp=EXTERNAL_UNIT ? shared_lp : local_lp;
    xp3_filter_tva unit (
        .clk(clk), .rst(rst), .in_valid(!EXTERNAL_UNIT && unit_in_valid), .in_ready(local_in_ready),
        .tva(shared_tva), .mode(shared_mode), .sample(shared_sample),
        .old_bp(shared_old_bp), .old_lp(shared_old_lp),
        .frequency(shared_frequency), .damping(shared_damping), .gain(shared_gain),
        .out_valid(local_out_valid), .out_ready(unit_out_ready), .result(local_result),
        .next_bp(local_bp), .next_lp(local_lp), .high_pass()
    );
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE; work_sample<=0;
        end else case(state)
            IDLE: if(in_valid) begin
                structure_code<=filter_config[15:12]+4'd1;
                mode0<=filter_config[11:10]; mode1<=filter_config[9:8]; booster<=filter_config[7:6];
                x<=samples[23:0]; y<=samples[47:24]; work_sample<=samples[23:0];
                for(integer i=0;i<2;i=i+1) begin
                    bp[i]<=old_bp[i*24+:24]; lp[i]<=old_lp[i*24+:24];
                    f[i]<=frequencies[i*20+:20]; q[i]<=dampings[i*20+:20]; gain[i]<=gains[i*16+:16];
                end
                pc<=0; state<=ISSUE;
            end
            ISSUE: case(operation)
                FILTER,TVA: if(unit_in_ready) begin
                    if(save_work) saved<=work_sample;
                    issued_owner<=owner;issued_filter<=operation==FILTER;issued_save<=save_result;pc<=pc+1;state<=WAIT_UNIT;
                end
                SUM: begin work_sample<=sat24(sum_value); pc<=pc+1; end
                BOOST: begin work_sample<=$signed(sat16(boost_value)); pc<=pc+1; end
                RING: begin ring_product<=sat16({{16{work_sample[23]}},work_sample}) * $signed(b); state<=RING_RESULT; end
                default: state<=DONE;
            endcase
            WAIT_UNIT: if(unit_out_valid) begin
                work_sample<=unit_result;
                if(issued_save) saved<=unit_result;
                if(issued_filter) begin bp[issued_owner ? 0 : 1]<=unit_bp;lp[issued_owner ? 0 : 1]<=unit_lp;end
                if(unit_in_valid && unit_in_ready) begin
                    issued_owner<=owner;issued_filter<=operation==FILTER;issued_save<=save_result;pc<=pc+1;
                end else if(operation==SUM) begin work_sample<=sat24(sum_value);pc<=pc+1;state<=ISSUE;end
                else if(operation==BOOST) begin work_sample<=$signed(sat16(boost_value));pc<=pc+1;state<=ISSUE;end
                else state<=operation==FINISH ? DONE : ISSUE;
            end
            RING_RESULT: begin work_sample<=sat24(ring_scaled); pc<=pc+1; state<=ISSUE; end
            DONE: if(out_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
