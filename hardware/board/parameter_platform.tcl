# SPDX-License-Identifier: GPL-3.0-only
set script_dir [file normalize [file dirname [info script]]]
set root [file normalize [file join $script_dir ../..]]
set out [file join $root build/verification/offline-player/phase-04/parameter-platform]
file mkdir $out
set project_dir [file join $out project]
create_project sc88 $project_dir -part xc7z010clg400-1 -force
set_param general.maxThreads 8
set_property simulator_language Mixed [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
foreach unit {xp3_sample_pkg xp3_voice_state xp3_interpolate xp3_wave_source xp3_filter_tva xp3_pair_filter xp3_parameter_voice pcm_mixer pcm_frame_fifo pcm_sample_fetcher pcm_sample_cache pcm_parameter_dma pcm_parameter_voice_scheduler} {
    add_files -norecurse [file join $root hardware/rtl $unit.sv]
}
foreach unit {pcm_axi_control pcm_parameter_registers pcm_block_queue pcm_block_dma pcm_transport pcm_return_audio pcm_parameter_commands pcm_parameter_results pcm_i2s pcm_audio_bridge pcm_parameter_synth pcm_parameter_board} {
    add_files -norecurse [file join $script_dir $unit.sv]
}
add_files -norecurse [file join $script_dir pcm_parameter_board_ip.v]
add_files -norecurse [file join $root hardware/rtl/xp3_interpolation.mem]
update_compile_order -fileset sources_1
source [file join $script_dir zybo_ps7.tcl]
source [file join $script_dir parameter_design.tcl]
create_sc88_parameter_design
foreach {master slave} {M_WAVE HP0 M_BLOCK HP1 M_AUDIO HP2} {
    set spaces [get_bd_addr_spaces pcm/$master]
    if {[llength $spaces]!=1 || [llength [get_bd_addr_segs -of_objects $spaces]]==0} {error "Missing DDR mapping for $master"}
    if {[get_property CONFIG.PCW_USE_S_AXI_$slave [get_bd_cells ps7]]!=1} {error "Missing PS port $slave"}
}
set bd_file [get_files sc88.bd]
generate_target all $bd_file
make_wrapper -files $bd_file -top
add_files -norecurse [file join $project_dir sc88.gen sources_1 bd sc88 hdl sc88_wrapper.v]
set_property top sc88_wrapper [current_fileset]
set constraints [file join $script_dir parameter_zybo.xdc]
add_files -fileset constrs_1 -norecurse $constraints
set_property PROCESSING_ORDER LATE [get_files $constraints]
set_property USED_IN_SYNTHESIS false [get_files $constraints]
update_compile_order -fileset sources_1
write_hw_platform -fixed -force -file [file join $out sc88-platform.xsa]
puts "SC88_PARAMETER_PLATFORM_COMPLETE"
