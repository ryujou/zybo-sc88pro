# SPDX-License-Identifier: GPL-3.0-only
set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root build/verification/offline-player/phase-04/storage-platform]
file mkdir $out
create_project -force storage [file join $out project] -part xc7z010clg400-1
source [file join $root hardware/board/zybo_ps7.tcl]
create_bd_design storage
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
configure_zybo_ps7 $ps
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {0} CONFIG.PCW_USE_S_AXI_HP0 {0} CONFIG.PCW_USE_S_AXI_HP1 {0}] $ps
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} $ps
validate_bd_design
save_bd_design
generate_target all [get_files storage.bd]
make_wrapper -files [get_files storage.bd] -top
add_files [file join $out project/storage.gen/sources_1/bd/storage/hdl/storage_wrapper.v]
set_property top storage_wrapper [current_fileset]
write_hw_platform -fixed -force -file [file join $out storage.xsa]
puts "SC88_STORAGE_PLATFORM_COMPLETE"
