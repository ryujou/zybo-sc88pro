# SPDX-License-Identifier: GPL-3.0-only
set script_dir [file normalize [file dirname [info script]]]
set root [file normalize [file join $script_dir ../..]]
set board_out [file join $root build/verification/offline-player/phase-04/board]
file mkdir $board_out
set_param general.maxThreads 8
file copy -force [file join $root hardware/rtl/xp3_interpolation.mem] [file join [pwd] xp3_interpolation.mem]

proc parameter_stub {root board_out unit} {
    set input [open [file join $root hardware/rtl/$unit.sv] r]
    set source [read $input]
    close $input
    set header [string range $source 0 [expr {[string first ");" $source]+1}]]
    set header [string map [list "module $unit" "(* black_box *) module $unit"] $header]
    set output [open [file join $board_out ${unit}_stub.sv] w]
    puts $output "$header\nendmodule"
    close $output
}

# Finalization rechecks a routed checkpoint whose RTL and platform are unchanged.
if {$argc == 1 && [lindex $argv 0] eq "finalize"} {
    open_checkpoint [file join $board_out sc88-routed.dcp]
} else {
# Build the current sources in the same OOC partitions required by Phase 3.
if {$argc == 1 && [lindex $argv 0] in {resume shell}} {
    open_project [file join $root build/verification/offline-player/phase-04/parameter-platform/project/sc88.xpr]
    if {[lindex $argv 0] eq "shell"} {
        remove_files [get_files -quiet [file join $board_out parameter_core.dcp]]
        reset_run synth_1
        reset_run sc88_pcm_0_synth_1
        update_compile_order -fileset sources_1
    } elseif {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {reset_run synth_1}
    foreach run [get_runs] {
        if {[string match -nocase *error* [get_property STATUS $run]]} {
            reset_run $run
        }
    }
} else {
set partitions {xp3_parameter_voice pcm_parameter_dma pcm_mixer pcm_frame_fifo pcm_sample_fetcher pcm_sample_cache}
foreach unit $partitions {
    create_project -in_memory -part xc7z010clg400-1
    if {$unit eq "xp3_parameter_voice"} {
        foreach dep {xp3_sample_pkg xp3_voice_state xp3_interpolate xp3_wave_source xp3_filter_tva xp3_pair_filter} {
            read_verilog -sv [file join $root hardware/rtl/$dep.sv]
        }
    }
    read_verilog -sv [file join $root hardware/rtl/$unit.sv]
    if {$unit eq "pcm_sample_fetcher"} {
        synth_design -top $unit -generic TAG_BITS=11 -part xc7z010clg400-1 -mode out_of_context
    } else {
        synth_design -top $unit -part xc7z010clg400-1 -mode out_of_context
    }
    write_checkpoint -force [file join $board_out ${unit}_synthesis.dcp]
    close_project
    parameter_stub $root $board_out $unit
}
create_project -in_memory -part xc7z010clg400-1
foreach unit $partitions {read_verilog -sv [file join $board_out ${unit}_stub.sv]}
read_verilog -sv [file join $root hardware/rtl/pcm_parameter_voice_scheduler.sv]
synth_design -top pcm_parameter_voice_scheduler -generic VOICE_LIMIT=64 -part xc7z010clg400-1 -mode out_of_context
write_checkpoint -force [file join $board_out scheduler_shell.dcp]
close_project
create_project -in_memory -part xc7z010clg400-1
add_files [file join $board_out scheduler_shell.dcp]
foreach {cell unit} {voice_core xp3_parameter_voice parameters pcm_parameter_dma mixer pcm_mixer results pcm_frame_fifo fetcher pcm_sample_fetcher cache pcm_sample_cache} {
    set checkpoint [file join $board_out ${unit}_synthesis.dcp]
    add_files $checkpoint
    set_property SCOPED_TO_CELLS $cell [get_files $checkpoint]
}
link_design -top pcm_parameter_voice_scheduler -part xc7z010clg400-1
if {[llength [get_cells -hier -filter {IS_BLACKBOX == 1}]]} {error "Core contains unresolved black boxes"}
write_checkpoint -force [file join $board_out parameter_core.dcp]
close_project
parameter_stub $root $board_out pcm_parameter_voice_scheduler

source [file join $script_dir parameter_platform.tcl]
remove_files [get_files -quiet $root/hardware/rtl/*.sv]
add_files -norecurse [file join $board_out pcm_parameter_voice_scheduler_stub.sv]
update_compile_order -fileset sources_1
create_ip_run [get_files sc88.bd]
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    launch_runs synth_1 -jobs 1
    wait_on_run synth_1
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Parameter board shell synthesis failed"}
open_run synth_1
set core_cells [get_cells -hier -filter {NAME =~ */synth/core && REF_NAME =~ *pcm_parameter_voice_scheduler*}]
if {[llength $core_cells]!=1} {error "Expected one parameter core, found $core_cells"}
# read_checkpoint records its scoped file in the project; a resumed open_run can already load it.
if {[get_property IS_BLACKBOX $core_cells]} {
    read_checkpoint -cell [lindex $core_cells 0] [file join $board_out parameter_core.dcp]
}
report_utilization -file [file join $board_out utilization-synth.rpt]
report_utilization -hierarchical -file [file join $board_out utilization-synth-hierarchical.rpt]
write_checkpoint -force [file join $board_out sc88-synthesis.dcp]
opt_design -directive ExploreArea
# Vivado implements dbg_hub during opt_design.
set unresolved [get_cells -hier -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved]} {error "Board contains unresolved black boxes: $unresolved"}
report_control_sets -verbose -file [file join $board_out control-sets.rpt]
report_utilization -hierarchical -file [file join $board_out utilization-optimized-hierarchical.rpt]
write_checkpoint -force [file join $board_out sc88-optimized.dcp]
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
if {[get_property SLACK [get_timing_paths -max_paths 1 -setup]]<0} {
    phys_opt_design -directive AggressiveExplore
}
}
if {[llength [get_pins -hier -regexp {.*synth/audio/transmitter/bclk_reg/C}]]!=1} {error "Missing I2S clock source"}
if {[llength [get_pins -hier -regexp {.*synth/audio/(due_sync|fault_sync|pause_sync|drained_sync)_reg\[0\]/D}]]!=4} {error "Missing audio scalar synchronizers"}
report_utilization -file [file join $board_out utilization.rpt]
report_utilization -hierarchical -file [file join $board_out utilization-hierarchical.rpt]
report_route_status -file [file join $board_out route-status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $board_out timing-summary.rpt]
report_timing -max_paths 20 -path_type full -file [file join $board_out timing-paths.rpt]
report_clock_interaction -file [file join $board_out clock-interaction.rpt]
report_cdc -details -no_waiver -file [file join $board_out cdc-before-waiver.rpt]
report_cdc -details
# ILA 6.2 ila.xdc already false-paths these SRL match-configuration pins.
# ila_impl.xdc tag 1037291 omits u_srl_drive; tag 1191969 omits the
# I_WHOLE_SLICE hierarchy in the trigger-condition destination selector.
foreach {ila_match waiver_tag} {
    {sc88_i/audio_ila/inst/ila_core_inst/u_trig/U_TM/N_DDR_MODE.G_NMU[1].U_M/allx_typeA_match_detection.ltlib_v1_0_3_allx_typeA_inst/DUT} 1037291
    {sc88_i/audio_ila/inst/ila_core_inst/u_trig/N_DDR_TC.N_DDR_TC_INST[0].U_TC/allx_typeA_match_detection.ltlib_v1_0_3_allx_typeA_inst/DUT} 1191969
} {
set ila_from "${ila_match}/u_srl_drive/CLK"
set ila_to "${ila_match}/I_WHOLE_SLICE.G_SLICE_IDX\[0\].U_ALL_SRL_SLICE/I_IS_TERMINATION_SLICE_W_OUTPUT_REG.DOUT_O_reg/D"
foreach crossing [get_cdc_violations -quiet -filter {CHECK == CDC-10 && !IS_WAIVED}] {
    if {[get_property STARTPOINT_PIN $crossing] eq $ila_from && [get_property ENDPOINT_PIN $crossing] eq $ila_to} {
        if {[get_property DEPTH $crossing]!=2 || [get_property EXCEPTION $crossing] ne "False Path"} {error "ILA configuration handshake topology changed"}
        create_waiver -type CDC -id CDC-10 -from [get_pins $ila_from] -to [get_pins $ila_to] -user sc88 -tags $waiver_tag \
            -description "ILA 6.2 configuration handshake; exact ila.xdc false-path endpoints and ila_impl.xdc tag $waiver_tag topology."
    }
}
}
report_cdc -details -file [file join $board_out cdc.rpt]
report_waivers -file [file join $board_out waivers.rpt]
write_waivers -type CDC -force -file [file join $board_out waivers.xdc]
report_drc -file [file join $board_out drc.rpt]
report_methodology -file [file join $board_out methodology.rpt]
write_checkpoint -force [file join $board_out sc88-routed.dcp]
write_debug_probes -force [file join $board_out sc88.ltx]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup]!=1 || [llength $hold]!=1 || [get_property SLACK $setup]<0 || [get_property SLACK $hold]<0} {error "Board setup/hold timing failed"}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == "Critical Warning"}]]} {error "Board DRC failed"}
if {[llength [get_cdc_violations -filter {SEVERITY == Critical && !IS_WAIVED}]]} {error "Board CDC failed"}
write_bitstream -force [file join $board_out sc88.bit]
write_hw_platform -fixed -include_bit -force -file [file join $board_out sc88.xsa]
puts "SC88_PARAMETER_BOARD_ARTIFACTS_COMPLETE"
