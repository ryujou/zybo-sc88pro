set root [file normalize [file join [file dirname [info script]] ../..]]
file copy -force [file join $root hardware/rtl/xp3_interpolation.mem] [file join [pwd] xp3_interpolation.mem]
file copy -force [file join $root hardware/rtl/xp3_pitch.mem] [file join [pwd] xp3_pitch.mem]
set tops $argv
if {[llength $tops] == 0} { set tops {xp3_filter_tva xp3_interpolate xp3_voice_state xp3_pair_filter xp3_ramp_math xp3_control_math xp3_ramp_service xp3_wave_source xp3_source_control} }
foreach top $tops {
    create_project -in_memory -part xc7z010clg400-1
    read_verilog -sv [file join $root hardware/rtl/xp3_sample_pkg.sv]
    if {$top eq "xp3_wave_source"} { read_verilog -sv [file join $root hardware/rtl/xp3_interpolate.sv] }
    if {$top eq "xp3_pair_filter"} { read_verilog -sv [file join $root hardware/rtl/xp3_filter_tva.sv] }
    if {$top eq "xp3_ramp_service" || $top eq "xp3_source_control"} {
        read_verilog -sv [file join $root hardware/rtl/xp3_ramp_math.sv]
        read_verilog -sv [file join $root hardware/rtl/xp3_control_math.sv]
    }
    read_verilog -sv [file join $root hardware/rtl/${top}.sv]
    synth_design -top $top -part xc7z010clg400-1 -mode out_of_context
    if {$top eq "xp3_voice_state"} {
        set ram18 [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
        set ram36 [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
        if {$ram18 + 2*$ram36 != 8} { error "Voice state did not map to eight BRAM18 equivalents" }
    }
    create_clock -name core_clk -period 10 [get_ports clk]
    opt_design
    place_design
    route_design
    report_utilization -hierarchical -file ${top}_utilization.rpt
    report_timing_summary -max_paths 10 -file ${top}_timing.rpt
    report_drc -file ${top}_drc.rpt
    write_checkpoint -force ${top}.dcp
    set paths [get_timing_paths -max_paths 1 -setup]
    if {[llength $paths] != 1} { error "No timing path for $top" }
    set slack [get_property SLACK [lindex $paths 0]]
    puts "VOICE_UNIT_IMPLEMENTED top=$top setup_slack=$slack"
    if {$slack < 0} { error "$top failed the 10 ns internal timing target" }
    close_project
}
puts "VOICE_UNITS_IMPLEMENTATION_COMPLETE scope=components_only"
