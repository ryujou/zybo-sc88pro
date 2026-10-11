# SPDX-License-Identifier: GPL-3.0-only
set script_dir [file normalize [file dirname [info script]]]
set root [file normalize [file join $script_dir ../..]]
set out [file join $root build/verification/phase-04/board]
file mkdir $out
set project_dir [file join $out project]
create_project sc88 $project_dir -part xc7z010clg400-1 -force
set_param general.maxThreads 8
set_property simulator_language Mixed [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
foreach unit {xp3_sample_pkg xp3_voice_state xp3_interpolate xp3_wave_source xp3_ramp_math xp3_control_math xp3_source_control xp3_ramp_service xp3_filter_tva xp3_pair_filter xp3_voice pcm_mixer pcm_frame_fifo pcm_sample_fetcher pcm_sample_cache pcm_voice_scheduler} {
    add_files -norecurse [file join $root hardware/rtl $unit.sv]
}
add_files -norecurse [glob [file join $script_dir *.sv]]
add_files -norecurse [file join $script_dir pcm_board_ip.v]
add_files -norecurse [list [file join $root hardware/rtl/xp3_pitch.mem] [file join $root hardware/rtl/xp3_interpolation.mem]]
update_compile_order -fileset sources_1
source [file join $script_dir zybo_ps7.tcl]
source [file join $script_dir design.tcl]
create_sc88_design
set bd_file [get_files sc88.bd]
generate_target all $bd_file
make_wrapper -files $bd_file -top
add_files -norecurse [file join $project_dir sc88.gen sources_1 bd sc88 hdl sc88_wrapper.v]
set_property top sc88_wrapper [current_fileset]
set constraints [file join $script_dir zybo.xdc]
add_files -fileset constrs_1 -norecurse $constraints
set_property PROCESSING_ORDER LATE [get_files $constraints]
set_property USED_IN_SYNTHESIS false [get_files $constraints]
update_compile_order -fileset sources_1
create_ip_run $bd_file
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Full board synthesis failed"}
open_run synth_1
report_utilization -file [file join $out utilization-synth.rpt]
report_utilization -hierarchical -file [file join $out utilization-synth-hierarchical.rpt]
close_design
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE ExploreArea [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Full board implementation failed"}
open_run impl_1
if {[get_property SLACK [get_timing_paths -max_paths 1 -setup]]<0} {
    phys_opt_design -directive AggressiveExplore
    route_design -directive Explore
}
if {[llength [get_pins -hierarchical -regexp {.*synth/audio/transmitter/bclk_reg/C}]]!=1} {error "Missing I2S BCLK source register"}
if {[llength [get_pins -hierarchical -regexp {.*synth/audio/(due_sync|fault_sync|pause_sync)_reg\[0\]/D}]]!=3} {error "Missing audio scalar synchronizers"}
foreach {port pin} {clk125 L16 ac_mclk T19 i2s_bclk K18 i2s_lrclk L17 i2s_data M17 ac_mute_n P18 IIC_0_scl_io N18 IIC_0_sda_io N17 led[0] M14 led[1] M15 led[2] G14 led[3] D18} {
    if {[get_property PACKAGE_PIN [get_ports $port]] ne $pin} {error "Missing board pin constraint: $port"}
}
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out utilization-hierarchical.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing-summary.rpt]
report_clock_interaction -file [file join $out clock-interaction.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_drc -file [file join $out drc.rpt]
report_methodology -file [file join $out methodology.rpt]
write_checkpoint -force [file join $out sc88-routed.dcp]
write_debug_probes -force [file join $out sc88.ltx]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup]!=1 || [llength $hold]!=1 || [get_property SLACK $setup]<0 || [get_property SLACK $hold]<0} {error "Board setup/hold timing failed"}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == "Critical Warning"}]]} {error "Board DRC failed"}
if {[llength [get_cdc_violations -filter {SEVERITY == Critical && !IS_WAIVED}]]} {error "Board CDC failed"}
write_bitstream -force [file join $project_dir sc88.runs impl_1 sc88_wrapper.bit]
file copy -force [file join $project_dir sc88.runs impl_1 sc88_wrapper.bit] [file join $out sc88.bit]
write_hw_platform -fixed -include_bit -force -file [file join $out sc88.xsa]
puts "SC88_BOARD_ARTIFACTS_COMPLETE"
