set script_dir [file dirname [file normalize [info script]]]
set project_file [file join $script_dir "analog_echo.xpr"]
set calibrator_file [file join $script_dir "analog_echo.srcs" "sources_1" \
    "imports" "hdl" "adc_calibrator.v"]

open_project $project_file

if {![file exists $calibrator_file]} {
    error "Missing ADC calibrator source: $calibrator_file"
}
if {[llength [get_files -quiet -all -filter {NAME =~ *adc_calibrator.v}]] == 0} {
    # add_files treats square brackets in an absolute Windows path as glob
    # syntax.  Add by basename from the source directory so [FINAL] remains a
    # literal part of the project path.
    set original_dir [pwd]
    cd [file dirname $calibrator_file]
    add_files -norecurse [file tail $calibrator_file]
    cd $original_dir
}

open_bd_design [get_files -all "*/design_1.bd"]

set adc_path_already_configured [expr {
    [llength [get_bd_cells -quiet {adc_calibrator_0 adc_calibrator_1}]] == 2 &&
    [llength [get_bd_cells -quiet {axi_gpio_6 axi_gpio_7}]] == 2
}]

if {!$adc_path_already_configured} {
    # Two dual-channel GPIO banks carry the EEPROM ADC gain and offset values.
    set_property -dict [list CONFIG.NUM_MI {8}] [get_bd_cells axi_smc]

foreach gpio_name {axi_gpio_6 axi_gpio_7} {
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

foreach calibrator_name {adc_calibrator_0 adc_calibrator_1} {
    if {[llength [get_bd_cells -quiet $calibrator_name]] == 0} {
        create_bd_cell -type module -reference adc_calibrator $calibrator_name
    }
}

# Insert one calibrator between each physical ADC stream and its PI controller.
foreach controller_name {offset_scale_ctrl_0 offset_scale_ctrl_1} {
    set old_net [get_bd_intf_nets -quiet -of_objects \
        [get_bd_intf_pins ${controller_name}/data_i]]
    if {[llength $old_net] != 0} {
        delete_bd_objs $old_net
    }
}

connect_bd_intf_net [get_bd_intf_pins adc_0/adc_data_1] \
    [get_bd_intf_pins adc_calibrator_0/data_i]
connect_bd_intf_net [get_bd_intf_pins adc_calibrator_0/data_o] \
    [get_bd_intf_pins offset_scale_ctrl_0/data_i]
connect_bd_intf_net [get_bd_intf_pins adc_0/adc_data_2] \
    [get_bd_intf_pins adc_calibrator_1/data_i]
connect_bd_intf_net [get_bd_intf_pins adc_calibrator_1/data_o] \
    [get_bd_intf_pins offset_scale_ctrl_1/data_i]

connect_bd_intf_net [get_bd_intf_pins axi_smc/M06_AXI] \
    [get_bd_intf_pins axi_gpio_6/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M07_AXI] \
    [get_bd_intf_pins axi_gpio_7/S_AXI]

connect_bd_net [get_bd_pins clk_0/clk_125] \
    [get_bd_pins axi_gpio_6/s_axi_aclk] \
    [get_bd_pins axi_gpio_7/s_axi_aclk] \
    [get_bd_pins adc_calibrator_0/clk] \
    [get_bd_pins adc_calibrator_1/clk]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_gpio_6/s_axi_aresetn] \
    [get_bd_pins axi_gpio_7/s_axi_aresetn] \
    [get_bd_pins adc_calibrator_0/resetn] \
    [get_bd_pins adc_calibrator_1/resetn]

connect_bd_net [get_bd_pins axi_gpio_6/gpio_io_o] \
    [get_bd_pins adc_calibrator_0/cal_gain]
connect_bd_net [get_bd_pins axi_gpio_6/gpio2_io_o] \
    [get_bd_pins adc_calibrator_1/cal_gain]
connect_bd_net [get_bd_pins axi_gpio_7/gpio_io_o] \
    [get_bd_pins adc_calibrator_0/cal_offset]
connect_bd_net [get_bd_pins axi_gpio_7/gpio2_io_o] \
    [get_bd_pins adc_calibrator_1/cal_offset]

assign_bd_address -offset 0x41260000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs axi_gpio_6/S_AXI/Reg] -force
    assign_bd_address -offset 0x41270000 -range 0x00010000 \
        -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
        [get_bd_addr_segs axi_gpio_7/S_AXI/Reg] -force
} else {
    puts "ADC calibration path already exists; retaining existing connections"
}

validate_bd_design
save_bd_design
generate_target all [get_files -all "*/design_1.bd"]

set wrapper [make_wrapper -files [get_files -all "*/design_1.bd"] -top]
if {[llength [get_files -quiet -all $wrapper]] == 0} {
    add_files -norecurse $wrapper
}
set_property top design_1_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "ADC_EEPROM_CALIBRATION_BD_CONFIGURED=1"
close_project
exit
