set root [file normalize [file join [file dirname [info script]] ../..]]
foreach table {xp3_interpolation} {
    file copy -force [file join $root hardware/rtl/${table}.mem] [file join [pwd] ${table}.mem]
}
create_project -in_memory -part xc7z010clg400-1
foreach unit {xp3_sample_pkg xp3_voice_state xp3_interpolate xp3_wave_source xp3_filter_tva xp3_pair_filter xp3_parameter_voice} {
    read_verilog -sv [file join $root hardware/rtl/${unit}.sv]
}
synth_design -top xp3_parameter_voice -part xc7z010clg400-1 -mode out_of_context
report_utilization -hierarchical -file xp3_parameter_voice_synthesis.rpt
set lut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set ff [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set dsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
set bram [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]] + 2*[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]}]
puts "VOICE_SYNTHESIS lut=$lut ff=$ff dsp=$dsp bram18=$bram"
if {$lut>12000 || $ff>16000 || $dsp>32 || $bram>24} { error "Voice core exceeds the Phase 2 resource budget" }
create_clock -name core_clk -period 10 [get_ports clk]
opt_design
place_design
route_design
report_utilization -hierarchical -file xp3_parameter_voice_utilization.rpt
report_timing_summary -max_paths 10 -file xp3_parameter_voice_timing.rpt
report_drc -file xp3_parameter_voice_drc.rpt
write_checkpoint -force xp3_parameter_voice.dcp
set paths [get_timing_paths -max_paths 1 -setup]
if {[llength $paths]!=1} { error "No core timing path" }
set slack [get_property SLACK [lindex $paths 0]]
puts "VOICE_IMPLEMENTED setup_slack=$slack"
if {$slack<0} { error "Voice core failed the 10 ns internal timing target" }
puts "VOICE_IMPLEMENTATION_COMPLETE"
