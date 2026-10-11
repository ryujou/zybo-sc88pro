// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_parameter_voice_scheduler # (parameter integer VOICE_LIMIT=64) (
    input logic parameter_desc_valid,
    output logic parameter_desc_ready,
    input logic [63:0] parameter_desc_frame,
    input logic [31:0] parameter_desc_address,
    input logic [14:0] parameter_desc_bytes,
    output logic [31:0] parameter_bursts,parameter_configs,parameter_packets,parameter_noops,
    input logic clk,rst,soft_reset,
    output logic ready,bus_idle,
    input logic frame_valid,
    output logic frame_ready,
    input logic [63:0] frame_id,
    input logic [5:0] frame_highest_voice,
    input logic [15:0] frame_irq_status,frame_irq_mask,
    input logic frame_irq_interrupt,
    input logic [63:0] frame_descriptors,
    input logic [7:0] frame_physical16,
    input logic [31:0] frame_bank_shifts,
    input logic cfg_valid,cfg_write,cfg_rsp_ready,
    output logic cfg_ready,cfg_rsp_valid,
    input logic [5:0] cfg_voice,cfg_word,
    input logic [31:0] cfg_wdata,
    output logic [31:0] cfg_rsp_data,
    output logic done_valid,
    input logic done_ready,
    output logic [63:0] done_frame,
    output logic [12:0] done_cycles,
    output logic [15:0] done_irq_status,
    output logic done_irq_interrupt,done_irq_blocked,
    output logic out_valid,
    input logic out_ready,
    output logic [63:0] out_frame,out_data,
    output logic out_first,out_last,
    input logic consume_tick,
    output logic [7:0] fault,
    output logic [31:0] frames,max_frame_cycles,cache_hits,cache_misses,unmapped_reads,
    output logic [31:0] axi_bursts,axi_errors,timeouts,overruns,output_underruns,
    output logic [1:0] fifo_level,fifo_high_water,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    output logic [31:0] m_axi_araddr,
    output logic [5:0] m_axi_arid,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arlock,
    output logic [3:0] m_axi_arcache,
    output logic [2:0] m_axi_arprot,
    input logic m_axi_rvalid,
    output logic m_axi_rready,
    input logic [63:0] m_axi_rdata,
    input logic [5:0] m_axi_rid,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast
);
    typedef enum logic [3:0] {INIT,IDLE,CONFIG,ISSUE,WAIT_VOICE,DRAIN,REPORT,FAILED} state_t;
    state_t state;
    logic engine_reset,core_ready,core_cmd_ready,core_done_valid,core_done_ready,core_cfg_ready;
    logic [5:0] clear_voice,active_voice,highest,core_done_voice;
    logic paired,active_pair,irq_accepted;
    logic pair_config [0:63];
    logic [15:0] sends_a [0:63],sends_b [0:63],sends_c [0:63],sends_d [0:63];
    wire [19:0] wave_read [0:1],current_read [0:1];
    wire [19:0] pf_wave,pf_current;
    logic [19:0] loop_address [0:63],end_address [0:63];
    wire signed [23:0] prior_read [0:1];
    logic [39:0] core_source_owner,core_source_partner;
    logic [15:0] irq_mask,core_irq_status;
    logic core_irq_interrupt,core_irq_accepted,core_irq_blocked;
    logic [63:0] descriptors,core_done_frame;
    logic [7:0] physical16;
    logic [31:0] bank_shifts;
    logic [12:0] elapsed,admission_wait;
    logic active,frame_take,commit_take,deadline_error;
    logic [1:0] core_filter_due;
    logic signed [23:0] core_prior_owner,core_prior_partner,core_output_owner,core_output_partner;
    logic signed [19:0] core_sample_owner,core_sample_partner;
    logic rom_req_valid,rom_req_ready,rom_req_partner,rom_rsp_valid,rom_rsp_ready;
    logic [2:0] rom_req_cs;
    logic [23:0] rom_req_address;
    logic [7:0] rom_rsp_data;
    logic mixer_ready,mixer_frame_ready,mixer_voice_valid,mixer_voice_ready,mixer_done;
    logic [5:0] mixer_voice;
    logic signed [23:0] mixer_prior;
    logic [6:0] mixer_count;
    logic core_cmd_allowed;
    logic [63:0] mixer_sends;
    logic send_valid,send_ready,mix_valid,mix_ready,mix_seen,mix_last;
    logic [63:0] send_frame;
    logic [5:0] send_voice,send_destination,mix_destination;
    logic [1:0] send_index;
    logic [7:0] send_slot;
    logic signed [24:0] send_contribution;
    logic signed [23:0] mix_sample;
    logic fifo_begin_ready,fifo_record_ready,fifo_commit_ready,fifo_empty;
    logic [63:0] record_data;
    logic cache_ready,cache_fault,fetch_idle,fetch_valid,fetch_ready,line_valid,line_ready;
    logic [31:0] fetch_address;
    logic [7:0] fetch_tag,line_tag;
    logic [255:0] line_data;
    logic [3:0] line_error,bus_fault,previous_bus_fault;
    logic [2:0] outstanding;
    logic pf_valid,pf_ready,pf_scan,pf_needed;
    logic [5:0] pf_voice,pf_cursor;
    logic [1:0] pf_step;
    logic [2:0] pf_cs;
    logic [23:0] pf_address;
    logic [19:0] pf_logical;
    logic [3:0] pf_bank;
    logic mirror_write,mirror_clear;
    logic [5:0] mirror_address;
    logic [31:0] mirror_data;

    logic parameter_ready,parameter_begin_ready,parameter_complete,parameter_cfg_valid,parameter_cfg_ready,parameter_cfg_done;
    logic [7:0] parameter_fault;
    logic parameter_fetch_valid,parameter_fetch_ready,parameter_line_ready;
    logic [31:0] parameter_fetch_address,parameter_cfg_data;
    logic [10:0] parameter_fetch_tag,bus_req_tag,bus_line_tag;
    logic [5:0] parameter_cfg_voice,parameter_cfg_word;
    logic bus_req_valid,bus_req_ready,bus_line_valid,bus_line_ready;
    logic [31:0] bus_req_address;
    logic arbitrate_parameter;
    logic core_cfg_valid,core_cfg_write,core_cfg_rsp_ready,core_cfg_rsp_valid;
    logic [5:0] core_cfg_voice,core_cfg_word;
    logic [31:0] core_cfg_data;
    logic param_req_valid,param_valid,param_accept,core_param_fault;
    logic [63:0] param_req_frame,param_frame;
    logic [5:0] param_req_voice,param_voice;
    logic [2:0] param_req_stage,param_stage,param_reason;
    logic [21:0] param_mask;
    logic [703:0] param_values;
    logic param_terminal;

    assign pf_wave=wave_read[pf_cursor[0]];
    assign pf_current=current_read[pf_cursor[0]];
    assign engine_reset=rst || soft_reset;
    assign bus_idle=fetch_idle;
    assign ready=state!=INIT && state!=FAILED && core_ready && mixer_ready && cache_ready && parameter_ready && !engine_reset;
    assign cfg_ready=state==IDLE && ready && core_cfg_ready;
    assign frame_ready=state==IDLE && ready && core_cfg_ready && !core_cfg_rsp_valid && !cfg_valid && mixer_frame_ready && fifo_begin_ready &&
                       !pf_scan && parameter_begin_ready && frame_highest_voice<VOICE_LIMIT;
    assign frame_take=frame_valid && frame_ready;
    assign paired=!active_voice[0] && active_voice<highest && pair_config[active_voice];
    assign active=state==CONFIG || state==ISSUE || state==WAIT_VOICE || state==DRAIN;
    assign done_valid=state==REPORT && !engine_reset;
    assign core_done_ready=state==WAIT_VOICE;
    assign mixer_voice_valid=(state==ISSUE || state==WAIT_VOICE || state==DRAIN) && mixer_count<={1'b0,highest};
    assign mixer_voice=mixer_count[5:0];
    assign mixer_prior=prior_read[mixer_voice[0]];
    assign core_cmd_allowed=mixer_count>{1'b0,active_voice} &&
                            (!paired || mixer_count>{1'b0,active_voice[5:1],1'b1});
    assign mixer_sends={sends_d[mixer_voice],sends_c[mixer_voice],sends_b[mixer_voice],sends_a[mixer_voice]};
    assign commit_take=state==DRAIN && mixer_done && fifo_commit_ready && bus_fault==0 && !cache_fault && parameter_complete && parameter_fault==0 && !core_param_fault && elapsed<=3125;
    assign deadline_error=(active && elapsed>=3126) || admission_wait>=3126;
    assign send_ready=fifo_record_ready && fault==0;
    assign mix_ready=fifo_record_ready && fault==0;
    assign record_data=send_valid ? {1'b0,1'b0,send_slot,send_voice,send_index,send_destination,15'd0,send_contribution} :
                                   {1'b1,mix_seen,8'd0,6'd0,2'd0,mix_destination,15'd0,mix_sample[23],mix_sample};

    assign core_cfg_valid=state==CONFIG ? parameter_cfg_valid : cfg_valid && state==IDLE && ready;
    assign core_cfg_write=state==CONFIG ? 1'b1 : cfg_write;
    assign core_cfg_voice=state==CONFIG ? parameter_cfg_voice : cfg_voice;
    assign core_cfg_word=state==CONFIG ? parameter_cfg_word : cfg_word;
    assign core_cfg_data=state==CONFIG ? parameter_cfg_data : cfg_wdata;
    assign core_cfg_rsp_ready=state==IDLE ? cfg_rsp_ready : 1'b1;
    assign cfg_rsp_valid=state==IDLE && core_cfg_rsp_valid;
    assign parameter_cfg_ready=state==CONFIG && core_cfg_ready;
    xp3_parameter_voice voice_core (
        .param_valid,.param_ready(param_accept),.param_frame,.param_voice,.param_stage,.param_mask,.param_values,.param_terminal,.param_reason,
        .param_req_valid,.param_req_frame,.param_req_voice,.param_req_stage,.param_fault(core_param_fault),
        .clk,.rst(engine_reset),.ready(core_ready),.cmd_valid(state==ISSUE && core_cmd_allowed),.cmd_ready(core_cmd_ready),
        .cmd_pair(paired),.cmd_frame(done_frame),.cmd_voice(active_voice),.cmd_irq_status(done_irq_status),
        .cmd_irq_mask(irq_mask),.cmd_irq_interrupt(done_irq_interrupt),.cmd_irq_accepted(irq_accepted),.cmd_irq_blocked(done_irq_blocked),
        .cmd_descriptors(descriptors),.cmd_physical16(physical16),.cmd_bank_shifts(bank_shifts),
        .done_valid(core_done_valid),.done_ready(core_done_ready),.done_frame(core_done_frame),.done_voice(core_done_voice),
        .done_irq_status(core_irq_status),.done_irq_interrupt(core_irq_interrupt),.done_irq_accepted(core_irq_accepted),.done_irq_blocked(core_irq_blocked),
        .done_filter_due(core_filter_due),.done_prior_owner(core_prior_owner),.done_prior_partner(core_prior_partner),
        .done_output_owner(core_output_owner),.done_output_partner(core_output_partner),.done_sample_owner(core_sample_owner),.done_sample_partner(core_sample_partner),
        .done_source_owner(core_source_owner),.done_source_partner(core_source_partner),
        .cfg_valid(core_cfg_valid),.cfg_ready(core_cfg_ready),.cfg_write(core_cfg_write),.cfg_voice(core_cfg_voice),.cfg_word(core_cfg_word),.cfg_wdata(core_cfg_data),
        .cfg_rsp_valid(core_cfg_rsp_valid),.cfg_rsp_ready(core_cfg_rsp_ready),.cfg_rsp_data,
        .rom_req_valid,.rom_req_ready,.rom_req_cs,.rom_req_address,.rom_req_partner,.rom_rsp_valid,.rom_rsp_ready,.rom_rsp_data
    );
    pcm_mixer mixer (
        .clk,.rst(engine_reset),.ready(mixer_ready),.frame_valid(frame_take),.frame_ready(mixer_frame_ready),.frame_id,.frame_highest_voice,
        .voice_valid(mixer_voice_valid),.voice_ready(mixer_voice_ready),.voice_index(mixer_voice),.voice_prior(mixer_prior),.voice_sends(mixer_sends),
        .send_valid,.send_ready,.send_frame,.send_voice,.send_index,.send_slot,.send_destination,.send_contribution,
        .mix_valid,.mix_ready,.mix_destination,.mix_sample,.mix_seen,.mix_last,.done_valid(mixer_done),.done_ready(commit_take)
    );
    pcm_frame_fifo results (
        .clk,.rst(engine_reset),.begin_valid(frame_take),.begin_ready(fifo_begin_ready),.begin_frame(frame_id),
        .record_valid((send_valid || mix_valid) && fault==0),.record_ready(fifo_record_ready),.record_data,
        .commit_valid(commit_take),.commit_ready(fifo_commit_ready),.abort_frame(state==FAILED),
        .out_valid,.out_ready,.out_frame,.out_data,.out_first,.out_last,.level(fifo_level),.high_water(fifo_high_water),.empty(fifo_empty)
    );
    pcm_sample_cache cache (
        .clk,.rst,.flush(soft_reset),.fetch_idle,.ready(cache_ready),
        .req_valid(rom_req_valid),.req_ready(rom_req_ready),.req_voice(active_voice+6'(rom_req_partner)),.req_cs(rom_req_cs),.req_address(rom_req_address),
        .rsp_valid(rom_rsp_valid),.rsp_ready(rom_rsp_ready),.rsp_data(rom_rsp_data),
        .prefetch_valid(pf_valid),.prefetch_ready(pf_ready),.prefetch_voice(pf_voice),.prefetch_cs(pf_cs),.prefetch_address(pf_address),
        .fetch_valid,.fetch_ready,.fetch_address,.fetch_tag,.line_valid,.line_ready,.line_tag,.line_data,.line_error,.fault(cache_fault),
        .hits(cache_hits),.misses(cache_misses),.unmapped(unmapped_reads)
    );
    // Both clients share four total bursts. Alternate grants when both request.
    assign bus_req_valid=fetch_valid || parameter_fetch_valid;
    assign bus_req_address=parameter_fetch_valid && (!fetch_valid || arbitrate_parameter) ? parameter_fetch_address : fetch_address;
    assign bus_req_tag=parameter_fetch_valid && (!fetch_valid || arbitrate_parameter) ? parameter_fetch_tag : {3'd0,fetch_tag};
    assign parameter_fetch_ready=bus_req_ready && (!fetch_valid || arbitrate_parameter);
    assign fetch_ready=bus_req_ready && (!parameter_fetch_valid || !arbitrate_parameter);
    assign line_valid=bus_line_valid && !bus_line_tag[10];
    assign line_tag=bus_line_tag[7:0];
    assign bus_line_ready=bus_line_tag[10] ? parameter_line_ready : line_ready;
    always_ff @(posedge clk) begin
        if(engine_reset) arbitrate_parameter<=0;
        else if(bus_req_valid && bus_req_ready) arbitrate_parameter<=!bus_req_tag[10];
    end
    (* keep_hierarchy="yes" *) pcm_parameter_dma parameters (
        .clk,.rst,.flush(soft_reset),.fetch_idle,.ready(parameter_ready),
        .desc_valid(parameter_desc_valid),.desc_ready(parameter_desc_ready),.desc_frame(parameter_desc_frame),
        .desc_address(parameter_desc_address),.desc_bytes(parameter_desc_bytes),
        .fetch_valid(parameter_fetch_valid),.fetch_ready(parameter_fetch_ready),.fetch_address(parameter_fetch_address),.fetch_tag(parameter_fetch_tag),
        .line_valid(bus_line_valid && bus_line_tag[10]),.line_ready(parameter_line_ready),.line_tag(bus_line_tag),.line_data,.line_error,
        .begin_valid(frame_take),.begin_ready(parameter_begin_ready),.begin_frame(frame_id),
        .cfg_valid(parameter_cfg_valid),.cfg_ready(parameter_cfg_ready),.cfg_voice(parameter_cfg_voice),.cfg_word(parameter_cfg_word),.cfg_data(parameter_cfg_data),.cfg_done(parameter_cfg_done),
        .req_valid(param_req_valid),.req_frame(param_req_frame),.req_voice(param_req_voice),.req_stage(param_req_stage),
        .param_valid,.param_ready(param_accept),.param_frame,.param_voice,.param_stage,.param_mask,.param_values,.param_terminal,.param_reason,
        .audio_done(state==DRAIN),.finish_valid(commit_take),.complete(parameter_complete),.fault(parameter_fault),
        .bursts(parameter_bursts),.config_words(parameter_configs),.packets(parameter_packets),.noops(parameter_noops)
    );
    pcm_sample_fetcher #(.TAG_BITS(11)) fetcher (
        .clk,.rst,.flush(soft_reset),.idle(fetch_idle),.req_valid(bus_req_valid),.req_ready(bus_req_ready),.req_address(bus_req_address),.req_tag(bus_req_tag),
        .line_valid(bus_line_valid),.line_ready(bus_line_ready),.line_tag(bus_line_tag),.line_data,.line_error,.fault(bus_fault),.outstanding,
        .m_axi_arvalid,.m_axi_arready,.m_axi_araddr,.m_axi_arid,.m_axi_arlen,.m_axi_arsize,.m_axi_arburst,.m_axi_arlock,.m_axi_arcache,.m_axi_arprot,
        .m_axi_rvalid,.m_axi_rready,.m_axi_rdata,.m_axi_rid,.m_axi_rresp,.m_axi_rlast
    );

    // Prefetch the four-line working set from actual completed state, before this frame's synchronized reads.
    // A source step fetches at most eight byte addresses; distant loop/adjacent lines need not occupy the shared bus.
    assign pf_needed=pf_step==2 ? pf_current[19:5]==end_address[pf_cursor][19:5] :
                     pf_step==3 ? ((pf_wave[11]^pf_wave[13]) ? pf_current[4:0]<8 : pf_current[4:0]>=24) : 1'b1;
    assign pf_valid=ready && fault==0 && pf_scan && pf_needed;
    assign pf_voice=pf_cursor;
    assign pf_cs=pf_wave[6:4];
    assign pf_bank=pf_wave[3:0]>>bank_shifts[pf_cs*4+:4];
    assign mirror_clear=state==INIT;
    assign mirror_write=mirror_clear || (core_cfg_valid && core_cfg_ready && core_cfg_write);
    assign mirror_address=mirror_clear ? clear_voice : core_cfg_voice;
    assign mirror_data=mirror_clear ? 32'd0 : core_cfg_data;
    // One shared write address allows the host mirrors to infer distributed RAM.
    always_ff @(posedge clk) begin
        if(mirror_write) begin
            if(mirror_clear || core_cfg_word==2) loop_address[mirror_address]<=mirror_data[19:0];
            if(mirror_clear || core_cfg_word==3) end_address[mirror_address]<=mirror_data[19:0];
            if(mirror_clear || core_cfg_word==23) pair_config[mirror_address]<=mirror_data[4] && mirror_data[15:12]>=1 && mirror_data[15:12]<=9;
            if(mirror_clear || core_cfg_word==42) sends_a[mirror_address]<=mirror_data[15:0];
            if(mirror_clear || core_cfg_word==43) sends_b[mirror_address]<=mirror_data[15:0];
            if(mirror_clear || core_cfg_word==44) sends_c[mirror_address]<=mirror_data[15:0];
            if(mirror_clear || core_cfg_word==45) sends_d[mirror_address]<=mirror_data[15:0];
        end
    end
    // A command cannot overwrite its output mirror until the mixer has captured that Voice's preceding value.
    for(genvar parity=0;parity<2;parity=parity+1) begin: output_bank
        (* ram_style="distributed" *) logic [19:0] wave_config [0:31],sample_current [0:31];
        (* ram_style="distributed" *) logic signed [23:0] prior_outputs [0:31];
        assign wave_read[parity]=wave_config[pf_cursor[5:1]];
        assign current_read[parity]=sample_current[pf_cursor[5:1]];
        assign prior_read[parity]=prior_outputs[mixer_voice[5:1]];
        logic write_enable;
        logic [4:0] write_address;
        logic signed [23:0] write_data;
        always_comb begin
            write_enable=0;write_address=0;write_data=0;
            if(mirror_clear && clear_voice[0]==parity) begin
                write_enable=1;write_address=clear_voice[5:1];
            end else if(core_cfg_valid && core_cfg_ready && core_cfg_write && core_cfg_word==33 && core_cfg_voice[0]==parity) begin
                write_enable=1;write_address=core_cfg_voice[5:1];write_data=core_cfg_data[23:0];
            end else if(core_done_valid && core_done_ready) begin
                if(core_done_voice[0]==parity) begin
                    write_enable=1;write_address=core_done_voice[5:1];write_data=core_output_owner;
                end else if(active_pair) begin
                    write_enable=1;write_address=core_done_voice[5:1];write_data=core_output_partner;
                end
            end
        end
        always_ff @(posedge clk) if(write_enable) prior_outputs[write_address]<=write_data;
        logic wave_write,current_write;
        logic [4:0] source_address;
        logic [39:0] source_data;
        always_comb begin
            source_address=core_done_voice[5:1];
            source_data=core_done_voice[0]==parity ? core_source_owner : core_source_partner;
            wave_write=core_done_valid && core_done_ready && (core_done_voice[0]==parity || active_pair);
            current_write=wave_write;
            if(mirror_clear) begin
                source_address=clear_voice[5:1];source_data=0;
                wave_write=clear_voice[0]==parity;current_write=wave_write;
            end else if(core_cfg_valid && core_cfg_ready && core_cfg_write) begin
                source_address=core_cfg_voice[5:1];source_data={core_cfg_data[19:0],core_cfg_data[19:0]};
                wave_write=core_cfg_voice[0]==parity && core_cfg_word==0;
                current_write=core_cfg_voice[0]==parity && core_cfg_word==1;
            end
        end
        always_ff @(posedge clk) begin
            if(wave_write) wave_config[source_address]<=source_data[39:20];
            if(current_write) sample_current[source_address]<=source_data[19:0];
        end
    end
    always_comb begin
        case(pf_step)
            0:pf_logical=pf_current;
            1:pf_logical={5'd0,pf_current[19:6],1'b0};
            2:pf_logical=loop_address[pf_cursor];
            default:pf_logical=(pf_wave[11]^pf_wave[13]) ? pf_current-20'd32 : pf_current+20'd32;
        endcase
        pf_address={pf_bank,pf_logical};
    end

    always_ff @(posedge clk) begin
        if(engine_reset) begin
            state<=INIT;clear_voice<=0;active_voice<=0;highest<=0;active_pair<=0;
            done_frame<=0;done_cycles<=0;done_irq_status<=0;done_irq_interrupt<=0;done_irq_blocked<=0;irq_accepted<=0;irq_mask<=0;
            descriptors<=0;physical16<=0;bank_shifts<=0;elapsed<=0;admission_wait<=0;
            mixer_count<=0;
            pf_scan<=0;pf_cursor<=0;pf_step<=0;
            frames<=0;max_frame_cycles<=0;axi_bursts<=0;axi_errors<=0;timeouts<=0;overruns<=0;output_underruns<=0;
            fault<=0;previous_bus_fault<=0;
        end else begin
            if(frame_valid && !frame_ready) begin if(admission_wait<8191) admission_wait<=admission_wait+1'b1;end
            else admission_wait<=0;
            if(active && elapsed<8191) elapsed<=elapsed+1'b1;
            if(state!=INIT && m_axi_arvalid && m_axi_arready && axi_bursts!=32'hffffffff) axi_bursts<=axi_bursts+1'b1;
            previous_bus_fault<=bus_fault;
            if(state!=INIT && bus_fault[2:0]!=0 && previous_bus_fault[2:0]==0 && axi_errors!=32'hffffffff) axi_errors<=axi_errors+1'b1;
            if(state!=INIT && bus_fault[3] && !previous_bus_fault[3] && timeouts!=32'hffffffff) timeouts<=timeouts+1'b1;
            if(consume_tick && fifo_empty && ready && output_underruns!=32'hffffffff) output_underruns<=output_underruns+1'b1;
            if(mixer_voice_valid && mixer_voice_ready) mixer_count<=mixer_count+1'b1;
            if(pf_scan && ready && fault==0 && (!pf_needed || pf_ready)) begin
                if(pf_step!=3) pf_step<=pf_step+1'b1;
                else if(pf_cursor==highest) pf_scan<=0;
                else begin pf_cursor<=pf_cursor+1'b1;pf_step<=0;end
            end
            case(state)
                INIT:begin
                    if(clear_voice==63) begin
                        if(core_ready && mixer_ready && cache_ready && bus_fault==0) state<=IDLE;
                    end else clear_voice<=clear_voice+1'b1;
                end
                IDLE:if(frame_take) begin
                    done_frame<=frame_id;highest<=frame_highest_voice;active_voice<=0;elapsed<=admission_wait+1'b1;
                    done_irq_status<=frame_irq_status;done_irq_interrupt<=frame_irq_interrupt;done_irq_blocked<=0;irq_accepted<=0;
                    irq_mask<=frame_irq_mask;descriptors<=frame_descriptors;physical16<=frame_physical16;bank_shifts<=frame_bank_shifts;
                    pf_scan<=0;pf_cursor<=0;pf_step<=0;mixer_count<=0;state<=CONFIG;
                end
                CONFIG:if(parameter_cfg_done) begin pf_scan<=1;pf_cursor<=0;pf_step<=0;state<=ISSUE;end
                ISSUE:if(core_cmd_ready && core_cmd_allowed) begin active_pair<=paired;state<=WAIT_VOICE;end
                WAIT_VOICE:if(core_done_valid && core_done_ready) begin
                    done_irq_status<=core_irq_status;done_irq_interrupt<=core_irq_interrupt;done_irq_blocked<=core_irq_blocked;irq_accepted<=core_irq_accepted;
                    if(active_voice+7'(active_pair)>=highest) state<=DRAIN;
                    else begin active_voice<=active_voice+(active_pair ? 6'd2 : 6'd1);state<=ISSUE;end
                end
                DRAIN:if(commit_take) begin
                    done_cycles<=elapsed;state<=REPORT;pf_scan<=0;
                    if(frames!=32'hffffffff) frames<=frames+1'b1;
                    if(elapsed>max_frame_cycles) max_frame_cycles<={19'd0,elapsed};
                end
                REPORT:if(done_ready) state<=IDLE;
                default:begin end
            endcase
            if((bus_fault!=0 || cache_fault || parameter_fault!=0 || core_param_fault || deadline_error) && state!=INIT) begin
                state<=FAILED;fault<=fault|{4'd0,(parameter_fault!=0 || core_param_fault),(bus_fault!=0),cache_fault,deadline_error};
                if(deadline_error && !fault[0] && overruns!=32'hffffffff) overruns<=overruns+1'b1;
            end
        end
    end
endmodule
