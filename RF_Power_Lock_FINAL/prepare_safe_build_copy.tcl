set source_dir [file dirname [file normalize [info script]]]
set source_project [file join $source_dir analog_echo.xpr]
set build_dir [file normalize [file join $source_dir .. RF_Power_Lock_ADC_BUILD]]

open_project $source_project
save_project_as -force -scan_for_includes -exclude_run_results \
    analog_echo $build_dir
close_project

file copy -force \
    [file join $source_dir build_rf_power_lock_v1.tcl] \
    [file join $build_dir build_rf_power_lock_v1.tcl]

puts "SAFE_BUILD_COPY_READY=$build_dir"
set publish_dir $source_dir
source [file join $build_dir build_rf_power_lock_v1.tcl]
exit
