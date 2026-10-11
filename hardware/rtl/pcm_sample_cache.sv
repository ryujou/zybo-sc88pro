// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module pcm_sample_cache (
    input logic clk,rst,flush,fetch_idle,
    output logic ready,
    input logic req_valid,
    output logic req_ready,
    input logic [5:0] req_voice,
    input logic [2:0] req_cs,
    input logic [23:0] req_address,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [7:0] rsp_data,
    input logic prefetch_valid,
    output logic prefetch_ready,
    input logic [5:0] prefetch_voice,
    input logic [2:0] prefetch_cs,
    input logic [23:0] prefetch_address,
    output logic fetch_valid,
    input logic fetch_ready,
    output logic [31:0] fetch_address,
    output logic [7:0] fetch_tag,
    input logic line_valid,
    output logic line_ready,
    input logic [7:0] line_tag,
    input logic [255:0] line_data,
    input logic [3:0] line_error,
    output logic fault,
    output logic [31:0] hits,misses,unmapped
);
    (* ram_style="block" *) logic [63:0] memory [0:1023];
    logic [19:0] tags [0:3][0:63];
    logic [255:0] valid,pending;
    logic [1:0] replacement [0:63];
    logic waiting,flushing,fill_busy,rsp_zero,rsp_hot,lookup_new,demand_inflight;
    logic [1:0] fill_word;
    logic [5:0] saved_voice,lookup_voice;
    logic [2:0] saved_cs,lookup_cs,rsp_lane;
    logic [23:0] saved_address,lookup_address;
    logic [63:0] read_word;
    logic [63:0] hot_old_word;
    logic [21:0] hot_tag,hot_old_tag;
    logic hot_valid,hot_old_valid,hot_hit,hot_old_hit,request_mapped;
    logic [7:0] hot_byte,hot_old_byte;
    logic hot_select;
    logic pf_queued,process_pf;
    logic [5:0] pf_saved_voice;
    logic [2:0] pf_saved_cs;
    logic [23:0] pf_saved_address;
    logic lookup_mapped,lookup_hit,lookup_pending,lookup_space;
    logic pf_mapped,pf_hit,pf_pending,pf_space;
    logic [7:0] lookup_line,lookup_victim,pf_victim;
    logic [19:0] lookup_tag,pf_tag;
    logic issue_space,accept_req,accept_pf,allocate_req,allocate_pf,read_enable;
    logic [9:0] read_address;
    logic [7:0] allocated_line;
    logic [5:0] allocated_voice;
    logic [19:0] allocated_tag;
    logic [3:0] lookup_pending_ways,pf_pending_ways;
    logic count_hit;
    // An in-flight demand owns a non-evictable line, so only prefetch can allocate until its read completes.
    wire select_demand=waiting && !demand_inflight;
    assign lookup_pending_ways=pending[{lookup_voice,2'b00}+:4];
    assign pf_pending_ways=pending[{pf_saved_voice,2'b00}+:4];

    assign ready=!rst && !flush && !flushing && !fault;
    assign lookup_voice=saved_voice;
    assign lookup_cs=saved_cs;
    assign lookup_address=saved_address;
    assign lookup_tag={lookup_cs,lookup_address[21:5]};
    assign pf_tag={pf_saved_cs,pf_saved_address[21:5]};
    assign lookup_mapped=lookup_cs<5 && lookup_address[23:22]==0;
    assign pf_mapped=pf_saved_cs<5 && pf_saved_address[23:22]==0;
    assign request_mapped=req_cs<5 && req_address[23:22]==0;
    assign hot_hit=hot_valid && hot_tag=={req_cs,req_address[21:3]};
    assign hot_old_hit=hot_old_valid && hot_old_tag=={req_cs,req_address[21:3]};
    assign issue_space=!fetch_valid || fetch_ready;
    assign req_ready=ready && !waiting && (!rsp_valid || rsp_ready);
    assign process_pf=ready && pf_queued && (!waiting || demand_inflight) &&
                      (!pf_mapped || pf_hit || pf_pending || (pf_space && issue_space));
    assign prefetch_ready=ready && (!pf_queued || process_pf);
    assign accept_req=req_valid && req_ready;
    assign accept_pf=prefetch_valid && prefetch_ready;
    assign allocate_req=ready && waiting && !lookup_hit && !lookup_pending && lookup_space && issue_space;
    assign allocate_pf=process_pf && pf_mapped && !pf_hit && !pf_pending;
    assign allocated_line=select_demand ? lookup_victim : pf_victim;
    assign allocated_voice=select_demand ? lookup_voice : pf_saved_voice;
    assign allocated_tag=select_demand ? lookup_tag : pf_tag;
    assign read_enable=ready && lookup_hit && waiting;
    assign read_address={lookup_line,lookup_address[4:3]};
    assign rsp_data=rsp_zero ? 8'd0 : rsp_hot ? (hot_select ? hot_byte : hot_old_byte) : read_word[rsp_lane*8+:8];
    assign line_ready=ready && ((fill_busy && fill_word==3) || (!fill_busy && line_valid && line_error!=0));

    always_comb begin
        lookup_hit=0;lookup_pending=0;lookup_space=0;lookup_line=0;lookup_victim=0;
        pf_hit=0;pf_pending=0;pf_space=0;pf_victim=0;
        for(integer way=0;way<4;way=way+1) begin
            if(tags[way][lookup_voice]==lookup_tag) begin
                if(valid[{lookup_voice,2'(way)}]) begin lookup_hit=lookup_mapped;lookup_line={lookup_voice,2'(way)};end
                if(pending[{lookup_voice,2'(way)}]) lookup_pending=lookup_mapped;
            end
            if(tags[way][pf_saved_voice]==pf_tag) begin
                if(valid[{pf_saved_voice,2'(way)}]) pf_hit=pf_mapped;
                if(pending[{pf_saved_voice,2'(way)}]) pf_pending=pf_mapped;
            end
        end
        // Invalid entries first, then round-robin among lines that are not in flight.
        for(integer offset=3;offset>=0;offset=offset-1) begin
            if(!lookup_pending_ways[2'(replacement[lookup_voice]+offset)]) begin
                lookup_space=1;lookup_victim={lookup_voice,2'(replacement[lookup_voice]+offset)};
            end
            if(!pf_pending_ways[2'(replacement[pf_saved_voice]+offset)]) begin
                pf_space=1;pf_victim={pf_saved_voice,2'(replacement[pf_saved_voice]+offset)};
            end
        end
        for(integer way=3;way>=0;way=way-1) begin
            if(!valid[{lookup_voice,2'(way)}] && !pending[{lookup_voice,2'(way)}]) begin lookup_space=1;lookup_victim={lookup_voice,2'(way)};end
            if(!valid[{pf_saved_voice,2'(way)}] && !pending[{pf_saved_voice,2'(way)}]) begin pf_space=1;pf_victim={pf_saved_voice,2'(way)};end
        end
    end

    for(genvar way=0;way<4;way=way+1) begin: tag_bank
        always_ff @(posedge clk)
            if(!rst && !flush && (allocate_req || allocate_pf) && allocated_line[1:0]==way)
                tags[way][allocated_voice]<=allocated_tag;
    end

    // The BRAM output register is also the newest hot word; keep the preceding word for exponent/sample alternation.
    always_ff @(posedge clk) begin
        if(read_enable) read_word<=memory[read_address];
        if(ready && line_valid && line_error==0) begin
            if(!fill_busy) memory[{line_tag,2'b00}]<=line_data[63:0];
            else memory[{line_tag,fill_word}]<=line_data[fill_word*64+:64];
        end
    end

    always_ff @(posedge clk) begin
        if(rst || flush) begin
            valid<=0;pending<=0;waiting<=0;fill_busy<=0;fill_word<=0;
            rsp_valid<=0;rsp_zero<=0;rsp_hot<=0;rsp_lane<=0;fault<=0;lookup_new<=0;demand_inflight<=0;
            hot_old_word<=0;hot_tag<=0;hot_old_tag<=0;hot_valid<=0;hot_old_valid<=0;hot_byte<=0;hot_old_byte<=0;hot_select<=0;
            pf_queued<=0;pf_saved_voice<=0;pf_saved_cs<=0;pf_saved_address<=0;
            fetch_valid<=0;fetch_address<=0;fetch_tag<=0;
            saved_voice<=0;saved_cs<=0;saved_address<=0;
            flushing<=!rst;hits<=0;misses<=0;unmapped<=0;count_hit<=0;
            for(integer voice=0;voice<64;voice=voice+1) replacement[voice]<=0;
        end else begin
            count_hit<=(accept_req && request_mapped && (hot_hit || hot_old_hit)) || (waiting && lookup_new && lookup_hit);
            if(count_hit && hits!=32'hffffffff) hits<=hits+1'b1;
            if(flushing && fetch_idle) flushing<=0;
            if(rsp_valid && rsp_ready) rsp_valid<=0;
            if(fetch_valid && fetch_ready) fetch_valid<=0;
            if(process_pf) pf_queued<=0;
            if(accept_pf) begin pf_queued<=1;pf_saved_voice<=prefetch_voice;pf_saved_cs<=prefetch_cs;pf_saved_address<=prefetch_address;end
            if(accept_req) begin
                demand_inflight<=0;
                saved_voice<=req_voice;saved_cs<=req_cs;saved_address<=req_address;
                hot_byte<=read_word[req_address[2:0]*8+:8];
                hot_old_byte<=hot_old_word[req_address[2:0]*8+:8];
                hot_select<=hot_hit;
                if(!request_mapped) begin
                    rsp_valid<=1;rsp_zero<=1;
                    if(unmapped!=32'hffffffff) unmapped<=unmapped+1'b1;
                end else if(hot_hit || hot_old_hit) begin
                    rsp_valid<=1;rsp_zero<=0;rsp_hot<=1;
                end else begin
                    waiting<=1;lookup_new<=1;
                end
            end
            if(waiting && lookup_new) begin
                lookup_new<=0;
                if(!lookup_hit && misses!=32'hffffffff) misses<=misses+1'b1;
            end
            if(waiting && (allocate_req || lookup_pending)) demand_inflight<=1;
            if(read_enable) begin
                demand_inflight<=0;
                rsp_valid<=1;rsp_zero<=0;rsp_hot<=0;rsp_lane<=lookup_address[2:0];waiting<=0;
                hot_old_word<=read_word;hot_old_tag<=hot_tag;hot_old_valid<=hot_valid;
                hot_tag<={lookup_cs,lookup_address[21:3]};hot_valid<=1;
            end
            if(allocate_req || allocate_pf) begin
                valid[allocated_line]<=0;pending[allocated_line]<=1;
                replacement[allocated_voice]<=allocated_line[1:0]+1'b1;
                fetch_valid<=1;fetch_address<=32'h10000000+{7'd0,allocated_tag,5'd0};fetch_tag<=allocated_line;
            end
            if(ready && line_valid) begin
                if(line_error!=0) begin fault<=1;pending[line_tag]<=0;valid[line_tag]<=0;end
                else if(!fill_busy) begin fill_busy<=1;fill_word<=1;end
                else if(fill_word==3) begin fill_busy<=0;valid[line_tag]<=1;pending[line_tag]<=0;end
                else fill_word<=fill_word+1'b1;
            end
        end
    end
endmodule
