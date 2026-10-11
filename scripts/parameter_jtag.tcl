# SPDX-License-Identifier: GPL-3.0-only
if {[llength $argv]!=6} {error "Usage: parameter_jtag.tcl XSA BIT ELF PS7_INIT check|load CABLE_SERIAL"}
foreach variable {xsa bitfile elffile psinit} index {0 1 2 3} {
    set $variable [file normalize [lindex $argv $index]]
    if {![file isfile [set $variable]]} {error "Missing $variable: [set $variable]"}
}
set mode [lindex $argv 4]
set serial [lindex $argv 5]
if {$mode ni {check load}} {error "Expected check or load"}
if {$mode eq "check"} {
    puts "SC88_PARAMETER_JTAG_CHECK_COMPLETE hardware_verified=0"
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
if {$board_id!=0x53435034} {error "Parameter board register ID mismatch: $board_id"}
dow $elffile
con
puts "SC88_PARAMETER_JTAG_STARTED cable=$serial host_disabled=1 audio_mode=firmware"
disconnect
