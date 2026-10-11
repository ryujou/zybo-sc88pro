if {[llength $argv] != 3} {error "Usage: dump_parameter_pcm.tcl TOTAL_FRAMES OUTPUT_PCM CABLE_SERIAL"}
set total [lindex $argv 0]
set output [lindex $argv 1]
connect -url tcp:127.0.0.1:3121
set serial [lindex $argv 2]
if {![regexp {^[A-Za-z0-9]+$} $serial]} {error "Supply the intended cable serial"}
targets -set -filter [format {name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "%s"} $serial]
loadhw -hw build/verification/offline-player/phase-04/board/sc88.xsa
stop
try {
    set clock [lindex [mrd -value 0xf8000170] 0]
    if {($clock & 0x03f03f30) != 0x00300400} {error "Unexpected FCLK0 divisor: $clock"}
    set completed [lindex [mrd -value 0x43c00018] 0]
    set written [lindex [mrd -value 0x43c00024] 0]
    set fault [lindex [mrd -value 0x43c0000c] 0]
    if {$completed != $total || $written != $total || $fault != 0} {
        error "Incomplete render: completed=$completed written=$written fault=$fault"
    }
    mrd -bin -file $output 0x08000000 [expr {$total * 2}]
    puts "SC88_PCM_DUMP_COMPLETE frames=$completed bytes=[expr {$total * 8}] fclk_ctrl=$clock"
} finally {
    con
    disconnect
}
