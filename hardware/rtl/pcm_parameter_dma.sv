// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_parameter_dma (
    input logic clk,rst,flush,fetch_idle,
    output logic ready,
    input logic desc_valid,
    output logic desc_ready,
    input logic [63:0] desc_frame,
    input logic [31:0] desc_address,
    input logic [14:0] desc_bytes,
    output logic fetch_valid,
    input logic fetch_ready,
    output logic [31:0] fetch_address,
    output logic [10:0] fetch_tag,
    input logic line_valid,
    output logic line_ready,
    input logic [10:0] line_tag,
    input logic [255:0] line_data,
    input logic [3:0] line_error,
    input logic begin_valid,
    output logic begin_ready,
    input logic [63:0] begin_frame,
    output logic cfg_valid,
    input logic cfg_ready,
    output logic [5:0] cfg_voice,cfg_word,
    output logic [31:0] cfg_data,
    output logic cfg_done,
    input logic req_valid,
    input logic [63:0] req_frame,
    input logic [5:0] req_voice,
    input logic [2:0] req_stage,
    output logic param_valid,
    input logic param_ready,
    output logic [63:0] param_frame,
    output logic [5:0] param_voice,
    output logic [2:0] param_stage,
    output logic [21:0] param_mask,
    output logic [703:0] param_values,
    output logic param_terminal,
    output logic [2:0] param_reason,
    input logic audio_done,finish_valid,
    output logic complete,
    output logic [7:0] fault,
    output logic [31:0] bursts,config_words,packets,noops
);
    typedef enum logic [2:0] {P_IDLE,P_CFG,P_HEADER,P_VALUES,P_PAD,P_DONE} parse_t;
    parse_t parse_state;
    logic resetting,write_slot,read_slot,fill_slot,fill_busy,bound;
    logic [1:0] occupied,filled;
    logic [63:0] frame_number [0:1],last_descriptor,bound_frame;
    logic have_descriptor;
    logic [31:0] fill_base;
    logic [9:0] fill_lines,issued_lines,received_lines;
    logic [11:0] words_total [0:1],payload_words [0:1];
    logic [15:0] configs_count [0:1],packets_count [0:1];
    logic [11:0] read_cursor,read_end,consumed;
    logic [15:0] configs_left,packets_left;
    logic read_enable,word_valid,word_take;
    logic [1:0] word_bank;
    wire [63:0] word_data;
    wire [63:0] bank_data [0:3];
    logic [21:0] value_remaining,remaining_first,remaining_after,first_select,second_select,decode_mask;
    logic [5:0] decode_voice;
    logic [2:0] decode_stage,decode_reason;
    logic decode_terminal;
    logic q_head,q_tail;
    logic [1:0] q_count;
    logic [5:0] q_voice [0:1];
    logic [2:0] q_stage [0:1],q_reason [0:1];
    logic [21:0] q_mask [0:1];
    logic [703:0] q_values [0:1];
    logic q_terminal [0:1];
    logic store_packet,push_packet,pop_packet,matched,later,stale,cfg_bad,header_bad,values_bad;
    logic [21:0] header_mask;
    logic [2:0] header_stage,header_reason;
    logic header_terminal;
    logic [5:0] header_voice;
    logic [31:0] cfg_mask;
    logic cfg_buffer_valid;
    logic [5:0] cfg_buffer_voice,cfg_buffer_word;
    logic [31:0] cfg_buffer_data;
    logic have_packet;
    logic [8:0] previous_packet;

    function automatic logic [21:0] stage_mask(input logic [2:0] stage);
        case(stage)
            1:stage_mask=(22'd1<<0)|(22'd1<<11)|(22'd1<<12)|(22'd1<<14)|(22'd1<<16);
            2:stage_mask=22'd1<<12;
            3:stage_mask=(22'd1<<0)|(22'd1<<16);
            4:stage_mask=22'h3fffff & ~((22'd1<<6)|(22'd1<<7)|(22'd1<<8)|(22'd1<<9));
            default:stage_mask=0;
        endcase
    endfunction
    function automatic logic value_bad(input logic [21:0] selected,input logic [31:0] value);
        value_bad=(selected[21] && |value[31:1]) ||
                  (|selected[20:15] && |value[31:20]) ||
                  (|selected[14:0] && |value[31:18]) ||
                  (|selected[10:6] && value[17]);
    endfunction
    function automatic logic [31:0] field_mask(input logic [5:0] index);
        case(index)
            0,1,2,3,4,24,25,26,27,28,29:field_mask=32'h000fffff;
            5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22:field_mask=32'h0003ffff;
            23:field_mask=32'h000fffff;
            31,32,33:field_mask=32'h00ffffff;
            30,42,43,44,45:field_mask=32'h0000ffff;
            34,35,36,37,38,39,40,41:field_mask=32'h00000fff;
            46,47,48:field_mask=32'h00000001;
            49:field_mask=32'h00000007;
            50:field_mask=32'h00000003;
            default:field_mask=0;
        endcase
    endfunction

    assign ready=!resetting && !rst && !flush && fault==0;
    assign desc_ready=ready && !fill_busy && !occupied[write_slot];
    assign fetch_valid=ready && fill_busy && issued_lines<fill_lines;
    assign fetch_address=fill_base+{17'd0,issued_lines,5'd0};
    assign fetch_tag={1'b1,fill_slot,issued_lines[8:0]};
    assign line_ready=!rst && !flush;
    assign begin_ready=ready && !bound && filled[read_slot] && frame_number[read_slot]==begin_frame;
    assign word_data=bank_data[word_bank];
    assign read_enable=bound && read_cursor<read_end && (!word_valid || word_take) && parse_state!=P_DONE && fault==0;
    for(genvar bank=0;bank<4;bank=bank+1) begin: raw_bank
        (* ram_style="block" *) logic [63:0] words [0:1023];
        logic [63:0] read_data;
        assign bank_data[bank]=read_data;
        always_ff @(posedge clk) begin
            if(line_valid && line_ready && line_error==0 && line_tag[10]) words[{line_tag[9],line_tag[8:0]}]<=line_data[bank*64+:64];
            if(read_enable) read_data<=words[{read_slot,read_cursor[10:2]}];
        end
    end
    assign cfg_voice=cfg_buffer_voice;
    assign cfg_word=cfg_buffer_word;
    assign cfg_data=cfg_buffer_data;
    assign cfg_mask=field_mask(word_data[53:48]);
    assign cfg_bad=word_data[63:60]!=1 || word_data[47:32]!=0 || word_data[53:48]>50 || (word_data[31:0] & ~cfg_mask)!=0;
    assign cfg_valid=ready && bound && cfg_buffer_valid;
    assign cfg_done=bound && configs_left==0 && parse_state!=P_CFG && !cfg_buffer_valid;
    assign header_voice=word_data[59:54];
    assign header_stage=word_data[53:51];
    assign header_terminal=word_data[50];
    assign header_reason=word_data[49:47];
    assign header_mask=word_data[46:25];
    assign header_bad=word_data[63:60]!=2 || word_data[24:0]!=0 || header_stage<1 || header_stage>4 ||
                      (header_mask & ~stage_mask(header_stage))!=0 ||
                      (header_terminal && (header_stage!=4 || header_reason>4)) || (!header_terminal && header_reason!=0) ||
                      (header_mask==0 && !header_terminal);
    always_comb begin
        remaining_first=value_remaining & (value_remaining-22'd1);
        first_select=value_remaining ^ remaining_first;
        remaining_after=remaining_first & (remaining_first-22'd1);
        second_select=remaining_first ^ remaining_after;
        values_bad=value_bad(first_select,word_data[31:0]) ||
                   (remaining_first!=0 ? value_bad(second_select,word_data[63:32]) : word_data[63:32]!=0);
        word_take=0;
        case(parse_state)
            // A bad word latches fault on this edge, suppressing cfg_valid before publication.
            // Keep RAM validation off the parser progress/read-enable path.
            P_CFG:word_take=word_valid && (!cfg_buffer_valid || cfg_ready);
            P_HEADER:word_take=word_valid && q_count<2;
            P_VALUES:word_take=word_valid && q_count<2;
            P_PAD:word_take=word_valid;
            default:begin end
        endcase
        store_packet=word_valid && q_count<2 && ((parse_state==P_HEADER && header_mask==0) ||
                                               (parse_state==P_VALUES && remaining_after==0));
        push_packet=store_packet && (parse_state==P_HEADER ? !header_bad : !values_bad);
    end
    assign matched=q_count!=0 && {q_voice[q_head],q_stage[q_head]}=={req_voice,req_stage};
    assign later=q_count!=0 && {q_voice[q_head],q_stage[q_head]}>{req_voice,req_stage};
    assign stale=q_count!=0 && {q_voice[q_head],q_stage[q_head]}<{req_voice,req_stage};
    assign param_valid=ready && bound && req_valid && req_frame==bound_frame && (matched || later || (q_count==0 && parse_state==P_DONE));
    assign param_frame=req_frame;
    assign param_voice=req_voice;
    assign param_stage=req_stage;
    assign param_mask=matched ? q_mask[q_head] : 22'd0;
    // The mask controls consumption of values, including a no-change hook.
    assign param_values=q_values[q_head];
    assign param_terminal=matched && q_terminal[q_head];
    assign param_reason=matched ? q_reason[q_head] : 3'd0;
    assign pop_packet=param_valid && param_ready && matched;
    assign complete=bound && parse_state==P_DONE && q_count==0 && !cfg_buffer_valid && fault==0;

    always_ff @(posedge clk) begin
        if(rst || flush) begin
            resetting<=1;write_slot<=0;read_slot<=0;fill_slot<=0;fill_busy<=0;bound<=0;
            occupied<=0;filled<=0;fill_base<=0;fill_lines<=0;issued_lines<=0;received_lines<=0;
            have_descriptor<=0;last_descriptor<=0;bound_frame<=0;
            parse_state<=P_IDLE;read_cursor<=0;read_end<=0;consumed<=0;word_valid<=0;word_bank<=0;
            configs_left<=0;packets_left<=0;value_remaining<=0;decode_mask<=0;
            decode_voice<=0;decode_stage<=0;decode_terminal<=0;decode_reason<=0;
            q_head<=0;q_tail<=0;q_count<=0;fault<=0;bursts<=0;config_words<=0;packets<=0;noops<=0;
            have_packet<=0;previous_packet<=0;
            cfg_buffer_valid<=0;cfg_buffer_voice<=0;cfg_buffer_word<=0;cfg_buffer_data<=0;
            for(integer i=0;i<2;i=i+1) begin
                frame_number[i]<=0;words_total[i]<=0;payload_words[i]<=0;configs_count[i]<=0;packets_count[i]<=0;
                q_voice[i]<=0;q_stage[i]<=0;q_mask[i]<=0;q_values[i]<=0;q_terminal[i]<=0;q_reason[i]<=0;
            end
        end else begin
            if(resetting && fetch_idle) resetting<=0;
            if(cfg_valid && cfg_ready) cfg_buffer_valid<=0;
            if(desc_valid && desc_ready) begin
                if(desc_address[4:0]!=0 || desc_address<32'h12000000 || desc_address+{17'd0,desc_bytes}>32'h12080000 ||
                   desc_bytes<32 || desc_bytes>16384 || desc_bytes[4:0]!=0 || (have_descriptor && desc_frame!=last_descriptor+1'b1)) fault[1]<=1;
                else begin
                    occupied[write_slot]<=1;frame_number[write_slot]<=desc_frame;words_total[write_slot]<=desc_bytes[14:3];
                    fill_slot<=write_slot;fill_base<=desc_address;fill_lines<=desc_bytes[14:5];issued_lines<=0;received_lines<=0;fill_busy<=1;
                    write_slot<=!write_slot;last_descriptor<=desc_frame;have_descriptor<=1;
                end
            end
            if(fetch_valid && fetch_ready) begin issued_lines<=issued_lines+1'b1;bursts<=bursts+1'b1;end
            if(line_valid && line_ready) begin
                if(line_error!=0) fault[6]<=1;
                if(!line_tag[10] || !fill_busy || line_tag[9]!=fill_slot || {1'b0,line_tag[8:0]}!=received_lines) fault[1]<=1;
                else begin
                    received_lines<=received_lines+1'b1;
                    if(line_tag[8:0]==0) begin
                        if(line_data[63:0]!=64'h31414d4438384353 || line_data[127:64]!=frame_number[fill_slot] ||
                           line_data[159:128]!={17'd0,words_total[fill_slot],3'd0} || line_data[255:224]!=0 ||
                           line_data[191:160]>2044 || line_data[191:160]+4>words_total[fill_slot] ||
                           ((line_data[191:160]+7)&32'hfffffffc)!=words_total[fill_slot] ||
                           line_data[207:192]+line_data[223:208]>line_data[191:160]) fault[0]<=1;
                        payload_words[fill_slot]<=line_data[171:160];configs_count[fill_slot]<=line_data[207:192];packets_count[fill_slot]<=line_data[223:208];
                    end
                    if(received_lines+1'b1==fill_lines) begin filled[fill_slot]<=1;fill_busy<=0;end
                end
            end
            if(begin_valid && begin_ready) begin
                bound<=1;bound_frame<=begin_frame;filled[read_slot]<=0;read_cursor<=4;read_end<=words_total[read_slot];consumed<=4;
                configs_left<=configs_count[read_slot];packets_left<=packets_count[read_slot];word_valid<=0;
                parse_state<=configs_count[read_slot]!=0 ? P_CFG : packets_count[read_slot]!=0 ? P_HEADER : P_PAD;
                have_packet<=0;previous_packet<=0;
            end
            if(read_enable) begin word_valid<=1;word_bank<=read_cursor[1:0];read_cursor<=read_cursor+1'b1;end
            else if(word_take) word_valid<=0;
            if(word_valid && parse_state==P_CFG && cfg_bad) fault[2]<=1;
            if(word_take) begin
                consumed<=consumed+1'b1;
                if(parse_state!=P_PAD && consumed>=payload_words[read_slot]+4) fault[5]<=1;
                case(parse_state)
                    P_CFG:begin
                        cfg_buffer_valid<=1;cfg_buffer_voice<=word_data[59:54];
                        cfg_buffer_word<=word_data[53:48];cfg_buffer_data<=word_data[31:0];
                        config_words<=config_words+1'b1;configs_left<=configs_left-1'b1;
                        if(configs_left==1) parse_state<=packets_left!=0 ? P_HEADER : P_PAD;
                    end
                    P_HEADER:begin
                        if(header_bad) fault[3]<=1;
                        if(have_packet && {header_voice,header_stage}<=previous_packet) fault[4]<=1;
                        have_packet<=1;previous_packet<={header_voice,header_stage};
                        decode_voice<=header_voice;decode_stage<=header_stage;decode_mask<=header_mask;
                        decode_terminal<=header_terminal;decode_reason<=header_reason;q_values[q_tail]<=0;value_remaining<=header_mask;
                        if(header_mask!=0) parse_state<=P_VALUES;
                        else begin packets_left<=packets_left-1'b1;if(packets_left==1) parse_state<=P_PAD;end
                    end
                    P_VALUES:begin
                        if(values_bad) fault[3]<=1;
                        for(integer i=0;i<22;i=i+1) begin
                            if(first_select[i]) begin
                                if(i==21) q_values[q_tail][i*32+:32]<={31'd0,word_data[0]};
                                else if(i>=15) q_values[q_tail][i*32+:32]<={12'd0,word_data[19:0]};
                                else q_values[q_tail][i*32+:32]<={14'd0,word_data[17:0]};
                                if(i>=6 && i<=10) q_values[q_tail][i*32+17]<=0;
                            end
                            if(second_select[i]) begin
                                if(i==21) q_values[q_tail][i*32+:32]<={31'd0,word_data[32]};
                                else if(i>=15) q_values[q_tail][i*32+:32]<={12'd0,word_data[51:32]};
                                else q_values[q_tail][i*32+:32]<={14'd0,word_data[49:32]};
                                if(i>=6 && i<=10) q_values[q_tail][i*32+17]<=0;
                            end
                        end
                        value_remaining<=remaining_after;
                        if(remaining_after==0) begin
                            packets_left<=packets_left-1'b1;parse_state<=packets_left==1 ? P_PAD : P_HEADER;
                        end
                    end
                    P_PAD:begin
                        if(consumed<payload_words[read_slot]+4 || word_data!=0) fault[5]<=1;
                    end
                    default:begin end
                endcase
            end
            if(bound && consumed==read_end && !word_valid && parse_state==P_PAD) parse_state<=P_DONE;
            if(bound && consumed>=payload_words[read_slot]+4 && !word_valid && (parse_state==P_CFG || parse_state==P_HEADER || parse_state==P_VALUES)) fault[5]<=1;
            q_count<=q_count+2'(push_packet)-2'(pop_packet);
            // A free slot may be written before validation, but only a valid packet becomes visible in the queue.
            if(store_packet) begin
                q_voice[q_tail]<=parse_state==P_HEADER ? header_voice : decode_voice;
                q_stage[q_tail]<=parse_state==P_HEADER ? header_stage : decode_stage;
                q_mask[q_tail]<=parse_state==P_HEADER ? header_mask : decode_mask;
                q_terminal[q_tail]<=parse_state==P_HEADER ? header_terminal : decode_terminal;
                q_reason[q_tail]<=parse_state==P_HEADER ? header_reason : decode_reason;
            end
            if(push_packet) q_tail<=!q_tail;
            if(pop_packet) begin q_head<=!q_head;packets<=packets+1'b1;end
            if(param_valid && param_ready && !matched) noops<=noops+1'b1;
            if(bound && req_valid && (req_frame!=bound_frame || stale)) fault[4]<=1;
            if(audio_done && parse_state==P_DONE && q_count!=0) fault[7]<=1;
            if(finish_valid && complete) begin
                bound<=0;occupied[read_slot]<=0;read_slot<=!read_slot;parse_state<=P_IDLE;word_valid<=0;
            end
        end
    end
endmodule
