// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_sample_cache;
    logic clk=0,rst=1,flush=0,fetch_idle,ready,req_valid=0,req_ready,rsp_valid,rsp_ready=0;
    logic [5:0] req_voice=0,prefetch_voice=0;
    logic [2:0] req_cs=0,prefetch_cs=0;
    logic [23:0] req_address=0,prefetch_address=0;
    logic [7:0] rsp_data;
    logic prefetch_valid=0,prefetch_ready,fetch_valid,fetch_ready,line_valid,line_ready,fault;
    logic [31:0] fetch_address,hits,misses,unmapped;
    logic [7:0] fetch_tag,line_tag;
    logic [255:0] line_data;
    logic [3:0] line_error,bus_fault;
    logic [2:0] outstanding;
    logic m_axi_arvalid,m_axi_arready=0,m_axi_arlock;
    logic [31:0] m_axi_araddr;
    logic [5:0] m_axi_arid,m_axi_rid=0;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize,m_axi_arprot;
    logic [1:0] m_axi_arburst,m_axi_rresp=0;
    logic [3:0] m_axi_arcache;
    logic m_axi_rvalid=0,m_axi_rready,m_axi_rlast=0;
    logic [63:0] m_axi_rdata=0;
    logic [31:0] queue [0:4095];
    integer issued=0,responded=0,cycles=0,beat=0,delay=20,reads=0,hit_reads=0,flush_tests=0;
    integer before_bursts;
    integer hot_tag0=-1,hot_tag1=-1,bram_hits=0;
    logic r_fire=0,inject_error=0,issue_stall=0;
    logic [31:0] held_address;
    logic [7:0] held_tag;
    pcm_sample_cache cache(.*);
    pcm_sample_fetcher fetcher(.clk,.rst,.flush,.idle(fetch_idle),.req_valid(fetch_valid),.req_ready(fetch_ready),
        .req_address(fetch_address),.req_tag(fetch_tag),.line_valid,.line_ready,.line_tag,.line_data,.line_error,
        .fault(bus_fault),.outstanding,.m_axi_arvalid,.m_axi_arready,.m_axi_araddr,.m_axi_arid,.m_axi_arlen,
        .m_axi_arsize,.m_axi_arburst,.m_axi_arlock,.m_axi_arcache,.m_axi_arprot,.m_axi_rvalid,.m_axi_rready,
        .m_axi_rdata,.m_axi_rid,.m_axi_rresp,.m_axi_rlast);
    always #5 clk=~clk;
    function automatic logic [7:0] byte_for(input logic [31:0] offset);
        byte_for=8'((offset*73+(offset>>7)*19+32'h35)^(offset>>13));
    endfunction

    always @(posedge clk) begin
        if(rst) begin issued=0;cycles=0;r_fire=0;issue_stall=0;end
        else begin
            cycles=cycles+1;
            if(issue_stall && !flush && (!fetch_valid || fetch_address!==held_address || fetch_tag!==held_tag)) $fatal(1,"Cache fetch changed under stall");
            issue_stall=fetch_valid && !fetch_ready && !flush;held_address=fetch_address;held_tag=fetch_tag;
            if(m_axi_arvalid && m_axi_arready) begin
                if(m_axi_araddr<32'h10000000 || m_axi_araddr>=32'h11400000 || m_axi_araddr[4:0]!=0 || m_axi_arlen!=3 || m_axi_arsize!=3) $fatal(1,"Cache DDR mapping");
                queue[issued]=m_axi_araddr;issued=issued+1;
            end
            r_fire=m_axi_rvalid && m_axi_rready;
        end
    end
    always @(negedge clk) begin
        if(rst) begin
            responded=0;beat=0;delay=20;m_axi_arready=0;m_axi_rvalid=0;m_axi_rresp=0;m_axi_rlast=0;
        end else begin
            m_axi_arready=cycles%9>=2;
            if(r_fire) begin
                if(m_axi_rlast) begin responded=responded+1;beat=0;delay=responded%33;end
                else begin beat=beat+1;delay=beat%4;end
                m_axi_rvalid=0;
            end
            if(!m_axi_rvalid) begin
                if(delay>0) delay=delay-1;
                else if(responded<issued) begin
                    m_axi_rvalid=1;m_axi_rlast=beat==3;m_axi_rresp=inject_error ? 2'd2 : 2'd0;
                    for(integer lane=0;lane<8;lane=lane+1) m_axi_rdata[lane*8+:8]=byte_for(queue[responded]-32'h10000000+32'(beat*8+lane));
                end
            end
        end
    end
    task automatic reset_core;
        @(negedge clk);#1;rst=1;flush=0;req_valid=0;prefetch_valid=0;rsp_ready=0;inject_error=0;hot_tag0=-1;hot_tag1=-1;
        repeat(2) @(negedge clk);#1;rst=0;
        @(negedge clk);#1;if(!ready) $fatal(1,"Cache reset");
    endtask
    task automatic request_byte(input integer voice,input integer cs,input integer address);
        req_voice=6'(voice);req_cs=3'(cs);req_address=24'(address);req_valid=1;
        do begin @(posedge clk);end while(!req_ready);
        @(negedge clk);#1;req_valid=0;
    endtask
    task automatic read_byte(input integer voice,input integer cs,input integer address,input logic must_hit);
        logic [7:0] expected;
        logic mapped,fast_hit;
        integer word_tag;
        mapped=cs<5 && address<4194304;word_tag=cs*524288+(address>>3);
        fast_hit=!mapped || hot_tag0==word_tag || hot_tag1==word_tag;
        request_byte(voice,cs,address);
        if(fast_hit && !rsp_valid) $fatal(1,"Hot-word response is not one cycle");
        if(must_hit && !fast_hit) begin
            if(rsp_valid) $fatal(1,"BRAM lookup bypassed request register");
            @(negedge clk);#1;
            if(!rsp_valid) $fatal(1,"BRAM hit exceeds two cycles");
            bram_hits=bram_hits+1;
        end
        for(integer elapsed=0;!rsp_valid;elapsed=elapsed+1) begin
            if(elapsed>256) $fatal(1,"Cache read timeout voice=%0d address=%h",voice,address);
            @(negedge clk);#1;
        end
        expected=cs>=5 || address>=4194304 ? 8'd0 : byte_for(32'(cs*4194304+address));
        repeat(reads%4+1) begin
            if(!rsp_valid || rsp_data!==expected) $fatal(1,"CACHE_BYTE_DIFFERENCE voice=%0d address=%h got=%h expected=%h",voice,address,rsp_data,expected);
            @(negedge clk);#1;
        end
        rsp_ready=1;@(negedge clk);#1;rsp_ready=0;reads=reads+1;if(fast_hit) hit_reads=hit_reads+1;
        if(mapped && !fast_hit) begin hot_tag1=hot_tag0;hot_tag0=word_tag;end
    endtask
    task automatic prefetch_line(input integer voice,input integer cs,input integer address);
        prefetch_voice=6'(voice);prefetch_cs=3'(cs);prefetch_address=24'(address);prefetch_valid=1;
        do begin @(posedge clk);end while(!prefetch_ready);
        @(negedge clk);#1;prefetch_valid=0;
    endtask
    task automatic wait_drained;
        for(integer elapsed=0;!fetch_idle || fetch_valid || cache.pf_queued;elapsed=elapsed+1) begin
            if(elapsed>256) $fatal(1,"Cache/fetch drain timeout");
            @(negedge clk);#1;
        end
    endtask
    task automatic local_flush;
        flush=1;req_valid=0;prefetch_valid=0;hot_tag0=-1;hot_tag1=-1;@(negedge clk);#1;flush=0;
        for(integer elapsed=0;!ready;elapsed=elapsed+1) begin
            if(rsp_valid) $fatal(1,"Stale response during flush");
            if(elapsed>256) $fatal(1,"Local flush timeout");
            @(negedge clk);#1;
        end
        if(!fetch_idle || rsp_valid || fault || bus_fault) $fatal(1,"Local flush did not drain");
    endtask

    initial begin
        reset_core();
        read_byte(0,0,24'h40040,0);
        before_bursts=issued;
        for(integer offset=0;offset<32;offset=offset+1) read_byte(0,0,24'h40040+offset,1);
        if(issued!=before_bursts) $fatal(1,"Hit caused extra burst");
        read_byte(1,0,24'h40040,0);read_byte(0,0,24'h40041,1);
        for(integer way=1;way<4;way=way+1) read_byte(0,0,24'h40040+way*64,0);
        read_byte(0,0,24'h40040+4*64,0);
        before_bursts=issued;read_byte(0,0,24'h40040,0);
        if(issued!=before_bursts+1) $fatal(1,"Round-robin did not evict first line");
        reset_core();
        for(integer way=0;way<4;way=way+1) prefetch_line(0,2,24'h60000+way*64);
        prefetch_line(0,2,24'h60000);wait_drained();
        if(issued!=4) $fatal(1,"Duplicate pending prefetch");
        for(integer way=0;way<4;way=way+1) read_byte(0,2,24'h60001+way*64,1);
        for(integer voice=1;voice<64;voice=voice+1) begin
            for(integer way=0;way<4;way=way+1) prefetch_line(voice,voice%5,24'h60000+voice*4096+way*64);
            wait_drained();
        end
        for(integer voice=1;voice<64;voice=voice+1)
            for(integer way=0;way<4;way=way+1) read_byte(voice,voice%5,24'h60000+voice*4096+way*64+voice%32,1);
        before_bursts=issued;
        read_byte(0,7,24'h40040,1);read_byte(0,0,24'h400000,1);
        if(issued!=before_bursts || unmapped!=2) $fatal(1,"Unmapped reads reached DDR");
        for(integer offset=0;offset<8;offset=offset+1) begin
            reset_core();prefetch_line(1,1,24'h90000);request_byte(0,0,24'h70000);
            repeat(offset*7) begin @(negedge clk);#1;end
            local_flush();read_byte(0,0,24'h70000,0);flush_tests=flush_tests+1;
        end
        reset_core();inject_error=1;request_byte(0,0,24'h40040);
        for(integer elapsed=0;!fault;elapsed=elapsed+1) begin
            if(elapsed>256) $fatal(1,"Missing cache fill fault");
            @(negedge clk);#1;
        end
        if(rsp_valid || ready || bus_fault==0) $fatal(1,"Bad fill became valid");
        inject_error=0;local_flush();read_byte(0,0,24'h40040,0);
        $display("SAMPLE_CACHE_PASS reads=%0d one_cycle_hits=%0d two_cycle_BRAM_hits=%0d flush_positions=%0d",reads,hit_reads,bram_hits,flush_tests);
        $finish;
    end
    initial begin #(64'd10000000);$fatal(1,"Cache watchdog");end
endmodule
