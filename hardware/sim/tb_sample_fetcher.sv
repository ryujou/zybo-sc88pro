// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_sample_fetcher;
    logic clk=0,rst=1,flush=0,idle,req_valid=0,req_ready;
    logic [31:0] req_address=0;
    logic [7:0] req_tag=0,line_tag;
    logic line_valid,line_ready=0;
    logic [255:0] line_data;
    logic [3:0] line_error,fault;
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
    integer mode=0,cycles=0,requests=0,addresses=0,responses=0,lines=0,expected_line=0;
    integer response_index=0,response_beat=0,wait_cycles=0,max_outstanding=0;
    integer fault_tests=0,flush_tests=0;
    logic r_fire=0,old_ar_stall=0,old_line_stall=0;
    logic [31:0] old_araddr;
    logic [255:0] old_line_data;
    logic [7:0] old_line_tag;
    logic [3:0] old_line_error;
    pcm_sample_fetcher dut(.*);
    always #5 clk=~clk;

    function automatic logic [31:0] address_for(input integer index);
        address_for=32'h10000000+32'((index*32'h10420)%(20*1024*1024));
    endfunction
    function automatic logic [63:0] word_for(input logic [31:0] address,input integer beat);
        logic [31:0] offset;
        for(integer lane=0;lane<8;lane=lane+1) begin
            offset=address-32'h10000000+32'(beat*8+lane);
            word_for[lane*8+:8]=8'((offset*73+(offset>>7)*19+32'h35)^(offset>>13));
        end
    endfunction

    always @(posedge clk) begin
        if(rst) begin
            cycles=0;requests=0;addresses=0;responses=0;lines=0;expected_line=0;r_fire=0;
            old_ar_stall=0;old_line_stall=0;max_outstanding=0;
        end else begin
            cycles=cycles+1;
            if(req_valid && req_ready) requests=requests+1;
            if(old_ar_stall && (!m_axi_arvalid || m_axi_araddr!==old_araddr)) $fatal(1,"AR changed under stall/flush");
            if(old_line_stall && !flush && (!line_valid || line_data!==old_line_data || line_tag!==old_line_tag || line_error!==old_line_error)) $fatal(1,"Line changed under stall");
            old_ar_stall=m_axi_arvalid && !m_axi_arready;old_araddr=m_axi_araddr;
            old_line_stall=line_valid && !line_ready && !flush;
            old_line_data=line_data;old_line_tag=line_tag;old_line_error=line_error;
            if(m_axi_arvalid && m_axi_arready) begin
                if(addresses>=requests || m_axi_araddr!==address_for(addresses)) $fatal(1,"AXI address order");
                if(m_axi_arid!=0 || m_axi_arlen!=3 || m_axi_arsize!=3 || m_axi_arburst!=1 || m_axi_arlock!=0 || m_axi_araddr[4:0]!=0) $fatal(1,"AXI attributes");
                if({1'b0,m_axi_araddr[11:0]}+13'd32>4096) $fatal(1,"4KB crossing");
                addresses=addresses+1;
            end
            r_fire=m_axi_rvalid && m_axi_rready;
            if(r_fire && m_axi_rlast) responses=responses+1;
            if(outstanding>max_outstanding) max_outstanding=outstanding;
            if(outstanding>4) $fatal(1,"Too many outstanding");
            if(line_valid && line_ready) begin
                if(mode!=0 || line_error!=0 || line_tag!==8'(expected_line)) $fatal(1,"Line tag/error");
                for(integer beat=0;beat<4;beat=beat+1)
                    if(line_data[beat*64+:64]!==word_for(address_for(expected_line),beat)) $fatal(1,"Line data/order index=%0d beat=%0d",expected_line,beat);
                expected_line=expected_line+1;lines=lines+1;
            end
        end
    end

    // Single-ID slave model accepts addresses independently and delays in-order read responses.
    always @(negedge clk) begin
        if(rst) begin
            m_axi_arready=0;m_axi_rvalid=0;m_axi_rdata=0;m_axi_rid=0;m_axi_rresp=0;m_axi_rlast=0;
            response_index=0;response_beat=0;wait_cycles=32;
        end else begin
            m_axi_arready=(mode==6 ? cycles>1100 : cycles>=12 && cycles%11>=3);
            if(r_fire) begin
                if(m_axi_rlast) begin response_index=response_index+1;response_beat=0;wait_cycles=mode==5 ? 1100 : (response_index%33);end
                else begin response_beat=response_beat+1;wait_cycles=response_beat%4;end
                m_axi_rvalid=0;
            end
            if(!m_axi_rvalid) begin
                if(mode==5 && response_index==0 && cycles<1100) begin end
                else if(wait_cycles>0) wait_cycles=wait_cycles-1;
                else if(response_index<addresses) begin
                    m_axi_rvalid=1;m_axi_rdata=word_for(address_for(response_index),response_beat);
                    m_axi_rid=mode==2 ? 6'd1 : 6'd0;
                    m_axi_rresp=mode==1 ? 2'd2 : 2'd0;
                    m_axi_rlast=response_beat==(mode==3 ? 2 : mode==4 ? 4 : 3);
                end
            end
        end
    end

    task automatic reset_core(input integer next_mode);
        @(negedge clk);#1;rst=1;flush=0;req_valid=0;line_ready=0;mode=next_mode;
        repeat(2) @(negedge clk);#1;rst=0;
        @(negedge clk);#1;
        if(!idle || fault!=0) $fatal(1,"Shared reset");
    endtask
    task automatic request_line(input integer index);
        req_address=address_for(index);req_tag=8'(index);req_valid=1;
        do begin @(posedge clk);end while(!req_ready);
        @(negedge clk);#1;req_valid=0;
    endtask
    task automatic wait_idle(input integer limit);
        for(integer elapsed=0;!idle;elapsed=elapsed+1) begin
            if(elapsed>limit) $fatal(1,"Drain did not finish");
            @(negedge clk);#1;
        end
    endtask
    task automatic pulse_flush;
        flush=1;@(negedge clk);#1;flush=0;
    endtask

    initial begin
        reset_core(0);
        fork
            begin for(integer i=0;i<1024;i=i+1) request_line(i);end
            begin
                while(lines<1024) begin @(negedge clk);#1;line_ready=cycles%17>=8;end
                line_ready=0;
            end
        join
        wait_idle(100);
        if(requests!=1024 || addresses!=1024 || responses!=1024 || max_outstanding!=4 || fault!=0) $fatal(1,"Normal traffic counts");
        for(integer offset=0;offset<8;offset=offset+1) begin
            reset_core(0);
            for(integer i=0;i<4;i=i+1) request_line(i);
            repeat(offset*13) begin @(negedge clk);#1;end
            pulse_flush();wait_idle(256);
            if(fault!=0 || addresses!=4 || responses!=4 || line_valid) $fatal(1,"Local flush lost accepted traffic");
            expected_line=4;line_ready=1;
            for(integer i=4;i<8;i=i+1) request_line(i);
            wait_idle(256);
            if(lines!=4 || expected_line!=8 || fault!=0) $fatal(1,"Post-flush recovery");
            flush_tests=flush_tests+1;
        end
        for(integer failure=1;failure<=6;failure=failure+1) begin
            reset_core(failure);request_line(0);
            for(integer elapsed=0;fault==0;elapsed=elapsed+1) begin
                if(elapsed>1200) $fatal(1,"Missing AXI fault mode=%0d",failure);
                @(negedge clk);#1;
            end
            if(fault!==(failure==1 ? 4'b0001 : failure==2 ? 4'b0010 : failure<=4 ? 4'b0100 : 4'b1000) || req_ready) $fatal(1,"Wrong AXI fault mode=%0d fault=%b",failure,fault);
            pulse_flush();wait_idle(1500);
            if(fault!=0 || responses!=1 || line_valid) $fatal(1,"Fault flush");
            fault_tests=fault_tests+1;
        end
        $display("SAMPLE_FETCHER_PASS lines=1024 outstanding=4 flush_positions=%0d fault_tests=%0d",flush_tests,fault_tests);
        $finish;
    end
    initial begin #(64'd10000000);$fatal(1,"Fetcher watchdog");end
endmodule
