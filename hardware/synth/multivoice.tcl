set root [file normalize [file join [file dirname [info script]] ../..]]
if {$argc!=1 || [lindex $argv 0] ni {1 8 32 64}} {error "Expected Voice level 1, 8, 32 or 64"}
set voices [lindex $argv 0]
foreach table {xp3_interpolation xp3_pitch} {
    file copy -force [file join $root hardware/rtl/${table}.mem] [file join [pwd] ${table}.mem]
}
create_project -in_memory -part xc7z010clg400-1
foreach unit {xp3_sample_pkg xp3_voice_state xp3_interpolate xp3_wave_source xp3_ramp_math xp3_control_math xp3_source_control xp3_ramp_service xp3_filter_tva xp3_pair_filter xp3_voice pcm_mixer pcm_frame_fifo pcm_sample_fetcher pcm_sample_cache pcm_voice_scheduler} {
    read_verilog -sv [file join $root hardware/rtl/${unit}.sv]
}
synth_design -top pcm_voice_scheduler -generic VOICE_LIMIT=$voices -part xc7z010clg400-1 -mode out_of_context
report_utilization -hierarchical -file pcm_voice_scheduler_synthesis.rpt
create_clock -name core_clk -period 10 [get_ports clk]
opt_design
report_utilization -hierarchical -file pcm_voice_scheduler_optimized.rpt
write_checkpoint -force pcm_voice_scheduler_optimized.dcp
set lut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set ff [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set dsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
set bram [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]] + 2*[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]}]
puts "MULTIVOICE_SYNTHESIS voices=$voices lut=$lut ff=$ff dsp=$dsp bram18=$bram"
if {$lut>16000 || $ff>30000 || $dsp>64 || $bram>100} {error "Phase 3 resource budget exceeded"}
set cache_bram [get_cells -hier -filter {NAME =~ *cache* && (REF_NAME =~ RAMB18* || REF_NAME =~ RAMB36*)}]
if {[llength $cache_bram]==0} {error "Sample cache data did not infer BRAM"}
place_design -directive Explore
route_design -directive Explore
if {[get_property SLACK [get_timing_paths -max_paths 1 -setup]]<0} {
    phys_opt_design -directive AggressiveExplore
    route_design -directive Explore
}
report_utilization -hierarchical -file pcm_voice_scheduler_utilization.rpt
report_timing_summary -max_paths 10 -file pcm_voice_scheduler_timing.rpt
report_drc -file pcm_voice_scheduler_drc.rpt
write_checkpoint -force pcm_voice_scheduler.dcp
set paths [get_timing_paths -max_paths 1 -setup]
if {[llength $paths]!=1} {error "No scheduler timing path"}
set slack [get_property SLACK [lindex $paths 0]]
puts "MULTIVOICE_IMPLEMENTED voices=$voices setup_slack=$slack"
if {$slack<0} {error "Multi-Voice core failed the 10 ns target"}
puts "MULTIVOICE_IMPLEMENTATION_COMPLETE voices=$voices"
