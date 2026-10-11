// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module xp3_wave_source (
    input logic clk,rst,in_valid,
    output logic in_ready,
    input logic [63:0] frame,
    input logic [5:0] voice_index,
    input logic [2:0] runtime_phase,
    input logic [1:0] sample_format,
    input logic [19:0] wave_control,sample_current,sample_loop,sample_end,fetch_state,
    input logic [17:0] accumulator,pitch_increment,address_fraction,playback_config,
    input logic [95:0] fifo,
    input logic bus16,physical16,
    input logic [3:0] bank_shift,
    input logic [15:0] irq_status,irq_mask,
    input logic irq_interrupt,irq_accepted,irq_blocked,
    output logic rom_req_valid,
    input logic rom_req_ready,
    output logic [2:0] rom_req_cs,
    output logic [23:0] rom_req_address,
    input logic rom_rsp_valid,
    output logic rom_rsp_ready,
    input logic [7:0] rom_rsp_data,
    output logic out_valid,
    input logic out_ready,
    output logic [19:0] next_control,next_address,next_fetch,
    output logic [17:0] next_accumulator,next_fraction,next_config,
    output logic [95:0] next_fifo,
    output logic [2:0] next_phase,
    output logic [1:0] next_format,
    output logic signed [19:0] sample,
    output logic filter_due,
    output logic [15:0] next_irq_status,
    output logic next_irq_interrupt,next_irq_accepted,next_irq_blocked
);
    import xp3_sample_pkg::*;
    typedef enum logic [3:0] {IDLE,START,RUN,REQUEST,RESPONSE,WAIT_SAMPLE,DONE} state_t;
    typedef enum logic [1:0] {EXP_LOW,EXP_HIGH,MANTISSA} read_t;
    state_t state;
    read_t read_kind,following_kind;
    logic [19:0] loop_reg,end_reg,request_address,following_address,advanced_address,advanced_control;
    logic [19:0] muted_control;
    logic [17:0] increment;
    logic [1:0] dither;
    logic [5:0] voice_reg;
    logic [15:0] mask_reg,advanced_irq_status;
    logic advanced_interrupt,advanced_accepted,advanced_blocked;
    logic [3:0] shift_reg,remaining,total_preload,producer;
    logic [47:0] consume_cells;
    logic [2:0] consume_remaining;
    logic bus_reg,physical_reg,preloading,interp_done;
    logic reverse_direction,looped,refresh,another_read,loop_distinct,at_boundary;
    logic [3:0] preload_count,available;
    logic [18:0] linear_phase,following_phase,phase_offset;
    logic [2:0] consume_count;
    logic [3:0] refill_count;
    logic [19:0] logical_request;
    logic [15:0] loop_event;
    logic interp_valid,interp_ready,interp_out_valid;
    logic signed [19:0] interp_sample;
    logic [35:0] interp_cells,selected_cells;

    always_comb begin
        in_ready=state==IDLE && !rst;
        out_valid=state==DONE && !rst;
        reverse_direction=next_control[11]^next_control[13];
        preload_count=7; available=0;
        if(bus_reg) begin
            preload_count=reverse_direction ? 4'd7+next_address[0] : 4'd8-next_address[0];
            if(next_fraction[3:0]!=0) begin
                if(next_fraction[3]) available=reverse_direction ? ((next_fraction[3:0]-4'd9)|4'd1)+next_address[0] : (next_fraction[3:0]&4'd6);
                if(available<preload_count) preload_count=available;
            end
        end
        linear_phase={1'b0,next_fraction[3:0],next_fraction[17:4]};
        following_phase=linear_phase+{3'b0,increment[17:2]}+((increment[1:0]>{dither[0],dither[1]}) ? 19'd1 : 19'd0);
        consume_count=(following_phase>>14)-(linear_phase>>14);
        phase_offset=next_fetch[16] ? 19'h04000 : 19'd0;
        refill_count=bus_reg ? (((following_phase+phase_offset)>>15)-((linear_phase+phase_offset)>>15))*2 : {1'b0,consume_count};
        for(integer i=0;i<3;i=i+1) selected_cells[i*12+:12]=next_fifo[((next_fraction[2:0]+i)&7)*12+:12];
        interp_valid=state==RUN;
        muted_control=next_control;
        if(next_control[19:18]==2'b10 && next_control[15] && mask_reg[8] && !next_irq_interrupt && !next_irq_accepted)
            muted_control[18]=1;

        advanced_address=next_address; advanced_control=next_control; looped=0;
        advanced_irq_status=next_irq_status; advanced_interrupt=next_irq_interrupt;
        advanced_accepted=next_irq_accepted; advanced_blocked=next_irq_blocked;
        loop_event={2'b0,voice_reg,5'b0,(next_control[14] ? 3'd6 : 3'd5)};
        if((reverse_direction ? next_address<=loop_reg : next_address>=loop_reg) && !next_control[16] && next_control[15] && mask_reg[5]) begin
            if(next_irq_interrupt && next_irq_status==loop_event) begin
                if(next_control[17]) advanced_control[16]=1; else advanced_control[17]=1;
            end else if(next_irq_interrupt || next_irq_accepted) advanced_blocked=1;
            else begin
                advanced_irq_status=loop_event; advanced_interrupt=1; advanced_accepted=1;
                if(next_control[17]) advanced_control[16]=1; else advanced_control[17]=1;
            end
        end
        if(at_boundary) begin
            if(next_control[12]) advanced_control[13]=!next_control[13];
            else if(loop_distinct) begin advanced_address=next_control[13] ? end_reg : loop_reg; looped=1; end
        end else advanced_address=reverse_direction ? next_address-20'd1 : next_address+20'd1;
        refresh=looped || advanced_address[5:0]==((advanced_control[11]^advanced_control[13]) ? 6'h3f : 6'h00);

        following_kind=MANTISSA; following_address=next_address; another_read=0;
        case(read_kind)
            EXP_LOW: begin following_kind=EXP_HIGH; following_address=request_address+20'd1; another_read=1; end
            EXP_HIGH: begin following_kind=MANTISSA; following_address=next_address; another_read=remaining!=0; end
            MANTISSA: begin
                following_address=advanced_address; another_read=remaining>1;
                if(refresh && next_format==0) begin
                    following_kind=EXP_LOW; following_address=(advanced_address&20'hfffc0)>>5; another_read=1;
                end
            end
        endcase
        rom_rsp_ready=state==RESPONSE && !rst;
        rom_req_valid=!rst && (state==REQUEST || (state==RESPONSE && rom_rsp_valid && another_read));
        logical_request=state==RESPONSE ? following_address : request_address;
        if(!bus_reg && physical_reg) logical_request[0]=0;
        rom_req_cs=next_control[6:4];
        rom_req_address={(next_control[3:0]>>shift_reg),logical_request};
    end

    xp3_interpolate interpolation (
        .clk(clk),.rst(rst),.in_valid(interp_valid),.in_ready(interp_ready),.format_code(next_format),
        .gain(next_config[4:3]),.phase(next_fraction[17:11]),.cells(interp_cells),.accumulator(next_accumulator),
        .out_valid(interp_out_valid),.out_ready(1'b1),.sample(interp_sample)
    );
    always_ff @(posedge clk) begin
        if(rst) begin state<=IDLE; sample<=0; filter_due<=0;consume_remaining<=0;end
        else begin
            // Snapshot consumer cells before overlapping ROM producer writes.
            if(state!=IDLE && consume_remaining!=0) begin
                next_accumulator<=next_accumulator+decode_delta(next_format,consume_cells[11:0]);
                consume_cells<=consume_cells>>12;consume_remaining<=consume_remaining-3'd1;
            end
            if(interp_out_valid) begin sample<=interp_sample; interp_done<=1; end
            case(state)
                IDLE: if(in_valid) begin
                    next_control<=wave_control; next_address<=sample_current; loop_reg<=sample_loop; end_reg<=sample_end;
                    // Loop/end stay fixed during this operation; compare before the ROM request path.
                    loop_distinct<=sample_loop!=sample_end;
                    at_boundary<=wave_control[13] ? sample_current==sample_loop : sample_current==sample_end;
                    next_fetch<=fetch_state; next_accumulator<=accumulator; next_fraction<=address_fraction; next_config<=playback_config;
                    next_fifo<=fifo; next_phase<=runtime_phase; next_format<=sample_format;
                    next_irq_status<=irq_status; mask_reg<=irq_mask; next_irq_interrupt<=irq_interrupt;
                    next_irq_accepted<=irq_accepted; next_irq_blocked<=irq_blocked;
                    bus_reg<=bus16; physical_reg<=physical16; shift_reg<=bank_shift; voice_reg<=voice_index;
                    increment<=pitch_increment; dither<=frame[1:0]+2'd3; preloading<=runtime_phase==1;
                    sample<=0; filter_due<=0; interp_done<=1;consume_remaining<=0;state<=START;
                end
                START: begin
                    interp_cells<=selected_cells;
                    next_control<=muted_control;
                    if(next_control[19:18]==2'b10 && next_control[15] && mask_reg[8]) begin
                        if(next_irq_interrupt || next_irq_accepted) next_irq_blocked<=1;
                        else begin next_irq_interrupt<=1; next_irq_accepted<=1; next_irq_status<={2'b0,voice_reg,8'd8}; end
                    end
                    if(next_phase==1) begin
                        next_format<=next_control[9] ? 2'd2 : next_control[7] ? 2'd1 : 2'd0;
                        next_phase<=2;
                        if(next_control[10]) state<=DONE;
                        else if(preload_count==0) begin next_control<=muted_control|20'hc0000; state<=DONE; end
                        else begin
                            total_preload<=preload_count; remaining<=preload_count; producer<=0; next_fetch<=0;
                            if(!next_control[9] && !next_control[7]) begin read_kind<=EXP_LOW; request_address<=(next_address&20'hfffc0)>>5; end
                            else begin read_kind<=MANTISSA; request_address<=next_address; end
                            state<=REQUEST;
                        end
                    end else if(next_phase==2) begin next_phase<=3; next_config<=18'h10000|(next_config&18'h1f); state<=DONE; end
                    else if(next_phase==3) begin next_phase<=4; next_config<=18'h30000|(next_config&18'h1f); state<=DONE; end
                    else if(next_phase==4) begin
                        next_config<=18'h30000|(next_config&18'h18)|{15'd0,(next_config[2:0]+3'd1)};
                        state<=(muted_control&20'hc0400)!=0 ? DONE : RUN;
                    end else state<=DONE;
                end
                RUN: if(interp_ready) begin
                    interp_done<=0; filter_due<=1;
                    next_fraction<={following_phase[13:0],following_phase[17:14]};
                    consume_remaining<=consume_count;remaining<=refill_count;
                    for(integer n=0;n<4;n=n+1) consume_cells[n*12+:12]<=next_fifo[((next_fraction[2:0]+n)&7)*12+:12];
                    producer<=next_fetch[19:16];
                    if(refill_count==0) state<=WAIT_SAMPLE;
                    else begin read_kind<=MANTISSA;request_address<=next_address;state<=REQUEST;end
                end
                REQUEST: if(rom_req_ready) state<=RESPONSE;
                RESPONSE: if(rom_rsp_valid) begin
                    if(read_kind==EXP_LOW) next_fetch[7:0]<=rom_rsp_data;
                    else if(read_kind==EXP_HIGH) next_fetch[15:8]<=rom_rsp_data;
                    else begin
                        next_fifo[producer[2:0]*12+:12]<={next_format==0 ? ((next_fetch>>({next_address[5:4],2'b0}))&4'hf) : 4'd0,rom_rsp_data};
                        producer<=producer+4'd1; remaining<=remaining-4'd1;
                        next_fetch[19:16]<=producer+4'd1;
                        next_control<=advanced_control; next_address<=advanced_address;
                        at_boundary<=advanced_control[13] ? advanced_address==loop_reg : advanced_address==end_reg;
                        next_irq_status<=advanced_irq_status; next_irq_interrupt<=advanced_interrupt;
                        next_irq_accepted<=advanced_accepted; next_irq_blocked<=advanced_blocked;
                        if(refresh && next_format!=0) next_fetch[15:0]<=0;
                    end
                    if(another_read) begin
                        read_kind<=following_kind; request_address<=following_address;
                        state<=rom_req_ready ? RESPONSE : REQUEST;
                    end else begin
                        if(preloading) begin
                            next_fetch[19:16]<=total_preload; next_control<=(read_kind==MANTISSA ? advanced_control : next_control)|20'h00080;
                        end
                        state<=interp_done ? DONE : WAIT_SAMPLE;
                    end
                end
                WAIT_SAMPLE: if(interp_done) state<=DONE;
                DONE: if(out_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
