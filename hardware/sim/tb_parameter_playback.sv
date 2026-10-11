// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
module tb_parameter_playback #(parameter integer TOTAL=65);
    tb_parameter_board #(.PLAYBACK(1)) test();
    logic [63:0] commands[0:1023],parameters[0:65535],results[0:16383],audio[0:1023];
    integer cycle=0,block_left=0,wave_left=0,audio_left=0,write_left=0;
    integer block_pos=0,wave_pos=0,audio_pos=0,write_pos=0;
    integer played=0,processed=0,submitted=0,returned=0;
    integer input_slot=0,output_slot=0,release_slot=0,blocks_count=0;
    integer count,first,records,owner,level;
    logic [63:0] mixed;
    logic audio_started=0,playing=0;
    always @(negedge test.clk) begin
        test.m_block_arready=block_left==0 && !test.m_block_rvalid && cycle%5!=0;
        test.m_wave_arready=wave_left==0 && !test.m_wave_rvalid && cycle%7!=0;
        test.m_audio_arready=audio_left==0 && !test.m_audio_rvalid && cycle%3!=0;
        test.m_block_awready=write_left==0 && !test.m_block_bvalid;
        test.m_block_wready=write_left!=0 && cycle%11!=0;
    end
    always @(posedge test.clk) begin
        cycle<=cycle+1;
        if(test.resetn) begin
            if(test.m_block_arvalid && test.m_block_arready) begin
                if(test.m_block_araddr<32'h05000000 || test.m_block_araddr>=32'h05002000 || test.m_block_arsize!=3)
                    $fatal(1,"command DDR address");
                block_pos=(test.m_block_araddr-32'h05000000)>>3;block_left=test.m_block_arlen+1;
            end
            if(test.m_block_rvalid && test.m_block_rready) begin
                test.m_block_rvalid<=0;block_pos=block_pos+1;block_left=block_left-1;
            end else if(!test.m_block_rvalid && block_left && cycle%3!=0) begin
                test.m_block_rvalid<=1;test.m_block_rdata<=commands[block_pos];test.m_block_rlast<=block_left==1;
            end
            if(test.m_wave_arvalid && test.m_wave_arready) begin
                if(!((test.m_wave_araddr>=32'h12000000 && test.m_wave_araddr<32'h12080000) ||
                     (test.m_wave_araddr>=32'h10000000 && test.m_wave_araddr<32'h11400000)) || test.m_wave_arlen!=3)
                    $fatal(1,"cold parameter DDR address");
                wave_pos=test.m_wave_araddr>=32'h12000000 ? (test.m_wave_araddr-32'h12000000)>>3 : -1;wave_left=4;
            end
            if(test.m_wave_rvalid && test.m_wave_rready) begin
                test.m_wave_rvalid<=0;if(wave_pos>=0) wave_pos=wave_pos+1;wave_left=wave_left-1;
            end else if(!test.m_wave_rvalid && wave_left && cycle%4!=0) begin
                test.m_wave_rvalid<=1;test.m_wave_rdata<=wave_pos>=0 ? parameters[wave_pos] : 0;test.m_wave_rlast<=wave_left==1;
            end
            if(test.m_audio_arvalid && test.m_audio_arready) begin
                if(test.m_audio_araddr<32'h07000000 || test.m_audio_araddr>=32'h07002000 || test.m_audio_arsize!=3)
                    $fatal(1,"return DDR address");
                audio_pos=(test.m_audio_araddr-32'h07000000)>>3;audio_left=test.m_audio_arlen+1;
            end
            if(test.m_audio_rvalid && test.m_audio_rready) begin
                test.m_audio_rvalid<=0;audio_pos=audio_pos+1;audio_left=audio_left-1;returned=returned+1;
            end else if(!test.m_audio_rvalid && audio_left && cycle%5!=0) begin
                test.m_audio_rvalid<=1;test.m_audio_rdata<=audio[audio_pos];test.m_audio_rlast<=audio_left==1;
            end
            if(test.m_block_awvalid && test.m_block_awready) begin
                if(test.m_block_awaddr<32'h06000000 || test.m_block_awaddr>=32'h06020000 || test.m_block_awsize!=3)
                    $fatal(1,"result DDR address");
                write_pos=(test.m_block_awaddr-32'h06000000)>>3;write_left=test.m_block_awlen+1;
            end
            if(test.m_block_wvalid && test.m_block_wready) begin
                if(test.m_block_wstrb!=255 || test.m_block_wlast!=(write_left==1)) $fatal(1,"result AXI burst");
                results[write_pos]=test.m_block_wdata;write_pos=write_pos+1;write_left=write_left-1;
                if(!write_left) test.m_block_bvalid<=1;
            end else if(test.m_block_bvalid && test.m_block_bready) test.m_block_bvalid<=0;
            if(playing && test.dut.fault) $fatal(1,"playback fault=%h completed=%0d returned=%0d",test.dut.fault,processed,returned);
        end
    end
    always @(posedge test.audio_clk) begin
        #1;
        if(test.dut.synth.audio_accepted) begin
            if(test.dut.synth.native_left!==0 || test.dut.synth.native_right!==0 || played>=TOTAL)
                $fatal(1,"cold PCM mismatch");
            played=played+1;
        end
    end
    task publish(input integer slot,input integer frame,input integer frames);
        begin
            for(integer n=0;n<frames;n=n+1) begin
                parameters[(slot*16+n)*2048]=64'h31414d4438384353;
                parameters[(slot*16+n)*2048+1]=frame+n;
                parameters[(slot*16+n)*2048+2]=32;
                parameters[(slot*16+n)*2048+3]=0;
                commands[slot*512+n*8]=64'h53434431 | (frame+n==TOTAL-1 ? 64'h200000000 : 0);
                commands[slot*512+n*8+1]=frame+n;
                commands[slot*512+n*8+2]=(64'd32<<32) | (32'h12000000+(slot*16+n)*16384);
                commands[slot*512+n*8+3]=0;commands[slot*512+n*8+4]=64'h1f3f;
                commands[slot*512+n*8+5]=0;commands[slot*512+n*8+6]=0;commands[slot*512+n*8+7]=0;
            end
            test.write_reg(12'('h100+slot*32),32'h05000000+slot*4096);
            test.write_reg(12'('h104+slot*32),frames*64);
            test.write_reg(12'('h108+slot*32),32'h06000000+slot*65536);
            test.write_reg(12'('h10c+slot*32),frames*2560);
            test.write_reg(12'('h110+slot*32),frames);
            test.write_reg(12'('h114+slot*32),frame);test.write_reg(12'('h118+slot*32),0);
            test.write_reg(12'('h11c+slot*32),frame+frames==TOTAL ? 257 : 1);
            submitted=submitted+frames;
        end
    endtask
    initial begin
        test.resetn=0;test.audio_reset=1;
        repeat(64) @(negedge test.clk);test.resetn=1;test.audio_reset=0;test.wait_ready();
        count=TOTAL<16 ? TOTAL : 16;publish(0,0,count);
        if(TOTAL>16) begin count=TOTAL-16<16 ? TOTAL-16 : 16;publish(1,16,count);end
        test.write_reg(4,1);playing=1;
        while(processed<TOTAL || played<TOTAL) begin
            test.read_reg('h88);owner=test.value;
            for(integer n=0;n<2;n=n+1) begin
                if(((owner>>(release_slot*2))&3)==3) begin
                    test.write_reg(12'('h19c+release_slot*32),2);release_slot=release_slot^1;
                end
            end
            test.read_reg('h80);owner=test.value;
            test.read_reg('h88);
            if(processed<TOTAL && ((owner>>(input_slot*2))&3)==3 && ((test.value>>(output_slot*2))&3)==0) begin
                count=TOTAL-processed<16 ? TOTAL-processed : 16;
                for(integer n=0;n<count;n=n+1) begin
                    for(integer r=0;r<320;r=r+1) begin
                        mixed=results[input_slot*8192+n*320+r];
                        if(mixed[24:0]!==0 || mixed[63]!=(r>=256)) $fatal(1,"ordered cold result");
                        if(r>=256 && mixed[45:40]!=(r-256)) $fatal(1,"mixer cell order");
                    end
                    // Mock PS consumes all ordered results, then returns the selected direct cells.
                    audio[output_slot*512+n]={8'd0,results[input_slot*8192+n*320+257][23:0],
                                             8'd0,results[input_slot*8192+n*320+256][23:0]};
                end
                test.write_reg(12'('h180+output_slot*32),32'h07000000+output_slot*4096);
                test.write_reg(12'('h184+output_slot*32),count*8);test.write_reg(12'('h188+output_slot*32),0);
                test.write_reg(12'('h18c+output_slot*32),0);test.write_reg(12'('h190+output_slot*32),count);
                test.write_reg(12'('h194+output_slot*32),processed);test.write_reg(12'('h198+output_slot*32),0);
                test.write_reg(12'('h19c+output_slot*32),processed+count==TOTAL ? 257 : 1);
                test.write_reg(12'('h11c+input_slot*32),2);
                processed=processed+count;blocks_count=blocks_count+1;output_slot=output_slot^1;
                if(submitted<TOTAL) begin count=TOTAL-submitted<16 ? TOTAL-submitted : 16;publish(input_slot,submitted,count);end
                input_slot=input_slot^1;
            end
            if(!audio_started) begin
                test.read_reg('h3c);level=test.value;test.read_reg('h8c);
                if(level>=32 || (level && test.value)) begin test.write_reg(4,16);audio_started=1;end
            end
        end
        test.read_reg(8);while(!test.value[4]) test.read_reg(8);
        test.read_reg('h18);if(test.value!=TOTAL || submitted!=TOTAL || returned!=TOTAL) $fatal(1,"frame accounting");
        test.read_reg('h1c);if(test.value>3125) $fatal(1,"late frame");
        if(test.mute_n) $fatal(1,"end still audible");
        $display("PARAMETER_PLAYBACK_PASS frames=%0d blocks=%0d accesses=%0d max_due=%0d",played,blocks_count,test.checks,test.value);
        $finish;
    end
endmodule

module tb_parameter_playback_short;
    tb_parameter_playback #(.TOTAL(1)) test();
endmodule
