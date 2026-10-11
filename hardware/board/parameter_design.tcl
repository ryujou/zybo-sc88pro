# SPDX-License-Identifier: GPL-3.0-only
proc create_sc88_parameter_design {} {
    create_bd_design sc88
    set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
    configure_zybo_ps7 $ps
    set_property -dict [list CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_EN_RST0_PORT {1} \
        CONFIG.PCW_FPGA_FCLK0_ENABLE {1} CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {83.333333} CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
        CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_USE_S_AXI_HP0 {1} CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
        CONFIG.PCW_USE_S_AXI_HP1 {1} CONFIG.PCW_S_AXI_HP1_DATA_WIDTH {64} CONFIG.PCW_USE_S_AXI_HP2 {1} CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {64} \
        CONFIG.PCW_USE_FABRIC_INTERRUPT {1} CONFIG.PCW_IRQ_F2P_INTR {1} \
        CONFIG.PCW_EN_I2C0 {1} CONFIG.PCW_I2C0_I2C0_IO {EMIO} CONFIG.PCW_EN_EMIO_I2C0 {1} \
        CONFIG.PCW_I2C0_BASEADDR {0xE0004000} CONFIG.PCW_I2C0_HIGHADDR {0xE0004FFF} CONFIG.PCW_I2C0_PERIPHERAL_ENABLE {1}] $ps
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} $ps
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 IIC_0
    connect_bd_intf_net [get_bd_intf_ports IIC_0] [get_bd_intf_pins ps7/IIC_0]
    create_bd_port -dir I -type clk -freq_hz 125000000 clk125
    create_bd_port -dir O -type clk -freq_hz 12288002 ac_mclk
    foreach name {i2s_bclk i2s_lrclk i2s_data ac_mute_n} {create_bd_port -dir O $name}
    create_bd_port -dir O -from 3 -to 0 led
    create_bd_cell -type module -reference pcm_parameter_board_ip pcm
    set control [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 control_axi]
    set_property CONFIG.NUM_MI {1} $control
    foreach name {wave_axi block_axi audio_axi} {
        set converter [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 $name]
        # Masters already limit INCR bursts to 16 beats and never cross a 4 KiB boundary.
        set_property -dict [list CONFIG.SI_PROTOCOL {AXI4} CONFIG.MI_PROTOCOL {AXI3} CONFIG.DATA_WIDTH {64} CONFIG.ID_WIDTH {6} CONFIG.TRANSLATION_MODE {0}] $converter
    }
    set audio [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 audio_clock]
    set_property -dict [list CONFIG.PRIM_IN_FREQ {125} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {12.288} \
        CONFIG.OVERRIDE_MMCM {true} CONFIG.MMCM_DIVCLK_DIVIDE {8} CONFIG.MMCM_CLKFBOUT_MULT_F {39.125} \
        CONFIG.MMCM_CLKOUT0_DIVIDE_F {49.750} CONFIG.RESET_PORT {resetn} CONFIG.RESET_TYPE {ACTIVE_LOW} \
        CONFIG.USE_RESET {true} CONFIG.USE_LOCKED {true}] $audio
    foreach name {sys_reset audio_reset} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 $name
    }
    set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 irq_zero]
    set_property -dict [list CONFIG.CONST_WIDTH {15} CONFIG.CONST_VAL {0}] $zero
    set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 interrupts]
    set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {1} CONFIG.IN1_WIDTH {15}] $concat
    set leds [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 status_leds]
    set_property -dict [list CONFIG.DIN_WIDTH {128} CONFIG.DIN_FROM {7} CONFIG.DIN_TO {4} CONFIG.DOUT_WIDTH {4}] $leds
    set logic_ila [create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 logic_ila]
    set_property CONFIG.C_MONITOR_TYPE {Native} $logic_ila
    set_property -dict [list CONFIG.C_NUM_OF_PROBES {3} CONFIG.C_PROBE0_WIDTH {128} CONFIG.C_PROBE1_WIDTH {128} CONFIG.C_PROBE2_WIDTH {1} \
        CONFIG.C_PROBE0_TYPE {1} CONFIG.C_PROBE1_TYPE {1} CONFIG.C_PROBE2_TYPE {2} CONFIG.C_DATA_DEPTH {1024}] $logic_ila
    set audio_ila [create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 audio_ila]
    set_property CONFIG.C_MONITOR_TYPE {Native} $audio_ila
    set_property -dict [list CONFIG.C_NUM_OF_PROBES {2} CONFIG.C_PROBE0_WIDTH {64} CONFIG.C_PROBE1_WIDTH {1} \
        CONFIG.C_PROBE0_TYPE {1} CONFIG.C_PROBE1_TYPE {2} CONFIG.C_DATA_DEPTH {1024}] $audio_ila
    set audio_trigger [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 audio_trigger]
    set_property -dict [list CONFIG.DIN_WIDTH {64} CONFIG.DIN_FROM {4} CONFIG.DIN_TO {4} CONFIG.DOUT_WIDTH {1}] $audio_trigger
    connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins control_axi/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins control_axi/M00_AXI] [get_bd_intf_pins pcm/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins pcm/M_WAVE] [get_bd_intf_pins wave_axi/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins wave_axi/M_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]
    connect_bd_intf_net [get_bd_intf_pins pcm/M_BLOCK] [get_bd_intf_pins block_axi/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins block_axi/M_AXI] [get_bd_intf_pins ps7/S_AXI_HP1]
    connect_bd_intf_net [get_bd_intf_pins pcm/M_AUDIO] [get_bd_intf_pins audio_axi/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins audio_axi/M_AXI] [get_bd_intf_pins ps7/S_AXI_HP2]
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK] [get_bd_pins ps7/S_AXI_HP0_ACLK] [get_bd_pins ps7/S_AXI_HP1_ACLK] [get_bd_pins ps7/S_AXI_HP2_ACLK] \
        [get_bd_pins control_axi/ACLK] [get_bd_pins control_axi/S00_ACLK] [get_bd_pins control_axi/M00_ACLK] \
        [get_bd_pins wave_axi/aclk] [get_bd_pins block_axi/aclk] [get_bd_pins audio_axi/aclk] [get_bd_pins pcm/clk] [get_bd_pins sys_reset/slowest_sync_clk] [get_bd_pins logic_ila/clk]
    connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins sys_reset/ext_reset_in] [get_bd_pins audio_reset/ext_reset_in] [get_bd_pins audio_clock/resetn]
    connect_bd_net [get_bd_pins audio_clock/locked] [get_bd_pins sys_reset/dcm_locked] [get_bd_pins audio_reset/dcm_locked]
    connect_bd_net [get_bd_pins sys_reset/peripheral_aresetn] [get_bd_pins pcm/resetn] [get_bd_pins control_axi/ARESETN] \
        [get_bd_pins control_axi/S00_ARESETN] [get_bd_pins control_axi/M00_ARESETN] [get_bd_pins wave_axi/aresetn] [get_bd_pins block_axi/aresetn] [get_bd_pins audio_axi/aresetn]
    connect_bd_net [get_bd_ports clk125] [get_bd_pins audio_clock/clk_in1]
    connect_bd_net [get_bd_pins audio_clock/clk_out1] [get_bd_pins audio_reset/slowest_sync_clk] [get_bd_pins pcm/audio_clk] [get_bd_pins audio_ila/clk] [get_bd_ports ac_mclk]
    connect_bd_net [get_bd_pins audio_reset/peripheral_reset] [get_bd_pins pcm/audio_reset]
    foreach {port pin} {i2s_bclk bclk i2s_lrclk lrclk i2s_data serial_data ac_mute_n mute_n} {
        connect_bd_net [get_bd_ports $port] [get_bd_pins pcm/$pin]
    }
    connect_bd_net [get_bd_pins pcm/debug_sys0] [get_bd_pins status_leds/Din] [get_bd_pins logic_ila/probe0]
    connect_bd_net [get_bd_pins pcm/debug_sys1] [get_bd_pins logic_ila/probe1]
    connect_bd_net [get_bd_pins pcm/debug_audio] [get_bd_pins audio_ila/probe0] [get_bd_pins audio_trigger/Din]
    connect_bd_net [get_bd_pins audio_trigger/Dout] [get_bd_pins audio_ila/probe1]
    connect_bd_net [get_bd_pins status_leds/Dout] [get_bd_ports led]
    connect_bd_net [get_bd_pins pcm/irq] [get_bd_pins interrupts/In0] [get_bd_pins logic_ila/probe2]
    connect_bd_net [get_bd_pins irq_zero/dout] [get_bd_pins interrupts/In1]
    connect_bd_net [get_bd_pins interrupts/dout] [get_bd_pins ps7/IRQ_F2P]
    assign_bd_address
    assign_bd_address -offset 0x43C00000 -range 0x00001000 -target_address_space [get_bd_addr_spaces ps7/Data] [get_bd_addr_segs pcm/S_AXI/reg0] -force
    validate_bd_design
    foreach name {sys_reset audio_reset} {
        if {[get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells $name]] != 0} {error "PS reset polarity must be active-low"}
    }
    save_bd_design
    puts "SC88_AUDIO_MCLK_HZ=[expr {125000000.0*39.125/8/49.75}]"
}
