// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_return_audio;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,run=0,stop=0,submit=0,submit_slot=0,last_block=0,acknowledge=0,ack_slot=0;
    logic [31:0] address=32'h07000000;
    logic [4:0] frame_count=16;
    logic [63:0] first_frame=400,sample_frame;
    wire submit_error,acknowledge_error,finished,idle,sample_valid;
    wire [3:0] ownership,error;
    wire [1:0] completion;
    wire [31:0] frames;
    logic sample_ready;
    wire signed [23:0] sample_left,sample_right;
    wire m_axi_arvalid,m_axi_rready;
    logic m_axi_arready,m_axi_rvalid=0,m_axi_rlast=0;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    logic [63:0] m_axi_rdata=0;
    logic [5:0] m_axi_rid=0;
    logic [1:0] m_axi_rresp=0;
    pcm_return_audio dut(.*);
    integer cycle=0,reads=0,beat=0,amount=0,base=0,delay_count=0,accepted=0,completions=0;
    integer checks=0,negative_checks=0,mode=0;
    logic pending=0,allow_ar=1,allow_response=1;
    logic held=0;
    logic [111:0] saved;
    function automatic [23:0] left_value(input integer n);left_value=24'(32'hfedcab+n*98761);endfunction
    function automatic [23:0] right_value(input integer n);right_value=24'(32'h812345-n*43211);endfunction
    assign m_axi_arready=allow_ar && !pending && cycle%5!=0;
    assign sample_ready=cycle%13<7;
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(rst) begin
            reads<=0;beat<=0;amount<=0;base<=0;delay_count<=0;accepted<=0;completions<=0;pending<=0;
            m_axi_rvalid<=0;m_axi_rdata<=0;m_axi_rlast<=0;m_axi_rid<=0;m_axi_rresp<=0;held<=0;
        end else begin
            if(m_axi_arvalid && m_axi_arready) begin
                if(m_axi_araddr!=(reads%2 ? 32'h07001000 : 32'h07000000) || m_axi_arlen>15)
                    $fatal(1,"return DMA address");
                pending<=1;amount<=int'(m_axi_arlen)+1;beat<=0;base<=reads*16;reads<=reads+1;delay_count<=4;
            end
            if(delay_count>0) delay_count<=delay_count-1;
            if(pending && !m_axi_rvalid && delay_count==0 && cycle%7!=0 && allow_response) begin
                m_axi_rvalid<=1;m_axi_rlast<=beat==amount-1 || mode==3;
                m_axi_rid<=mode==1 ? 1 : 0;m_axi_rresp<=mode==2 ? 2 : 0;
                m_axi_rdata<={{8{right_value(base+beat)[23]}},right_value(base+beat),
                              {8{left_value(base+beat)[23]}},left_value(base+beat)};
                if(mode==4) m_axi_rdata<=64'h0080000000000000;
            end
            if(m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid<=0;beat<=beat+1;
                if(m_axi_rlast) pending<=0;
            end
            if(!stop && !error && held && {sample_frame,sample_left,sample_right}!=saved)
                $fatal(1,"unstable audio under backpressure");
            held<=sample_valid && !sample_ready;saved<={sample_frame,sample_left,sample_right};
            if(sample_valid && sample_ready) begin
                if(mode || sample_frame!=400+accepted || sample_left!=left_value(accepted) || sample_right!=right_value(accepted))
                    $fatal(1,"returned audio/frame mismatch at %0d",accepted);
                accepted<=accepted+1;
            end
            if(completion) begin
                if(completion!=(completions%2 ? 2'b10 : 2'b01)) $fatal(1,"audio completion order");
                completions<=completions+1;
            end
        end
    end
    task reset_all;
        begin
            @(negedge clk);rst=1;run=0;stop=0;submit=0;acknowledge=0;allow_ar=1;allow_response=1;mode=0;
            repeat(4) @(negedge clk);rst=0;
        end
    endtask
    task descriptor(input integer n,input integer count,input logic last);
        begin
            @(negedge clk);submit_slot=1'(n%2);address=n%2 ? 32'h07001000 : 32'h07000000;
            frame_count=5'(count);first_frame=400+n*16;last_block=last;
            #1;if(submit_error) $fatal(1,"valid audio descriptor rejected");
            submit=1;@(negedge clk);submit=0;
        end
    endtask
    task ack(input logic slot);
        begin
            @(negedge clk);ack_slot=slot;#1;
            if(acknowledge_error) $fatal(1,"audio reuse before complete");
            acknowledge=1;@(negedge clk);acknowledge=0;
        end
    endtask
    initial begin
        reset_all();descriptor(0,16,0);descriptor(1,16,0);run=1;
        wait(reads==1);ack_slot=0;#1;if(!acknowledge_error) $fatal(1,"early release");checks=checks+1;
        for(integer n=2;n<8;n=n+1) begin
            wait(ownership[(n%2)*2+:2]==3);ack(1'(n%2));descriptor(n,n==7 ? 5 : 16,n==7);
        end
        wait(finished);repeat(4) @(negedge clk);
        if(error || frames!=117 || accepted!=117 || completions!=8 || !idle) $fatal(1,"audio stream completion");
        ack(0);ack(1);if(ownership || m_axi_arvalid || sample_valid) $fatal(1,"audio final ownership");checks=checks+1;
        $display("RETURN_AUDIO_STREAM frames=%0d blocks=%0d",frames,completions);
        for(integer bad=1;bad<=5;bad=bad+1) begin
            reset_all();mode=bad;descriptor(0,16,1);run=1;
            if(bad==5) allow_response=0;
            wait(error!=0);repeat(4) @(negedge clk);
            if(finished || completion || sample_valid || ownership[1:0]!=2 || accepted) $fatal(1,"bad DMA exposed audio");
            if(error!=(bad==1 ? 4 : bad==2 ? 2 : bad==3 ? 3 : bad==4 ? 7 : 5)) $fatal(1,"wrong DMA fault %0d",error);
            allow_response=1;wait(idle);negative_checks=negative_checks+1;
        end
        reset_all();allow_ar=0;descriptor(0,16,1);run=1;
        wait(m_axi_arvalid);@(negedge clk);stop=1;
        repeat(5) @(negedge clk);
        if(!m_axi_arvalid || idle || sample_valid) $fatal(1,"cancel revoked exposed AR");
        allow_ar=1;wait(idle);repeat(3) @(negedge clk);
        if(!error || finished || completion || accepted || ownership[1:0]!=2) $fatal(1,"cancel ownership");checks=checks+1;
        reset_all();submit_slot=0;address=32'h07000008;frame_count=16;first_frame=400;last_block=0;
        #1;if(!submit_error) $fatal(1,"audio bad address");negative_checks=negative_checks+1;
        address=32'h07000000;frame_count=0;#1;if(!submit_error) $fatal(1,"audio zero count");negative_checks=negative_checks+1;
        frame_count=17;#1;if(!submit_error) $fatal(1,"audio long count");negative_checks=negative_checks+1;
        frame_count=16;submit_slot=1;#1;if(!submit_error) $fatal(1,"audio slot order");negative_checks=negative_checks+1;
        descriptor(0,16,0);submit_slot=1;address=32'h07001000;first_frame=417;
        #1;if(!submit_error) $fatal(1,"audio frame continuity");negative_checks=negative_checks+1;
        $display("RETURN_AUDIO_PASS checks=%0d negatives=%0d",checks,negative_checks);$finish;
    end
    initial begin #1000000;$fatal(1,"watchdog");end
endmodule
