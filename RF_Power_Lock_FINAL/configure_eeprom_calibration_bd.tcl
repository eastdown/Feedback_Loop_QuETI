open_project [file normalize "./analog_echo.xpr"]

# The project was originally generated with an older Vivado release.  Upgrade
# only IP instances that the current release reports as locked; a locked block
# design cannot be validated or regenerated after adding the calibrators.
set locked_ips [get_ips -quiet -filter {IS_LOCKED == 1}]
if {[llength $locked_ips] != 0} {
    puts "UPGRADING_LOCKED_IPS=$locked_ips"
    upgrade_ip $locked_ips
}

set calibrator_file [file normalize "./analog_echo.srcs/sources_1/imports/hdl/dac_calibrator.v"]
if {![file exists $calibrator_file]} {
    error "Missing DAC calibrator source: $calibrator_file"
}
if {[llength [get_files -quiet $calibrator_file]] == 0} {
    add_files -norecurse $calibrator_file
}

open_bd_design [get_files "*/design_1.bd"]

# Keep the existing controller/PID parameter GPIOs intact.  Add two dedicated
# dual-channel GPIO banks for DAC calibration gain and offset.
set_property -dict [list CONFIG.NUM_MI {6}] [get_bd_cells axi_smc]

foreach gpio_name {axi_gpio_4 axi_gpio_5} {
    if {[llength [get_bd_cells -quiet $gpio_name]] == 0} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 $gpio_name
    }
    set_property -dict [list \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_ALL_OUTPUTS_2 {1} \
        CONFIG.C_GPIO_WIDTH {16} \
        CONFIG.C_GPIO2_WIDTH {16} \
        CONFIG.C_INTERRUPT_PRESENT {0} \
        CONFIG.C_IS_DUAL {1}] [get_bd_cells $gpio_name]
}

foreach calibrator_name {dac_calibrator_0 dac_calibrator_1} {
    if {[llength [get_bd_cells -quiet $calibrator_name]] == 0} {
        create_bd_cell -type module -reference dac_calibrator $calibrator_name
    }
}

# Replace only the direct controller-to-DAC nets with controller-to-calibrator
# and calibrator-to-DAC nets.
foreach net_name {offset_scale_ctrl_0_data_o offset_scale_ctrl_1_data_o} {
    if {[llength [get_bd_intf_nets -quiet $net_name]] != 0} {
        delete_bd_objs [get_bd_intf_nets $net_name]
    }
}

connect_bd_intf_net [get_bd_intf_pins offset_scale_ctrl_0/data_o] \
    [get_bd_intf_pins dac_calibrator_0/data_i]
connect_bd_intf_net [get_bd_intf_pins dac_calibrator_0/data_o] \
    [get_bd_intf_pins dac_0/dac_data_1]
connect_bd_intf_net [get_bd_intf_pins offset_scale_ctrl_1/data_o] \
    [get_bd_intf_pins dac_calibrator_1/data_i]
connect_bd_intf_net [get_bd_intf_pins dac_calibrator_1/data_o] \
    [get_bd_intf_pins dac_0/dac_data_2]

connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] \
    [get_bd_intf_pins axi_gpio_4/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M05_AXI] \
    [get_bd_intf_pins axi_gpio_5/S_AXI]

connect_bd_net [get_bd_pins clk_0/clk_125] \
    [get_bd_pins axi_gpio_4/s_axi_aclk] \
    [get_bd_pins axi_gpio_5/s_axi_aclk] \
    [get_bd_pins dac_calibrator_0/clk] \
    [get_bd_pins dac_calibrator_1/clk]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_gpio_4/s_axi_aresetn] \
    [get_bd_pins axi_gpio_5/s_axi_aresetn] \
    [get_bd_pins dac_calibrator_0/resetn] \
    [get_bd_pins dac_calibrator_1/resetn]

connect_bd_net [get_bd_pins axi_gpio_4/gpio_io_o] \
    [get_bd_pins dac_calibrator_0/cal_gain]
connect_bd_net [get_bd_pins axi_gpio_4/gpio2_io_o] \
    [get_bd_pins dac_calibrator_1/cal_gain]
connect_bd_net [get_bd_pins axi_gpio_5/gpio_io_o] \
    [get_bd_pins dac_calibrator_0/cal_offset]
connect_bd_net [get_bd_pins axi_gpio_5/gpio2_io_o] \
    [get_bd_pins dac_calibrator_1/cal_offset]

assign_bd_address -offset 0x41240000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs axi_gpio_4/S_AXI/Reg] -force
assign_bd_address -offset 0x41250000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs axi_gpio_5/S_AXI/Reg] -force

validate_bd_design
save_bd_design
generate_target all [get_files "*/design_1.bd"]

set wrapper [make_wrapper -files [get_files "*/design_1.bd"] -top]
if {[llength [get_files -quiet $wrapper]] == 0} {
    add_files -norecurse $wrapper
}
set_property top design_1_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "EEPROM_CALIBRATION_BD_CONFIGURED=1"
close_project
exit
