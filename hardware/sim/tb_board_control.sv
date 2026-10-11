// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_board_control;
    logic clk=0,audio_clk=0,resetn=0,audio_reset=1;
    always #5 clk=~clk;
    always #40.69 audio_clk=~audio_clk;
    logic s_axi_awvalid=0,s_axi_wvalid=0,s_axi_bready=0,s_axi_arvalid=0,s_axi_rready=0;
    wire s_axi_awready,s_axi_wready,s_axi_bvalid,s_axi_arready,s_axi_rvalid;
    logic [11:0] s_axi_awaddr=0,s_axi_araddr=0;
    logic [31:0] s_axi_wdata=0;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_bresp,s_axi_rresp;
    wire bclk,lrclk,serial_data,mute_n,irq,m_wave_arvalid,m_wave_rready;
    logic m_wave_rvalid=0,m_wave_rlast=0;
    wire [127:0] debug_sys0,debug_sys1;
    wire [63:0] debug_audio;
    wire m_block_arvalid,m_block_rready,m_block_awvalid,m_block_wvalid,m_block_wlast,m_block_bready;
    wire [31:0] m_block_araddr,m_block_awaddr;
    wire [7:0] m_block_arlen,m_block_awlen,m_block_wstrb;
    wire [63:0] m_block_wdata;
    logic m_block_rvalid=0,m_block_rlast=0,m_block_bvalid=0,m_block_wready=0;
    logic [63:0] m_block_rdata=0;
    logic hold_read=0;
    pcm_board dut (
        .clk,.resetn,.audio_clk,.audio_reset,.bclk,.lrclk,.serial_data,.mute_n,.irq,.debug_sys0,.debug_sys1,.debug_audio,
        .s_axi_awvalid,.s_axi_awready,.s_axi_awaddr,.s_axi_awprot(3'd0),.s_axi_wvalid,.s_axi_wready,.s_axi_wdata,.s_axi_wstrb(4'hf),
        .s_axi_bvalid,.s_axi_bready,.s_axi_bresp,.s_axi_arvalid,.s_axi_arready,.s_axi_araddr,.s_axi_arprot(3'd0),
        .s_axi_rvalid,.s_axi_rready,.s_axi_rdata,.s_axi_rresp,
        .m_wave_arvalid,.m_wave_arready(1'b1),.m_wave_rvalid,.m_wave_rready,.m_wave_rdata(64'd0),.m_wave_rid(6'd0),.m_wave_rresp(2'd0),.m_wave_rlast,
        .m_block_arvalid,.m_block_arready(1'b1),.m_block_araddr,.m_block_arlen,
        .m_block_rvalid,.m_block_rready,.m_block_rdata,.m_block_rid(6'd0),.m_block_rresp(2'd0),.m_block_rlast,
        .m_block_awvalid,.m_block_awready(1'b1),.m_block_awaddr,.m_block_awlen,
        .m_block_wvalid,.m_block_wready,.m_block_wdata,.m_block_wstrb,.m_block_wlast,
        .m_block_bvalid,.m_block_bready,.m_block_bid(6'd0),.m_block_bresp(2'd0)
    );
    integer read_left=0,read_index=0,write_left=0,write_index=0,accepted_reads=0,accepted_writes=0,samples=0,checks=0;
    integer wave_pending=0,wave_beat=0;
    logic read_fire=0;
    logic [31:0] value;
    logic [63:0] expected_record;
    integer slot,send_index;
    always @(posedge clk) if(resetn) begin
        if(m_wave_arvalid) wave_pending=wave_pending+1;
        if(m_wave_rvalid && m_wave_rready) begin
            if(m_wave_rlast) begin wave_pending=wave_pending-1;wave_beat=0;end
            else wave_beat=wave_beat+1;
        end
        read_fire=m_block_rvalid && m_block_rready;
        if(m_block_arvalid) begin
            if(read_left || m_block_araddr!=32'h02000000 || m_block_arlen!=2) $fatal(1,"control test read burst");
            read_left=3;read_index=0;accepted_reads=accepted_reads+1;
        end
        if(read_fire) begin read_left=read_left-1;read_index=read_index+1;end
        if(m_block_awvalid) begin
            if(write_left || m_block_awaddr!=32'h06000000+write_index*8) $fatal(1,"control test write address");
            write_left=m_block_awlen+1;accepted_writes=accepted_writes+1;
        end
        if(m_block_wvalid && m_block_wready) begin
            slot=write_index%68;
            if(slot<4) begin
                send_index=slot;
                expected_record=(64'(slot==0 ? 0 : slot==3 ? 3 : 2)<<54)|(64'(send_index)<<46);
            end else expected_record=(64'd1<<63)|(64'(slot==4)<<62)|(64'(slot-4)<<40);
            if(write_left==0 || m_block_wdata!==expected_record || m_block_wstrb!=255 || m_block_wlast!==(write_left==1))
                $fatal(1,"control test result record %d",write_index);
            write_left=write_left-1;write_index=write_index+1;
            if(m_block_wlast) m_block_bvalid<=1;
        end
        if(m_block_bvalid && m_block_bready) m_block_bvalid<=0;
        if(dut.local_clear && (read_left || write_left || m_block_bvalid)) $fatal(1,"reset cancelled accepted AXI");
    end
    always @(negedge clk) if(resetn) begin
        m_wave_rvalid=wave_pending>0;m_wave_rlast=wave_beat==3;
        m_block_wready=write_left>0;
        if(read_fire) m_block_rvalid=0;
        if(!m_block_rvalid && !hold_read && read_left>0) begin
            m_block_rvalid=1;m_block_rlast=read_left==1;
            m_block_rdata=read_index==2 ? 64'h3000000000000000 : 64'h1000000000000000;
        end
    end
    always @(posedge audio_clk) begin #1;if(dut.audio_accepted) samples=samples+1;end
    task write_register(input logic [11:0] address,input logic [31:0] data,input logic [1:0] expected_response=0);
        logic aw_seen,w_seen;
        @(negedge clk);s_axi_awaddr=address;s_axi_wdata=data;s_axi_awvalid=1;s_axi_wvalid=1;
        aw_seen=0;w_seen=0;
        while(!aw_seen || !w_seen) begin
            @(posedge clk);
            if(s_axi_awvalid && s_axi_awready) aw_seen=1;
            if(s_axi_wvalid && s_axi_wready) w_seen=1;
            @(negedge clk);if(aw_seen) s_axi_awvalid=0;if(w_seen) s_axi_wvalid=0;
        end
        wait(s_axi_bvalid);if(s_axi_bresp!==expected_response) $fatal(1,"control write response %h: %b",address,s_axi_bresp);
        @(negedge clk);s_axi_bready=1;@(negedge clk);s_axi_bready=0;
    endtask
    task read_register(input logic [11:0] address,output logic [31:0] data);
        @(negedge clk);s_axi_araddr=address;s_axi_arvalid=1;
        @(posedge clk);while(!s_axi_arready) @(posedge clk);
        @(negedge clk);s_axi_arvalid=0;
        wait(s_axi_rvalid);if(s_axi_rresp!=0) $fatal(1,"control read rejected");
        data=s_axi_rdata;@(negedge clk);s_axi_rready=1;@(negedge clk);s_axi_rready=0;
    endtask
    task wait_ready;
        value=0;
        while(!value[0]) read_register(12'h008,value);
    endtask
    task configure;
        write_register(12'h05c,0);write_register(12'h014,7);
        write_register(12'h100,32'h02000000);write_register(12'h104,24);
        write_register(12'h108,32'h06000000);write_register(12'h10c,1088);
        write_register(12'h110,2);write_register(12'h114,0);write_register(12'h118,0);
        write_register(12'h11c,257);
    endtask
    initial begin
        repeat(100) @(negedge clk);resetn=1;audio_reset=0;
        wait_ready();read_register(0,value);if(value!=32'h53433430) $fatal(1,"board identity");
        write_register(12'h05c,0);
        write_register(12'h100,32'h02000000);write_register(12'h104,24);
        write_register(12'h108,32'h06000000);write_register(12'h10c,1080);
        write_register(12'h110,2);write_register(12'h114,0);write_register(12'h118,0);
        write_register(12'h11c,257,2'b10);
        if(dut.ownership || accepted_reads || accepted_writes) $fatal(1,"invalid result length committed");checks=checks+1;
        write_register(12'h10c,1088);write_register(12'h110,0);
        write_register(12'h11c,257,2'b10);
        if(dut.ownership || accepted_reads || accepted_writes) $fatal(1,"zero frames committed");checks=checks+1;
        write_register(12'h110,2);write_register(12'h100,32'h02000008);
        write_register(12'h11c,257,2'b10);
        if(dut.ownership || accepted_reads || accepted_writes) $fatal(1,"unaligned commands committed");checks=checks+1;
        configure();write_register(12'h11c,257,2'b10);
        if(dut.ownership!=1 || accepted_reads || accepted_writes) $fatal(1,"duplicate submission changed queue");checks=checks+1;
        write_register(4,1);
        wait(samples==2 && dut.finished);repeat(7000) @(negedge clk);
        if(mute_n || dut.fault || !irq || write_index!=136 || dut.completed!=2) $fatal(1,"board control playback");
        read_register(12'h010,value);if(value!=1) $fatal(1,"block completion IRQ");
        write_register(12'h010,1);if(irq) $fatal(1,"block IRQ clear");checks=checks+1;
        write_register(4,4);wait_ready();
        if(dut.completed || dut.ownership || dut.fault || mute_n) $fatal(1,"completed session reset");checks=checks+1;
        write_index=0;samples=0;configure();hold_read=1;write_register(4,1);
        wait(read_left==3);write_register(4,4);
        repeat(100) @(negedge clk);
        if(dut.local_clear || !dut.reset_busy || read_left!=3) $fatal(1,"accepted AXI reset drain");
        hold_read=0;wait_ready();
        if(read_left || write_left || dut.fault || dut.ownership) $fatal(1,"drain recovery");checks=checks+1;
        write_index=0;samples=0;configure();write_register(4,1);
        wait(samples==2 && dut.finished);repeat(7000) @(negedge clk);
        if(dut.fault || mute_n || write_index!=136 || accepted_reads!=3) $fatal(1,"fresh playback after drain reset");checks=checks+1;
        $display("BOARD_CONTROL_PASS checks=%0d playback_frames=4 accepted_read_reset=1",checks);$finish;
    end
    initial begin #20000000;$fatal(1,"board control watchdog");end
endmodule
