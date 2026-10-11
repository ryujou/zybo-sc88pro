set root [file normalize [file join [file dirname [info script]] ../..]]
if {$argc!=1 || [lindex $argv 0] ni {1 8 32 64}} {error "Expected Voice level 1, 8, 32 or 64"}
set voices [lindex $argv 0]
foreach table {xp3_interpolation} {
    file copy -force [file join $root hardware/rtl/${table}.mem] [file join [pwd] ${table}.mem]
}
# Component OOC synthesis avoids Vivado 2025.2 cross-module optimization crashes.
set partitions {xp3_parameter_voice pcm_parameter_dma pcm_mixer pcm_frame_fifo pcm_sample_fetcher pcm_sample_cache}
foreach unit $partitions {
    if {$voices==1} {
    create_project -in_memory -part xc7z010clg400-1
    if {$unit eq "xp3_parameter_voice"} {
        foreach dep {xp3_sample_pkg xp3_voice_state xp3_interpolate xp3_wave_source xp3_filter_tva xp3_pair_filter} {
            read_verilog -sv [file join $root hardware/rtl/${dep}.sv]
        }
    }
    read_verilog -sv [file join $root hardware/rtl/${unit}.sv]
    if {$unit eq "pcm_sample_fetcher"} {
        synth_design -top $unit -generic TAG_BITS=11 -part xc7z010clg400-1 -mode out_of_context
    } else {
        synth_design -top $unit -part xc7z010clg400-1 -mode out_of_context
    }
    write_checkpoint -force ${unit}_synthesis.dcp
    close_project
    } else {
        file copy -force [file join $root build/verification/offline-player/phase-03/voices-1-implementation/${unit}_synthesis.dcp] ${unit}_synthesis.dcp
    }
    set source_file [open [file join $root hardware/rtl/${unit}.sv] r]
    set source_text [read $source_file]
    close $source_file
    set header_end [string first ");" $source_text]
    set stub [string range $source_text 0 [expr {$header_end+1}]]
    set stub [string map [list "module $unit" "(* black_box *) module $unit"] $stub]
    set stub_file [open ${unit}_stub.sv w]
    puts $stub_file "$stub\nendmodule"
    close $stub_file
}
create_project -in_memory -part xc7z010clg400-1
foreach unit $partitions {read_verilog -sv ${unit}_stub.sv}
read_verilog -sv [file join $root hardware/rtl/pcm_parameter_voice_scheduler.sv]
synth_design -top pcm_parameter_voice_scheduler -generic VOICE_LIMIT=$voices -part xc7z010clg400-1 -mode out_of_context
write_checkpoint -force parameter_scheduler_shell.dcp
close_project
create_project -in_memory -part xc7z010clg400-1
add_files parameter_scheduler_shell.dcp
foreach {cell unit} {voice_core xp3_parameter_voice parameters pcm_parameter_dma mixer pcm_mixer results pcm_frame_fifo fetcher pcm_sample_fetcher cache pcm_sample_cache} {
    add_files ${unit}_synthesis.dcp
    set_property SCOPED_TO_CELLS $cell [get_files ${unit}_synthesis.dcp]
}
link_design -top pcm_parameter_voice_scheduler -part xc7z010clg400-1
if {[llength [get_cells -hier -filter {IS_BLACKBOX == 1}]]!=0} {error "Integrated design contains an unresolved black box"}
report_utilization -hierarchical -file pcm_parameter_voice_scheduler_synthesis.rpt
create_clock -name core_clk -period 10 [get_ports clk]
opt_design
report_utilization -hierarchical -file pcm_parameter_voice_scheduler_optimized.rpt
write_checkpoint -force pcm_parameter_voice_scheduler_optimized.dcp
set lut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set ff [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set dsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
set bram [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]] + 2*[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]}]
puts "MULTIVOICE_SYNTHESIS voices=$voices lut=$lut ff=$ff dsp=$dsp bram18=$bram"
if {$lut>16000 || $ff>30000 || $dsp>64 || $bram>100} {error "Phase 3 resource budget exceeded"}
set cache_bram [get_cells -hier -filter {NAME =~ *cache* && (REF_NAME =~ RAMB18* || REF_NAME =~ RAMB36*)}]
if {[llength $cache_bram]==0} {error "Sample cache data did not infer BRAM"}
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
if {[get_property SLACK [get_timing_paths -max_paths 1 -setup]]<0} {
    phys_opt_design -placement_opt
    route_design -directive Explore
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -setup]]<0} {
    phys_opt_design -rewire -placement_opt
    route_design -directive Explore
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -setup]]<0} {
    phys_opt_design -routing_opt -critical_pin_opt
    route_design -directive Explore
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -setup]]<0} {
    route_design -unroute
    route_design -directive NoTimingRelaxation
}
report_utilization -hierarchical -file pcm_parameter_voice_scheduler_utilization.rpt
report_timing_summary -max_paths 10 -file pcm_parameter_voice_scheduler_timing.rpt
report_timing -max_paths 20 -path_type full -file pcm_parameter_voice_scheduler_paths.rpt
report_drc -file pcm_parameter_voice_scheduler_drc.rpt
write_checkpoint -force pcm_parameter_voice_scheduler.dcp
set paths [get_timing_paths -max_paths 1 -setup]
if {[llength $paths]!=1} {error "No scheduler timing path"}
set slack [get_property SLACK [lindex $paths 0]]
puts "MULTIVOICE_IMPLEMENTED voices=$voices setup_slack=$slack"
if {$slack<0} {error "Multi-Voice core failed the 10 ns target"}
puts "MULTIVOICE_IMPLEMENTATION_COMPLETE voices=$voices"
