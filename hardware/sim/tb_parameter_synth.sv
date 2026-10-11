// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_parameter_synth #(parameter integer TOTAL=96);
    logic clk=0,audio_clk=0,rst=1,audio_reset=1,soft_reset=0,start=0,audio_start=0,stop=0,pause=0;
    always #5 clk=~clk;
    always #40.690104 audio_clk=~audio_clk;
    logic [63:0] first_frame=0,command_data=0;
    logic command_valid=0;
    wire command_ready,write_valid,write_ready,ready,ended,pause_ack,wave_idle;
    wire sample_valid,sample_ready,audio_finish;
    wire signed [23:0] sample_left=0,sample_right=0;
    wire [63:0] write_data;
    wire [13:0] fault;
    wire [31:0] completed,written,max_due_cycles,max_frame_cycles,cache_hits,cache_misses,axi_bursts,timeouts,overruns;
    wire [31:0] parameter_bursts,parameter_configs,parameter_packets,parameter_noops;
    wire [5:0] audio_level;
    wire bclk,lrclk,serial_data,mute_n,audio_accepted,audio_mute_n;
    wire signed [23:0] native_left,native_right;
    wire m_axi_arvalid,m_axi_rready,m_axi_arlock;
    logic m_axi_arready,m_axi_rvalid=0,m_axi_rlast=0;
    wire [31:0] m_axi_araddr;
    wire [5:0] m_axi_arid;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize,m_axi_arprot;
    wire [1:0] m_axi_arburst;
    wire [3:0] m_axi_arcache;
    logic [63:0] m_axi_rdata=0;
    logic [5:0] m_axi_rid=0;
    wire [1:0] m_axi_rresp=0;
    pcm_parameter_synth dut(.*);
    logic [63:0] memory[0:31][0:3];
    logic [31:0] addresses[0:127];
    logic [5:0] ids[0:127];
    integer issued=0,responded=0,beat=0,cycle=0,record_index=0,ps_frames=0,returned=0,played=0;
    logic audio_started=0;
    assign m_axi_arready=issued-responded<4 && cycle%5!=0;
    assign write_ready=cycle%19!=0;
    assign sample_valid=returned<ps_frames && cycle%7!=0;
    assign audio_finish=returned==TOTAL;
    function automatic integer voices(input integer n);voices=n%2 ? 32 : 64;endfunction
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(!rst) begin
            if(fault) $fatal(1,"parameter synth fault=%h completed=%0d age=%0d core=%0d max_core=%0d max_due=%0d active=%0d credits=%0d state=%0d mix=%0d commit=%0d param=%0d wi=%0d ps=%0d send=%0d mixvalid=%0d",
                fault,completed,dut.commands.age,dut.core.elapsed,max_frame_cycles,max_due_cycles,dut.commands.active_frame,dut.commands.credits,dut.core.state,
                dut.core.mixer_done,dut.core.fifo_commit_ready,dut.core.parameter_complete,
                dut.core.results.write_index,ps_frames,dut.core.send_valid,dut.core.mix_valid);
            if(m_axi_arvalid && m_axi_arready) begin
                if(!((m_axi_araddr>=32'h12000000 && m_axi_araddr<32'h12080000) ||
                     (m_axi_araddr>=32'h10000000 && m_axi_araddr<32'h11400000)) || m_axi_arlen!=3 || m_axi_arsize!=3)
                    $fatal(1,"unexpected DDR request");
                addresses[issued%128]=m_axi_araddr;ids[issued%128]=m_axi_arid;issued<=issued+1;
            end
            if(!m_axi_rvalid && responded<issued && cycle%3!=0) begin
                m_axi_rvalid<=1;m_axi_rlast<=beat==3;m_axi_rid<=ids[responded%128];
                m_axi_rdata<=addresses[responded%128]>=32'h12000000 ? memory[(addresses[responded%128]-32'h12000000)>>14][beat] : 0;
            end
            if(m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid<=0;
                if(beat==3) begin beat<=0;responded<=responded+1;end else beat<=beat+1;
            end
            if(write_valid && write_ready) begin
                if(ps_frames>=TOTAL || write_data[24:0]!=0) $fatal(1,"cold Voice result");
                if(record_index<voices(ps_frames)*4) begin
                    if(write_data[63]) $fatal(1,"send/mixer order");
                end else if(!write_data[63] || write_data[45:40]!=record_index-voices(ps_frames)*4)
                    $fatal(1,"mixer index");
                if(record_index==voices(ps_frames)*4+63) begin record_index<=0;ps_frames<=ps_frames+1;end
                else record_index<=record_index+1;
            end
            if(sample_valid && sample_ready) returned<=returned+1;
            audio_start<=0;
            if(!audio_started && (audio_level>=32 || returned==TOTAL)) begin audio_started<=1;audio_start<=1;end
            if(!audio_started && played) $fatal(1,"audio before prefill");
        end
    end
    always @(posedge audio_clk) begin
        #1;
        if(!audio_reset && audio_accepted) begin
            if(native_left!==0 || native_right!==0 || played>=TOTAL) $fatal(1,"returned PCM");
            played=played+1;
        end
    end
    task word(input logic [63:0] value);
        begin
            @(negedge clk);command_valid=1;command_data=value;
            @(posedge clk);while(!command_ready) @(posedge clk);
            @(negedge clk);command_valid=0;
        end
    endtask
    initial begin
        repeat(64) @(negedge clk);rst=0;audio_reset=0;
        wait(ready);@(negedge clk);start=1;@(negedge clk);start=0;
        for(integer n=0;n<TOTAL;n=n+1) begin
            memory[n%32][0]=64'h31414d4438384353;memory[n%32][1]=n;memory[n%32][2]=32;memory[n%32][3]=0;
            word(64'h53434431 | (n==TOTAL-1 ? 64'h200000000 : 0));word(64'(n));
            word((64'd32<<32) | (32'h12000000+(n%32)*16384));word(0);
            word(64'h1f00 | (voices(n)-1));word(0);word(0);word(0);
        end
        wait(ended);repeat(10) @(negedge clk);
        if(completed!=TOTAL || written!=TOTAL || ps_frames!=TOTAL || returned!=TOTAL || played!=TOTAL ||
           !wave_idle || mute_n || issued<TOTAL || responded!=issued || parameter_bursts!=TOTAL || parameter_configs || parameter_packets)
            $fatal(1,"integrated completion");
        if(TOTAL>32 && (!max_due_cycles || max_due_cycles>3125)) $fatal(1,"due deadline");
        $display("PARAMETER_SYNTH_PASS frames=%0d bursts=%0d max_core=%0d max_due=%0d",played,parameter_bursts,max_frame_cycles,max_due_cycles);
        $finish;
    end
    initial begin #20000000;$fatal(1,"watchdog completed=%0d written=%0d returned=%0d played=%0d",completed,written,returned,played);end
endmodule

module tb_parameter_synth_short;
    tb_parameter_synth #(.TOTAL(1)) test();
endmodule
