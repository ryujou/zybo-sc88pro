set xsa [file normalize [lindex $argv 0]]
set bsp [file normalize [lindex $argv 1]]
set hardware [hsi::open_hw_design $xsa]
set processor ps7_cortexa9_0
if {[llength [hsi::get_cells $processor -filter {IP_TYPE==PROCESSOR}]]!=1} {error "Expected Cortex-A9 is absent from XSA"}
hsi::set_repo_path [file join $::env(XILINX_VITIS) data embeddedsw]
set software [hsi::create_sw_design -os standalone -proc $processor sc88_ps]
hsi::set_property CONFIG.stdin ps7_uart_1 [hsi::get_os]
hsi::set_property CONFIG.stdout ps7_uart_1 [hsi::get_os]
hsi::generate_bsp -dir $bsp -sw $software
hsi::close_hw_design $hardware
puts "SC88_PS_BSP_COMPLETE"
