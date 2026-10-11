# Original Zybo pin assignments: Digilent Zybo-Master.xdc (MIT).
set_property PACKAGE_PIN L16 [get_ports clk125]
set_property PACKAGE_PIN T19 [get_ports ac_mclk]
set_property PACKAGE_PIN K18 [get_ports i2s_bclk]
set_property PACKAGE_PIN L17 [get_ports i2s_lrclk]
set_property PACKAGE_PIN M17 [get_ports i2s_data]
set_property PACKAGE_PIN P18 [get_ports ac_mute_n]
set_property PACKAGE_PIN N18 [get_ports IIC_0_scl_io]
set_property PACKAGE_PIN N17 [get_ports IIC_0_sda_io]
set_property PACKAGE_PIN M14 [get_ports {led[0]}]
set_property PACKAGE_PIN M15 [get_ports {led[1]}]
set_property PACKAGE_PIN G14 [get_ports {led[2]}]
set_property PACKAGE_PIN D18 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk125 ac_mclk i2s_bclk i2s_lrclk i2s_data ac_mute_n IIC_0_scl_io IIC_0_sda_io led[*]}]
# The clock wizard supplies the 125 MHz input clock constraint.
set mclk_pin [get_pins -hierarchical -regexp {.*synth/audio/transmitter/bclk_reg/C}]
create_generated_clock -name codec_bclk -source $mclk_pin -divide_by 6 -invert [get_ports i2s_bclk]
# SSM2603 slave I2S: data and LRCLK require 10 ns setup and hold at rising BCLK.
set_output_delay -clock codec_bclk -max 10.000 [get_ports {i2s_data i2s_lrclk}]
set_output_delay -clock codec_bclk -min -10.000 [get_ports {i2s_data i2s_lrclk}]
# Only the first destination flops of the scalar toggle/status synchronizers are asynchronous.
set scalar_sync [get_pins -hierarchical -regexp {.*synth/audio/(due_sync|fault_sync|pause_sync)_reg\[0\]/D}]
set_false_path -to $scalar_sync
# These pins use asynchronous I2C handshakes or static status/mute levels, not a synchronous data interface.
set_false_path -from [get_ports {IIC_0_scl_io IIC_0_sda_io}]
set_false_path -to [get_ports {IIC_0_scl_io IIC_0_sda_io ac_mute_n led[*]}]
