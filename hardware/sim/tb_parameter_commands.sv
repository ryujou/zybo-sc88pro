// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_parameter_commands;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,start=0,stop=0,pause=0,due=0;
    logic [63:0] first_frame=900,command_data=0;
    logic command_valid=0,command_ready,parameter_desc_valid,parameter_desc_ready;
    logic [63:0] parameter_desc_frame,frame_id,frame_descriptors;
    logic [31:0] parameter_desc_address,frame_bank_shifts,completed,max_due_cycles;
    logic [14:0] parameter_desc_bytes;
    logic frame_valid,frame_ready,metadata_ready,metadata_valid;
    logic [5:0] frame_highest_voice;
    logic [15:0] frame_irq_status,frame_irq_mask,done_irq_status=0;
    logic frame_irq_interrupt,frame_last,done_irq_interrupt=0;
    logic [7:0] frame_physical16;
    logic done_valid=0,done_ready,running,ended,busy;
    logic [63:0] done_frame=0;
    logic [3:0] error;
    pcm_parameter_commands dut(.*);
    integer cycle=0,launches=0,parameters=0,ticks=0,delay_count=0,checks=0;
    integer wanted=96,negative_checks=0,reset_checks=0,prefetched_busy=0;
    logic automatic_core=1,allow_parameter=1,allow_frame=1,allow_metadata=1,automatic_due=0;
    logic offline_test=0;
    integer due_wait=0,last_due_completed=0;
    logic [15:0] expected_irq=0;
    logic expected_interrupt=0;
    logic held_parameter=0,held_frame=0;
    logic [110:0] saved_parameter;
    logic [207:0] saved_frame;
    wire [207:0] observed_frame={frame_id,frame_descriptors,frame_highest_voice,frame_irq_status,
        frame_irq_mask,frame_irq_interrupt,frame_last,frame_physical16,frame_bank_shifts};
    assign parameter_desc_ready=allow_parameter && cycle%5!=0;
    assign frame_ready=allow_frame && cycle%7!=0;
    assign metadata_ready=allow_metadata && cycle%11!=0;

    function automatic [63:0] word(input integer n,input integer w,input logic last);
        case(w)
            0:word=64'h53434431 | ((n%3==1)?64'h100000000:0) | (last?64'h200000000:0);
            1:word=first_frame+n;
            2:word=((64'd32+(n%16)*32)<<32) | (32'h12000000+(n%32)*16384);
            3:word=64'h76543210fedcba98 ^ n;
            4:word=((64'h8123 ^ n)<<16) | 64'h1f00 | (n%64);
            default:word=0;
        endcase
    endfunction

    always @(posedge clk) begin
        cycle<=cycle+1;
        if(rst) begin
            launches<=0;parameters<=0;ticks<=0;delay_count<=0;done_valid<=0;
            expected_irq<=0;expected_interrupt<=0;held_parameter<=0;held_frame<=0;
            prefetched_busy<=0;
        end else begin
            if(error==0 && running && !stop) begin
                if(held_parameter && {parameter_desc_frame,parameter_desc_address,parameter_desc_bytes}!=saved_parameter)
                    $fatal(1,"unstable parameter descriptor");
                if(held_frame && observed_frame!=saved_frame) $fatal(1,"unstable frame metadata");
            end
            held_parameter<=parameter_desc_valid && !parameter_desc_ready;
            saved_parameter<={parameter_desc_frame,parameter_desc_address,parameter_desc_bytes};
            held_frame<=frame_valid && !frame_ready;
            saved_frame<=observed_frame;
            if(metadata_valid!=(frame_valid && frame_ready)) $fatal(1,"metadata handshake");
            if(parameter_desc_valid && parameter_desc_ready) begin
                if(parameter_desc_frame!=first_frame+parameters ||
                   parameter_desc_address!=32'h12000000+(parameters%32)*16384 ||
                   parameter_desc_bytes!=32+(parameters%16)*32) $fatal(1,"parameter fields");
                parameters<=parameters+1;
                if(busy) prefetched_busy<=prefetched_busy+1;
            end
            if(frame_valid && frame_ready) begin
                if(busy || parameters<=launches || (!offline_test && launches>=32+ticks) || pause || !metadata_ready)
                    $fatal(1,"frame admitted without ownership/credit");
                if(frame_id!=first_frame+launches || frame_descriptors!=(64'h76543210fedcba98 ^ launches) ||
                   frame_highest_voice!=launches%64 || frame_irq_mask!=(16'h8123 ^ launches) ||
                   frame_physical16!=8'h1f || frame_bank_shifts || frame_last!=(launches==wanted-1))
                    $fatal(1,"frame fields at %0d",launches);
                if(frame_irq_status!=expected_irq || frame_irq_interrupt!=(expected_interrupt && launches%3!=1))
                    $fatal(1,"IRQ chain at %0d",launches);
                launches<=launches+1;
                if(automatic_core) begin
                    delay_count<=40;done_frame<=frame_id;
                    done_irq_status<=frame_irq_status+16'h107;done_irq_interrupt<=!launches[0];
                end
            end
            if(automatic_core) begin
                if(delay_count>0) begin delay_count<=delay_count-1;if(delay_count==1) done_valid<=1;end
                if(done_valid && done_ready) begin
                    done_valid<=0;expected_irq<=done_irq_status;expected_interrupt<=done_irq_interrupt;
                end
            end
            if(due && running) ticks<=ticks+1;
        end
    end
    always @(negedge clk) begin
        if(automatic_due) begin
            due=0;
            if(completed>=32 && completed<wanted && completed!=last_due_completed) begin
                due_wait=due_wait+1;
                if(due_wait==25) begin due=1;last_due_completed=completed;due_wait=0;end
            end
        end
    end
    task reset_start;
        begin
            @(negedge clk);rst=1;start=0;stop=0;pause=0;due=0;command_valid=0;
            automatic_due=0;automatic_core=1;allow_parameter=1;allow_frame=1;allow_metadata=1;
            offline_test=0;
            due_wait=0;last_due_completed=0;
            repeat(4) @(negedge clk);rst=0;start=1;@(negedge clk);start=0;
        end
    endtask
    task send(input logic [63:0] value);
        begin
            @(negedge clk);command_data=value;command_valid=1;
            @(posedge clk);while(!command_ready) begin
                if(error) $fatal(1,"unexpected fault %0d",error);
                @(posedge clk);
            end
            @(negedge clk);command_valid=0;
        end
    endtask
    task descriptor(input integer n,input logic last);
        for(integer w=0;w<8;w=w+1) send(word(n,w,last));
    endtask
    task bad(input integer index,input logic [63:0] value);
        begin
            reset_start();
            for(integer w=0;w<index;w=w+1) send(word(0,w,0));
            send(value);repeat(3) @(negedge clk);
            if(error!=1 || command_ready || parameter_desc_valid || frame_valid || parameters || launches)
                $fatal(1,"bad descriptor accepted at word %0d",index);
            negative_checks=negative_checks+1;
        end
    endtask
    task tick_once;
        begin @(negedge clk);due=1;@(negedge clk);due=0;end
    endtask
    initial begin
        reset_start();automatic_due=1;
        for(integer n=0;n<96;n=n+1) descriptor(n,n==95);
        wait(ended);@(negedge clk);
        if(error || running || completed!=96 || launches!=96 || ticks!=64 || !prefetched_busy || !max_due_cycles)
            $fatal(1,"normal stream completion");
        $display("PARAMETER_COMMAND_STREAM frames=%0d ticks=%0d prefetch=%0d max_mock_due=%0d",
            completed,ticks,prefetched_busy,max_due_cycles);checks=checks+1;
        automatic_due=0;
        reset_start();
        offline_test=1;
        for(integer n=0;n<96;n=n+1) begin
            send(word(n,0,n==95) | 64'h400000000);
            for(integer w=1;w<8;w=w+1) send(word(n,w,n==95));
            repeat(4000) @(negedge clk);
        end
        wait(ended);
        if(error || completed!=96 || max_due_cycles) $fatal(1,"offline stream needs audio credits");
        checks=checks+1;
        wanted=1;reset_start();allow_parameter=0;descriptor(0,1);
        repeat(20) @(negedge clk);
        if(parameters || launches || !parameter_desc_valid) $fatal(1,"parameter backpressure");
        allow_parameter=1;allow_metadata=0;wait(parameters==1);repeat(20) @(negedge clk);
        if(launches || frame_valid) $fatal(1,"metadata backpressure");
        allow_metadata=1;pause=1;repeat(20) @(negedge clk);
        if(launches || frame_valid) $fatal(1,"pause admission");
        pause=0;wait(ended);if(error || completed!=1) $fatal(1,"short stream");checks=checks+1;
        for(integer w=0;w<8;w=w+1) begin
            reset_start();for(integer i=0;i<w;i=i+1) send(word(0,i,1));
            reset_start();descriptor(0,1);wait(ended);
            if(error || completed!=1) $fatal(1,"partial descriptor reset");reset_checks=reset_checks+1;
        end
        bad(0,64'h53434430);bad(0,64'h853434431);bad(1,901);
        bad(2,64'h0000002011ffc000);bad(2,64'h0000002012080000);
        bad(2,64'h0000002012000020);bad(2,64'h0000000012000000);
        bad(2,64'h0000402012000000);bad(2,64'h0000002112000000);
        bad(4,64'h1f40);bad(4,64'h1e00);bad(4,64'h100001f00);
        bad(5,1);bad(6,1);bad(7,1);
        wanted=96;reset_start();automatic_core=0;descriptor(0,0);wait(busy);
        @(negedge clk);done_frame=901;done_valid=1;@(negedge clk);
        if(error!=2) $fatal(1,"wrong completion frame");checks=checks+1;
        reset_start();automatic_core=0;descriptor(0,0);wait(busy);
        @(negedge clk);stop=1;@(negedge clk);stop=0;start=1;@(negedge clk);start=0;
        if(running || command_ready || parameter_desc_valid || frame_valid || done_ready || ended)
            $fatal(1,"stop/restart requires reset");checks=checks+1;
        reset_start();tick_once();if(error!=3) $fatal(1,"credit overflow");checks=checks+1;
        reset_start();descriptor(0,0);wait(completed==1);tick_once();
        repeat(3125) @(negedge clk);
        if(error) $fatal(1,"deadline fired early");
        @(negedge clk);if(error!=3 || frame_valid || command_ready) $fatal(1,"starvation deadline");checks=checks+1;
        reset_start();descriptor(0,0);descriptor(1,0);wait(completed==2);
        tick_once();repeat(5) @(negedge clk);tick_once();
        if(error!=3) $fatal(1,"overlapping due");checks=checks+1;
        $display("PARAMETER_COMMANDS_PASS checks=%0d negatives=%0d resets=%0d",checks,negative_checks,reset_checks);
        $finish;
    end
    initial begin #20000000;$fatal(1,"watchdog");end
endmodule
