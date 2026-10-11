set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set generated [file join $root build hls-source]
set flags "-std=c++17 -I[file join $root hls] -I$generated"
set mode $::env(XP3_HLS_STAGE)
if {$mode eq "csim"} { open_project -reset build/hls-voice } else { open_project build/hls-voice }
set_top xp3_voice_step
open_solution single_voice -flow_target vivado
cd [file join $root build hls-voice]
add_files [file join $root hls xp3_voice.cpp] -cflags $flags
add_files [file join $generated xp3_core.cpp] -cflags $flags
add_files -tb [file join $root hls testbench.cpp] -cflags $flags
set_part xc7z010clg400-1
create_clock -period 10 -name default
config_compile -pipeline_loops 0
set arguments "[file join $root build verification phase-02 hls-vectors] [file join $root build verification phase-02 $mode]"
if {$mode eq "csim"} { csim_design -clean -argv $arguments }
if {$mode eq "synthesis"} { csynth_design }
if {$mode eq "cosim"} { cosim_design -rtl verilog -tool xsim -argv $arguments }
if {$mode eq "implementation"} { export_design -format ip_catalog -flow impl }
exit
