# SPDX-License-Identifier: GPL-3.0-only
if {[llength $argv] != 8} {
    error "Usage: xsct board_jtag.tcl XSA BIT ELF PS7_INIT WAVE COMMANDS check|load CABLE_SERIAL"
}
foreach variable {xsa bitfile elffile psinit wave commands} index {0 1 2 3 4 5} {
    set $variable [file normalize [lindex $argv $index]]
    if {![file isfile [set $variable]]} {error "Missing $variable: [set $variable]"}
}
set mode [lindex $argv 6]
set serial [lindex $argv 7]
if {$mode ni {check load}} {error "Expected check or load"}
if {[file size $wave] != 20971520} {error "Expected the decoded 20 MiB Wave ROM"}
if {[file size $commands] < 64 || [file size $commands] > 33554432} {error "Command packet exceeds its DDR allocation"}
if {$mode eq "check"} {
    puts "SC88_JTAG_OFFLINE_CHECK_COMPLETE hardware_verified=0"
    return
}
if {![regexp {^[A-Za-z0-9]+$} $serial]} {error "Supply the intended Zybo cable serial"}
connect -url tcp:127.0.0.1:3121
targets -set -timeout 10 -filter [format {name == "APU" && jtag_cable_serial == "%s"} $serial]
loadhw -hw $xsa
rst -system -stop
targets -set -timeout 10 -filter [format {name == "xc7z010" && jtag_cable_serial == "%s"} $serial]
fpga -file $bitfile
targets -set -timeout 10 -filter [format {name == "APU" && jtag_cable_serial == "%s"} $serial]
source $psinit
ps7_init
ps7_post_config
targets -set -timeout 10 -filter [format {name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "%s"} $serial]
rst -processor -clear-registers
set board_id [lindex [mrd -value 0x43C00000] 0]
if {$board_id != 0x53433430} {error "SC88 Phase 4 register ID mismatch: $board_id"}
dow $elffile
dow -data $wave 0x10000000
dow -data $commands 0x02000000
con
puts "SC88_JTAG_STARTED cable=$serial; Phase 4 diagnostic mixer audio, not complete XP/LSP output"
disconnect
