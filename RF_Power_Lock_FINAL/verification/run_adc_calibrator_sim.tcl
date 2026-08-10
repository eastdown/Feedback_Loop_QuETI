set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir ".."]]
set rtl_file [file join $project_dir "analog_echo.srcs" "sources_1" \
    "imports" "hdl" "adc_calibrator.v"]
set tb_file [file join $script_dir "tb_adc_calibrator.sv"]
set sim_project_dir [file normalize [file join $project_dir ".." "tmp" \
    "rf_power_lock_adc_calibrator_sim"]]
set staged_source_dir [file join $sim_project_dir "staged_sources"]
set staged_rtl_file [file join $staged_source_dir "adc_calibrator.v"]
set staged_tb_file [file join $staged_source_dir "tb_adc_calibrator.sv"]

create_project adc_calibrator_sim $sim_project_dir \
    -part xc7z010clg400-1 -force
file mkdir $staged_source_dir
file copy -force $rtl_file $staged_rtl_file
file copy -force $tb_file $staged_tb_file
add_files -norecurse [list $staged_rtl_file]
add_files -fileset sim_1 -norecurse [list $staged_tb_file]
set_property top tb_adc_calibrator [get_filesets sim_1]
set_property xsim.simulate.runtime {5us} [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
close_sim
exit
