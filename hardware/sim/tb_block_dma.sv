// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_block_dma;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,stop=0,rd_start=0,wr_start=0;
    logic [31:0] rd_base=32'h02000ff0,rd_bytes=2048,wr_base=32'h06000ff8,wr_bytes=2056;
    wire rd_idle,wr_idle,rd_done,wr_done;
    wire [3:0] rd_error,wr_error;
    wire read_valid,write_ready;
    logic read_ready=0,write_valid=0;
    wire [63:0] read_data;
    logic [63:0] write_data;
    wire m_axi_arvalid,m_axi_rready,m_axi_awvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready;
    logic m_axi_arready=0,m_axi_rvalid=0,m_axi_awready=0,m_axi_wready=0,m_axi_bvalid=0;
    wire [31:0] m_axi_araddr,m_axi_awaddr;
    wire [7:0] m_axi_arlen,m_axi_awlen;
    logic [63:0] m_axi_rdata=0;
    wire [63:0] m_axi_wdata;
    logic [5:0] m_axi_rid=0,m_axi_bid=0;
    logic [1:0] m_axi_rresp=0,m_axi_bresp=0;
    logic m_axi_rlast=0;
    pcm_block_dma dut(.*);
    integer cycles=0,mode=0,started_at=0,read_count=0,sent_count=0,write_count=0,ar_count=0,aw_count=0;
    integer rwords=0,rindex=0,rdelay=0,wwords=0,windex=0,bdelay=0;
    integer read_done_count=0,write_done_count=0,tests=0;
    logic rbusy=0,wbusy=0,bpending=0;
    logic [31:0] raddress=0,waddress=0;
    function automatic [63:0] value_at(input logic [31:0] address);
        value_at={address^32'h87654321,(address*32'd73)^32'hf01234ab};
    endfunction
    assign write_data=value_at(wr_base+32'(sent_count*8));
    logic held_ar=0,held_aw=0,held_w=0;
    logic [39:0] previous_ar,previous_aw;
    logic [64:0] previous_w;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(rst) begin
            m_axi_rvalid<=0;m_axi_bvalid<=0;rbusy<=0;wbusy<=0;bpending<=0;
            rwords<=0;rindex<=0;rdelay<=0;wwords<=0;windex<=0;bdelay<=0;
            read_count<=0;sent_count<=0;write_count<=0;ar_count<=0;aw_count<=0;
            read_done_count<=0;write_done_count<=0;held_ar<=0;held_aw<=0;held_w<=0;
        end else begin
            if(held_ar && (!m_axi_arvalid || {m_axi_araddr,m_axi_arlen}!==previous_ar)) $fatal(1,"AR_CHANGED");
            if(held_aw && (!m_axi_awvalid || {m_axi_awaddr,m_axi_awlen}!==previous_aw)) $fatal(1,"AW_CHANGED");
            if(held_w && (!m_axi_wvalid || {m_axi_wdata,m_axi_wlast}!==previous_w)) $fatal(1,"W_CHANGED");
            held_ar<=m_axi_arvalid && !m_axi_arready;previous_ar<={m_axi_araddr,m_axi_arlen};
            held_aw<=m_axi_awvalid && !m_axi_awready;previous_aw<={m_axi_awaddr,m_axi_awlen};
            held_w<=m_axi_wvalid && !m_axi_wready;previous_w<={m_axi_wdata,m_axi_wlast};
            if(rd_done) read_done_count<=read_done_count+1;
            if(wr_done) write_done_count<=write_done_count+1;
            if(read_valid && read_ready) begin
                if(read_data!==value_at(rd_base+32'(read_count*8))) $fatal(1,"DMA_READ_DATA");
                read_count<=read_count+1;
            end
            if(write_valid && write_ready) sent_count<=sent_count+1;
            if(m_axi_arvalid && m_axi_arready) begin
                if(rbusy || m_axi_araddr[2:0]!=0 || m_axi_arlen>=16 || {1'b0,m_axi_araddr[11:0]}+(m_axi_arlen+1)*8>4096) $fatal(1,"DMA_READ_BURST");
                rbusy<=1;raddress<=m_axi_araddr;rindex<=0;rwords<=m_axi_arlen+1+(mode==4);
                rdelay<=mode==7 ? 1100 : 4;ar_count<=ar_count+1;
            end
            if(rbusy && !m_axi_rvalid) begin
                if(rdelay>0) rdelay<=rdelay-1;
                else begin
                    m_axi_rvalid<=1;m_axi_rdata<=value_at(raddress+32'(rindex*8));
                    m_axi_rresp<=mode==1 ? 2'b10 : 0;m_axi_rid<=mode==2 ? 1 : 0;
                    m_axi_rlast<=mode==3 || rindex+1==rwords;
                end
            end
            if(m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid<=0;
                if(m_axi_rlast) rbusy<=0;
                else begin rindex<=rindex+1;rdelay<=rindex%3;end
            end
            if(m_axi_awvalid && m_axi_awready) begin
                if(wbusy || bpending || m_axi_bvalid || m_axi_awaddr[2:0]!=0 || m_axi_awlen>=16 || {1'b0,m_axi_awaddr[11:0]}+(m_axi_awlen+1)*8>4096) $fatal(1,"DMA_WRITE_BURST");
                wbusy<=1;waddress<=m_axi_awaddr;windex<=0;wwords<=m_axi_awlen+1;aw_count<=aw_count+1;
            end
            if(m_axi_wvalid && m_axi_wready) begin
                if(!wbusy || m_axi_wdata!==value_at(waddress+32'(windex*8)) || m_axi_wlast!=(windex+1==wwords)) $fatal(1,"DMA_WRITE_DATA");
                write_count<=write_count+1;
                if(m_axi_wlast) begin wbusy<=0;bpending<=1;bdelay<=5;end
                else windex<=windex+1;
            end
            if(bpending && !m_axi_bvalid) begin
                if(bdelay>0) bdelay<=bdelay-1;
                else begin m_axi_bvalid<=1;bpending<=0;m_axi_bresp<=mode==5 ? 2'b10 : 0;m_axi_bid<=mode==6 ? 1 : 0;end
            end
            if(m_axi_bvalid && m_axi_bready) m_axi_bvalid<=0;
        end
    end
    always @(negedge clk) begin
        read_ready=cycles%5!=0;
        m_axi_arready=!rst && cycles%7==3;
        m_axi_awready=!rst && cycles%7==4 && !(mode==8 && cycles-started_at<1100);
        m_axi_wready=!rst && wbusy && cycles%4!=0;
        write_valid=!rst && sent_count<wr_bytes/8;
    end
    task automatic launch(input integer selected_mode,input integer words);
        @(negedge clk);rst=1;stop=0;mode=selected_mode;rd_start=0;wr_start=0;
        rd_base=32'h02000ff0;wr_base=32'h06000ff8;rd_bytes=32'(words*8);wr_bytes=32'((words+1)*8);
        repeat(4) @(negedge clk);rst=0;
        @(negedge clk);rd_start=1;wr_start=1;started_at=cycles;
        @(negedge clk);rd_start=0;wr_start=0;
    endtask
    task automatic finish_jobs;
        integer deadline;
        deadline=cycles+20000;
        while(read_done_count==0 || write_done_count==0) begin
            @(negedge clk);
            if(cycles>=deadline) $fatal(1,"DMA_JOB_TIMEOUT mode=%0d rd=%0d wr=%0d",mode,rd_error,wr_error);
        end
        if(!rd_idle || !wr_idle || rbusy || wbusy || bpending || m_axi_bvalid || m_axi_rvalid) $fatal(1,"DMA_NOT_DRAINED");
        tests=tests+1;
    endtask
    initial begin
        launch(0,256);finish_jobs();
        if(rd_error!=0 || wr_error!=0 || read_count!=256 || write_count!=257 || ar_count!=17 || aw_count!=17) $fatal(1,"DMA_NORMAL_COUNTS");
        for(integer error_case=1;error_case<=8;error_case=error_case+1) begin
            launch(error_case,64);finish_jobs();
            case(error_case)
                1:if(rd_error!=2 || wr_error!=0) $fatal(1,"RRESP_NOT_DETECTED");
                2:if(rd_error!=4 || wr_error!=0) $fatal(1,"RID_NOT_DETECTED");
                3,4:if(rd_error!=3 || wr_error!=0) $fatal(1,"RLAST_NOT_DETECTED");
                5:if(wr_error!=2 || rd_error!=0) $fatal(1,"BRESP_NOT_DETECTED");
                6:if(wr_error!=4 || rd_error!=0) $fatal(1,"BID_NOT_DETECTED");
                7:if(rd_error!=5 || wr_error!=0) $fatal(1,"R_TIMEOUT_NOT_DETECTED");
                8:if(wr_error!=5 || rd_error!=0) $fatal(1,"AW_TIMEOUT_NOT_DETECTED");
            endcase
        end
        for(integer position=0;position<4;position=position+1) begin
            launch(0,256);
            case(position)
                0:while(!m_axi_arvalid) @(negedge clk);
                1:while(!m_axi_awvalid) @(negedge clk);
                2:while(!m_axi_wvalid) @(negedge clk);
                3:while(!m_axi_bready) @(negedge clk);
            endcase
            stop=1;finish_jobs();
            if(rd_error!=6 || wr_error!=6) $fatal(1,"STOP_NOT_REPORTED");
        end
        launch(0,0);finish_jobs();
        if(rd_error!=1 || wr_error!=0) $fatal(1,"ZERO_LENGTH_NOT_REJECTED");
        $display("BLOCK_DMA_PASS tests=%0d crossing_4KiB=1 read_words=256 write_words=257 fault_cases=8 stop_positions=4",tests);
        $finish;
    end
    initial begin #10000000;$fatal(1,"DMA_SIM_TIMEOUT");end
endmodule
