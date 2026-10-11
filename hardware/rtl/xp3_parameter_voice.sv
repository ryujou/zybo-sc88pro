// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module xp3_parameter_voice (
    input logic param_valid,
    output logic param_ready,
    input logic [63:0] param_frame,
    input logic [5:0] param_voice,
    input logic [2:0] param_stage,
    input logic [21:0] param_mask,
    input logic [703:0] param_values,
    input logic param_terminal,
    input logic [2:0] param_reason,
    output logic param_req_valid,
    output logic [63:0] param_req_frame,
    output logic [5:0] param_req_voice,
    output logic [2:0] param_req_stage,
    output logic param_fault,
    input logic clk,
    input logic rst,
    input logic cmd_valid,
    input logic cmd_pair,
    input logic cmd_irq_interrupt,
    input logic cmd_irq_accepted,
    input logic cmd_irq_blocked,
    input logic done_ready,
    input logic cfg_valid,
    input logic cfg_write,
    input logic cfg_rsp_ready,
    input logic rom_req_ready,
    input logic rom_rsp_valid,
    output logic cmd_ready,
    output logic done_valid,
    output logic done_irq_interrupt,
    output logic done_irq_accepted,
    output logic done_irq_blocked,
    output logic cfg_ready,
    output logic cfg_rsp_valid,
    output logic rom_req_valid,
    output logic rom_rsp_ready,
    output logic rom_req_partner,
    output logic ready,
    input logic [63:0] cmd_frame,
    input logic [5:0] cmd_voice,
    input logic [5:0] cfg_voice,
    input logic [5:0] cfg_word,
    input logic [15:0] cmd_irq_status,
    input logic [15:0] cmd_irq_mask,
    input logic [63:0] cmd_descriptors,
    input logic [7:0] cmd_physical16,
    input logic [7:0] rom_rsp_data,
    input logic [31:0] cmd_bank_shifts,
    input logic [31:0] cfg_wdata,
    output logic [31:0] cfg_rsp_data,
    output logic [63:0] done_frame,
    output logic [5:0] done_voice,
    output logic [15:0] done_irq_status,
    output logic [1:0] done_filter_due,
    output logic signed [23:0] done_prior_owner,
    output logic signed [23:0] done_prior_partner,
    output logic signed [23:0] done_output_owner,
    output logic signed [23:0] done_output_partner,
    output logic signed [19:0] done_sample_owner,
    output logic signed [19:0] done_sample_partner,
    output logic [39:0] done_source_owner,
    output logic [39:0] done_source_partner,
    output logic [2:0] rom_req_cs,
    output logic [23:0] rom_req_address
);
    typedef enum logic [4:0] {IDLE,CFG_READ,CFG_DONE,LOAD,LOAD_LAST,PREPARE,SOURCE_WAIT,PARAM_WAIT,PARAM_NEXT,NEXT_LANE,FILTER_WAIT,TVA_SEND,TVA_WAIT,PAIR_WAIT,STORE,DONE} state_t;
    state_t state;
    logic [31:0] work [0:1][0:63];
    logic [63:0] dirty [0:1];
    logic paired,lane,load_lane,read_lane;
    logic [2:0] phase_before,hook_stage;
    logic [21:0] allowed_mask;
    logic parameter_bad;
    logic [5:0] hold_word;
    logic [31:0] terminal_control;
    assign done_source_owner={work[0][0][19:0],work[0][1][19:0]};
    assign done_source_partner=paired ? {work[1][0][19:0],work[1][1][19:0]} : 40'd0;
    logic [2:0] row,read_row;
    logic read_pending,ram_ready,ram_read,background_load,partner_loaded,background_store,store_lane;
    logic [2:0] background_row,store_index,store_row,write_row;
    logic write_lane;
    logic [8:0] ram_raddr,ram_waddr;
    logic [7:0] ram_we;
    logic [255:0] ram_rdata,ram_wdata;
    logic [5:0] config_word;
    logic [63:0] descriptors;
    logic [7:0] physical;
    logic [31:0] shifts;
    logic [15:0] irq_mask;
    logic [5:0] active_voice;
    logic [2:0] cs,kind,phase_input;
    logic [1:0] format_input;
    logic chain_tva;
    logic [95:0] fifo,source_fifo;
    logic source_ready,source_done,source_due;
    logic [19:0] source_control,source_address,source_fetch;
    logic [17:0] source_accumulator,source_fraction,source_config;
    logic [2:0] source_phase;
    logic [1:0] source_format;
    logic signed [19:0] source_sample;
    logic [15:0] source_irq_status;
    logic source_irq_interrupt,source_irq_accepted,source_irq_blocked;
    logic filter_ready,filter_done,pair_ready,pair_done;
    logic signed [23:0] filter_result,filter_bp,filter_lp,filter_hp,filtered,pair_result;
    logic [47:0] pair_bp,pair_lp;
    logic pair_unit_valid,pair_unit_out_ready,pair_unit_tva;
    logic [1:0] pair_unit_mode;
    logic signed [23:0] pair_unit_sample,pair_unit_old_bp,pair_unit_old_lp;
    logic [19:0] pair_unit_frequency,pair_unit_damping;
    logic [15:0] pair_unit_gain;
    logic [19:0] gain_sum;
    function automatic logic [31:0] field_mask(input logic [5:0] index);
        case(index)
            6'd0:field_mask=32'h000fffff;
            6'd1:field_mask=32'h000fffff;
            6'd2:field_mask=32'h000fffff;
            6'd3:field_mask=32'h000fffff;
            6'd4:field_mask=32'h000fffff;
            6'd5:field_mask=32'h0003ffff;
            6'd6:field_mask=32'h0003ffff;
            6'd7:field_mask=32'h0003ffff;
            6'd8:field_mask=32'h0003ffff;
            6'd9:field_mask=32'h0003ffff;
            6'd10:field_mask=32'h0003ffff;
            6'd11:field_mask=32'h0003ffff;
            6'd12:field_mask=32'h0003ffff;
            6'd13:field_mask=32'h0003ffff;
            6'd14:field_mask=32'h0003ffff;
            6'd15:field_mask=32'h0003ffff;
            6'd16:field_mask=32'h0003ffff;
            6'd17:field_mask=32'h0003ffff;
            6'd18:field_mask=32'h0003ffff;
            6'd19:field_mask=32'h0003ffff;
            6'd20:field_mask=32'h0003ffff;
            6'd21:field_mask=32'h0003ffff;
            6'd22:field_mask=32'h0003ffff;
            6'd23:field_mask=32'h000fffff;
            6'd24:field_mask=32'h000fffff;
            6'd25:field_mask=32'h000fffff;
            6'd26:field_mask=32'h000fffff;
            6'd27:field_mask=32'h000fffff;
            6'd28:field_mask=32'h000fffff;
            6'd29:field_mask=32'h000fffff;
            6'd30:field_mask=32'h0000ffff;
            6'd31:field_mask=32'h00ffffff;
            6'd32:field_mask=32'h00ffffff;
            6'd33:field_mask=32'h00ffffff;
            6'd34:field_mask=32'h00000fff;
            6'd35:field_mask=32'h00000fff;
            6'd36:field_mask=32'h00000fff;
            6'd37:field_mask=32'h00000fff;
            6'd38:field_mask=32'h00000fff;
            6'd39:field_mask=32'h00000fff;
            6'd40:field_mask=32'h00000fff;
            6'd41:field_mask=32'h00000fff;
            6'd42:field_mask=32'h0000ffff;
            6'd43:field_mask=32'h0000ffff;
            6'd44:field_mask=32'h0000ffff;
            6'd45:field_mask=32'h0000ffff;
            6'd46:field_mask=32'h00000001;
            6'd47:field_mask=32'h00000001;
            6'd48:field_mask=32'h00000001;
            6'd49:field_mask=32'h00000007;
            6'd50:field_mask=32'h00000003;
            default:field_mask=0;
        endcase
    endfunction
    function automatic logic [5:0] parameter_word(input integer index);
        case(index)
            0:parameter_word=6'd6;
            1:parameter_word=6'd9;
            2:parameter_word=6'd10;
            3:parameter_word=6'd11;
            4:parameter_word=6'd12;
            5:parameter_word=6'd13;
            6:parameter_word=6'd14;
            7:parameter_word=6'd15;
            8:parameter_word=6'd16;
            9:parameter_word=6'd17;
            10:parameter_word=6'd18;
            11:parameter_word=6'd19;
            12:parameter_word=6'd20;
            13:parameter_word=6'd21;
            14:parameter_word=6'd22;
            15:parameter_word=6'd24;
            16:parameter_word=6'd25;
            17:parameter_word=6'd26;
            18:parameter_word=6'd27;
            19:parameter_word=6'd28;
            20:parameter_word=6'd29;
            21:parameter_word=6'd48;
            default:parameter_word=0;
        endcase
    endfunction
    function automatic logic [31:0] preserved_mask(input integer index);
        preserved_mask=(index>=6 && index<=10) ? 32'h00020000 : 0;
    endfunction
    xp3_voice_state storage(.clk(clk),.rst(rst),.ready(ram_ready),.read_enable(ram_read),.read_address(ram_raddr),.read_data(ram_rdata),.write_enable(ram_we),.write_address(ram_waddr),.write_data(ram_wdata));
    always_comb begin
        ready=ram_ready && !param_fault;
        param_req_valid=state==PARAM_WAIT && !param_fault && !rst;
        param_ready=param_req_valid;
        param_req_frame=done_frame;
        param_req_voice=active_voice;
        param_req_stage=hook_stage;
        case(hook_stage)
            3'd1:allowed_mask=22'h015801;
            3'd2:allowed_mask=22'h001000;
            3'd3:allowed_mask=22'h010001;
            3'd4:allowed_mask=22'h3ffc3f;
            default:allowed_mask=0;
        endcase
        case(param_reason)
            0:hold_word=14;1:hold_word=16;2:hold_word=15;3:hold_word=17;default:hold_word=18;
        endcase
        terminal_control=(param_reason==4 && param_mask[10]) ? param_values[320+:32] : work[lane][hold_word];
        parameter_bad=param_frame!=done_frame || param_voice!=active_voice || param_stage!=hook_stage || (param_mask&~allowed_mask)!=0 ||
            (param_terminal && (hook_stage!=4 || param_reason>4));
        for(integer i=0;i<22;i=i+1) if(param_mask[i] && ((param_values[i*32+:32]&~field_mask(parameter_word(i)))!=0 ||
            (param_values[i*32+:32]&preserved_mask(i))!=0)) parameter_bad=1;

        cfg_ready=ram_ready && (state==IDLE || (state==CFG_DONE && cfg_rsp_ready)) && !rst && !param_fault;
        cmd_ready=ram_ready && state==IDLE && !rst && !param_fault && !cfg_valid;
        cfg_rsp_valid=state==CFG_DONE && !rst && !param_fault;
        done_valid=state==DONE && !rst && !param_fault;
        // Paired commands have an even owner; lane selects its adjacent partner.
        active_voice={done_voice[5:1],done_voice[0] | lane};
        cs=work[lane][0][6:4];
        phase_input=state==LOAD_LAST ? ram_rdata[32+:3] : work[lane][49][2:0];
        format_input=state==LOAD_LAST ? ram_rdata[64+:2] : work[lane][50][1:0];
        chain_tva=state==FILTER_WAIT && filter_done;
        rom_req_partner=lane;
        for(integer n=0;n<8;n=n+1) fifo[n*12+:12]=work[lane][34+n][11:0];
        gain_sum=({4'b0,work[lane][30][15:0]}<<3)-{4'b0,work[lane][30][15:0]};
        if(work[lane][46][0]) gain_sum=gain_sum+{4'b0,work[lane][26][19:4]}+20'd3;
        ram_read=0;ram_raddr=0;ram_we=0;ram_waddr=0;ram_wdata=0;
        if(cfg_valid && cfg_ready) begin
            ram_raddr={cfg_voice,cfg_word[5:3]};ram_read=!cfg_write;
            ram_waddr=ram_raddr;
            ram_wdata[cfg_word[2:0]*32+:32]=cfg_wdata&field_mask(cfg_word);
            ram_we[cfg_word[2:0]]=cfg_write && cfg_word<51;
        end
        if(state==IDLE && cmd_valid && cmd_ready) begin ram_read=1;ram_raddr={cmd_voice,3'd0};end
        if(state==LOAD) begin ram_read=1;ram_raddr={done_voice,row};end
        if(background_load) begin ram_read=1;ram_raddr={(done_voice+6'd1),background_row};end
        case(store_index) 0:store_row=0;1:store_row=1;2:store_row=2;3:store_row=5;default:store_row=6;endcase
        write_row=background_store ? store_row : row;
        write_lane=background_store ? store_lane : load_lane;
        if(background_store || state==STORE) begin
            ram_waddr={(done_voice+6'(write_lane)),write_row};
            for(integer n=0;n<8;n=n+1) begin
                ram_wdata[n*32+:32]=work[write_lane][write_row*8+n]&field_mask(6'(write_row*8+n));
                ram_we[n]=dirty[write_lane][write_row*8+n];
            end
        end
    end
    xp3_wave_source source(
        .clk(clk),.rst(rst),.in_valid((state==PREPARE || state==LOAD_LAST) && work[lane][46][0]),.in_ready(source_ready),
        .frame(done_frame),.voice_index(active_voice),.runtime_phase(phase_input),.sample_format(format_input),
        .wave_control(work[lane][0][19:0]),.sample_current(work[lane][1][19:0]),.sample_loop(work[lane][2][19:0]),.sample_end(work[lane][3][19:0]),.fetch_state(work[lane][4][19:0]),
        .accumulator(work[lane][5][17:0]),.pitch_increment(work[lane][6][17:0]),.address_fraction(work[lane][7][17:0]),.playback_config(work[lane][8][17:0]),
        .fifo(fifo),.bus16(descriptors[cs*8]),.physical16(physical[cs]),.bank_shift(shifts[cs*4+:4]),
        .irq_status(done_irq_status),.irq_mask(irq_mask),.irq_interrupt(done_irq_interrupt),.irq_accepted(done_irq_accepted),.irq_blocked(done_irq_blocked),
        .rom_req_valid(rom_req_valid),.rom_req_ready(rom_req_ready),.rom_req_cs(rom_req_cs),.rom_req_address(rom_req_address),
        .rom_rsp_valid(rom_rsp_valid),.rom_rsp_ready(rom_rsp_ready),.rom_rsp_data(rom_rsp_data),
        .out_valid(source_done),.out_ready(1'b1),.next_control(source_control),.next_address(source_address),.next_fetch(source_fetch),
        .next_accumulator(source_accumulator),.next_fraction(source_fraction),.next_config(source_config),.next_fifo(source_fifo),
        .next_phase(source_phase),.next_format(source_format),.sample(source_sample),.filter_due(source_due),
        .next_irq_status(source_irq_status),.next_irq_interrupt(source_irq_interrupt),.next_irq_accepted(source_irq_accepted),.next_irq_blocked(source_irq_blocked)
    );
    // Single and paired commands are mutually exclusive through completion.
    xp3_filter_tva filter(
        .clk(clk),.rst(rst),.in_valid(paired ? pair_unit_valid : (state==NEXT_LANE && done_filter_due!=0) || state==TVA_SEND || chain_tva),.in_ready(filter_ready),
        .tva(paired ? pair_unit_tva : state==TVA_SEND || chain_tva),.mode(paired ? pair_unit_mode : work[0][23][11:10]),
        .sample(paired ? pair_unit_sample : chain_tva ? filter_result : state==TVA_SEND ? filtered : {{4{done_sample_owner[19]}},done_sample_owner}),
        .old_bp(paired ? pair_unit_old_bp : work[0][31][23:0]),.old_lp(paired ? pair_unit_old_lp : work[0][32][23:0]),
        .frequency(paired ? pair_unit_frequency : work[0][25][19:0]),.damping(paired ? pair_unit_damping : work[0][24][19:0]),.gain(paired ? pair_unit_gain : work[0][30][15:0]),
        .out_valid(filter_done),.out_ready(!paired || pair_unit_out_ready),.result(filter_result),.next_bp(filter_bp),.next_lp(filter_lp),.high_pass(filter_hp)
    );
    xp3_pair_filter #(.EXTERNAL_UNIT(1)) pair_filter(
        .clk(clk),.rst(rst),.in_valid(state==NEXT_LANE && paired && lane && done_filter_due!=0),.in_ready(pair_ready),.filter_config(work[0][23][19:0]),
        .samples({{4{done_sample_partner[19]}},done_sample_partner,{4{done_sample_owner[19]}},done_sample_owner}),
        .old_bp({work[1][31][23:0],work[0][31][23:0]}),.old_lp({work[1][32][23:0],work[0][32][23:0]}),
        .frequencies({work[1][25][19:0],work[0][25][19:0]}),.dampings({work[1][24][19:0],work[0][24][19:0]}),.gains({work[1][30][15:0],work[0][30][15:0]}),
        .out_valid(pair_done),.out_ready(1'b1),.result(pair_result),.next_bp(pair_bp),.next_lp(pair_lp),
        .shared_valid(pair_unit_valid),.shared_out_ready(pair_unit_out_ready),.shared_tva(pair_unit_tva),.shared_mode(pair_unit_mode),
        .shared_sample(pair_unit_sample),.shared_old_bp(pair_unit_old_bp),.shared_old_lp(pair_unit_old_lp),
        .shared_frequency(pair_unit_frequency),.shared_damping(pair_unit_damping),.shared_gain(pair_unit_gain),
        .shared_ready(filter_ready),.shared_done(filter_done),.shared_result(filter_result),.shared_bp(filter_bp),.shared_lp(filter_lp)
    );
    always_ff @(posedge clk) begin
        if(rst) begin state<=IDLE;read_pending<=0;background_load<=0;partner_loaded<=0;background_store<=0;param_fault<=0;hook_stage<=0;end
        else begin
            read_pending<=ram_read && !(cfg_valid && cfg_ready);
            if(ram_read && state==IDLE && cmd_valid && cmd_ready) begin read_row<=0;read_lane<=0;end
            if(ram_read && state==LOAD) begin read_row<=row;read_lane<=0;end
            if(background_load) begin
                read_row<=background_row;read_lane<=1;
                if(background_row==6) background_load<=0;else background_row<=background_row+1;
            end
            if(read_pending && read_lane && read_row==6) partner_loaded<=1;
            if(background_store) begin
                if(store_index==4) begin
                    store_index<=0;
                    if(paired && !store_lane) store_lane<=1;else background_store<=0;
                end else store_index<=store_index+1;
            end
            if(read_pending) for(integer n=0;n<8;n=n+1) work[read_lane][read_row*8+n]<=ram_rdata[n*32+:32];
            case(state)
                IDLE: if(cfg_valid && cfg_ready) begin
                    config_word<=cfg_word;
                    if(cfg_write) begin cfg_rsp_data<=cfg_wdata&field_mask(cfg_word);state<=CFG_DONE;end
                    else state<=CFG_READ;
                end else if(cmd_valid && cmd_ready) begin
                    done_frame<=cmd_frame;done_voice<=cmd_voice;paired<=cmd_pair;
                    done_irq_status<=cmd_irq_status;done_irq_interrupt<=cmd_irq_interrupt;done_irq_accepted<=cmd_irq_accepted;done_irq_blocked<=cmd_irq_blocked;
                    irq_mask<=cmd_irq_mask;descriptors<=cmd_descriptors;physical<=cmd_physical16;shifts<=cmd_bank_shifts;
                    done_filter_due<=0;done_sample_owner<=0;done_sample_partner<=0;done_prior_partner<=0;done_output_partner<=0;
                    dirty[0]<=0;dirty[1]<=0;row<=1;load_lane<=0;lane<=0;partner_loaded<=0;state<=LOAD;
                end
                CFG_READ:begin cfg_rsp_data<=ram_rdata[config_word[2:0]*32+:32]&field_mask(config_word);state<=CFG_DONE;end
                CFG_DONE:if(cfg_rsp_ready) begin
                    if(cfg_valid && cfg_ready) begin
                        config_word<=cfg_word;
                        if(cfg_write) begin cfg_rsp_data<=cfg_wdata&field_mask(cfg_word);state<=CFG_DONE;end
                        else state<=CFG_READ;
                    end else state<=IDLE;
                end
                LOAD:if(row==6) begin
                    state<=LOAD_LAST;
                end else row<=row+1;
                LOAD_LAST,PREPARE:begin
                    if(state==LOAD_LAST) begin background_load<=paired;background_row<=0;end
                    if(lane) done_prior_partner<=work[1][33][23:0];else done_prior_owner<=work[0][33][23:0];
                    if(!work[lane][46][0]) begin
                        work[lane][30]<=work[lane][30]==0 ? 0 : gain_sum[19:3]==0 ? 1 : {15'b0,gain_sum[19:3]};
                        work[lane][31]<=0;work[lane][32]<=0;work[lane][33]<=0;
                        dirty[lane][33:30]<=4'b1111;state<=NEXT_LANE;
                    end else begin
                        if(phase_input==3 || phase_input==4) begin work[lane][30]<={16'b0,gain_sum[18:3]};dirty[lane][30]<=1;end
                        phase_before<=phase_input;state<=SOURCE_WAIT;
                    end
                end
                SOURCE_WAIT:begin
                    if(source_done) begin
                        work[lane][0]<={12'b0,source_control};work[lane][1]<={12'b0,source_address};work[lane][4]<={12'b0,source_fetch};
                        work[lane][5]<={14'b0,source_accumulator};work[lane][7]<={14'b0,source_fraction};work[lane][8]<={14'b0,source_config};
                        work[lane][49]<={29'b0,source_phase};work[lane][50]<={30'b0,source_format};
                        for(integer n=0;n<8;n=n+1) work[lane][34+n]<={20'b0,source_fifo[n*12+:12]};
                        dirty[lane][0]<=1;dirty[lane][1]<=1;dirty[lane][4]<=1;dirty[lane][5]<=1;dirty[lane][7]<=1;dirty[lane][8]<=1;dirty[lane][50:49]<=3;
                        dirty[lane][41:34]<=8'hff;done_filter_due[lane]<=source_due;
                        if(lane) done_sample_partner<=source_sample;else done_sample_owner<=source_sample;
                        done_irq_status<=source_irq_status;done_irq_interrupt<=source_irq_interrupt;done_irq_accepted<=source_irq_accepted;done_irq_blocked<=source_irq_blocked;
                        case(phase_before)
                            2:begin hook_stage<=1;state<=PARAM_WAIT;end
                            3:begin hook_stage<=2;state<=PARAM_WAIT;end
                            4:begin hook_stage<=source_config[2:0]==6 ? 3 : 4;state<=PARAM_WAIT;end
                            default:state<=NEXT_LANE;
                        endcase
                    end
                end
                PARAM_WAIT:if(param_valid && param_ready) begin
                    if(parameter_bad) param_fault<=1;
                    else begin
                        for(integer i=0;i<22;i=i+1) if(param_mask[i]) begin
                            work[lane][parameter_word(i)]<=(param_values[i*32+:32]&~preserved_mask(i)) | (work[lane][parameter_word(i)]&preserved_mask(i));
                            dirty[lane][parameter_word(i)]<=1;
                        end
                        if(param_terminal && terminal_control[16] && irq_mask[param_reason]) begin
                            if(done_irq_interrupt || done_irq_accepted) done_irq_blocked<=1;
                            else begin
                                done_irq_status<={2'b0,active_voice,5'b0,param_reason};
                                done_irq_interrupt<=1;done_irq_accepted<=1;
                                work[lane][hold_word][17]<=1;dirty[lane][hold_word]<=1;
                            end
                        end
                        state<=PARAM_NEXT;
                    end
                end
                PARAM_NEXT:begin
                    if(hook_stage==3) begin hook_stage<=4;state<=PARAM_WAIT;end
                    else state<=NEXT_LANE;
                end
                NEXT_LANE:if(paired && !lane) begin
                    if(partner_loaded) begin lane<=1;state<=PREPARE;end
                end else begin
                    background_store<=1;store_index<=0;store_lane<=0;row<=3;load_lane<=0;
                    if(done_filter_due!=0) state<=paired ? PAIR_WAIT : FILTER_WAIT;
                    else state<=STORE;
                end
                FILTER_WAIT:if(filter_done) begin
                    filtered<=filter_result;work[0][31]<={8'b0,filter_bp};work[0][32]<={8'b0,filter_lp};dirty[0][32:31]<=3;state<=TVA_WAIT;
                end
                TVA_SEND:if(filter_ready) state<=TVA_WAIT;
                TVA_WAIT:if(filter_done) begin work[0][33]<={8'b0,filter_result};dirty[0][33]<=1;row<=3;load_lane<=0;state<=STORE;end
                PAIR_WAIT:if(pair_done) begin
                    work[0][31]<={8'b0,pair_bp[23:0]};work[1][31]<={8'b0,pair_bp[47:24]};work[0][32]<={8'b0,pair_lp[23:0]};work[1][32]<={8'b0,pair_lp[47:24]};
                    work[0][33]<={8'b0,pair_result};work[1][33]<=0;dirty[0][33:31]<=7;dirty[1][33:31]<=7;
                    row<=3;load_lane<=0;state<=STORE;
                end
                STORE:if(!background_store) begin
                  if(row==4) begin
                    row<=3;
                    if(paired && !load_lane) load_lane<=1;
                    else begin done_output_owner<=work[0][33][23:0];done_output_partner<=paired ? work[1][33][23:0] : 24'd0;state<=DONE;end
                  end else row<=row+1;
                end
                DONE:if(done_ready) state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
