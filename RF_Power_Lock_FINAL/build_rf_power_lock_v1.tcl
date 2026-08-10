set script_dir [file dirname [file normalize [info script]]]
set project_file [file join $script_dir "analog_echo.xpr"]
set bd_path [file join $script_dir "analog_echo.srcs" "sources_1" "bd" "design_1" "design_1.bd"]
set report_dir [file join $script_dir "reports"]
set output_dir [file join $script_dir "output"]

file mkdir $report_dir
file mkdir $output_dir

open_project $project_file
open_bd_design [get_files -all [list $bd_path]]

set controller_cells [get_bd_cells -quiet {offset_scale_ctrl_0 offset_scale_ctrl_1}]
if {[llength $controller_cells] != 2} {
    error "Expected two offset_scale_ctrl cells, found [llength $controller_cells]"
}
set adc_calibrator_cells [get_bd_cells -quiet {adc_calibrator_0 adc_calibrator_1}]
if {[llength $adc_calibrator_cells] != 2} {
    error "Expected two adc_calibrator cells, found [llength $adc_calibrator_cells]. Run configure_adc_calibration_bd.tcl first."
}

# The module ports are unchanged, so the existing block-design instances stay
# connected.  The current RTL is picked up when their output products are
# regenerated below.  Calling update_module_reference is unnecessary here and
# is unreliable in Vivado when the project path contains spaces.
validate_bd_design
save_bd_design
generate_target all [get_files -all [list $bd_path]]

set wrapper_file [file normalize [file join $script_dir "analog_echo.gen" "sources_1" "bd" "design_1" "hdl" "design_1_wrapper.v"]]
make_wrapper -files [get_files -all [list $bd_path]] -top
if {![file exists $wrapper_file]} {
    error "Missing generated wrapper: $wrapper_file"
}
if {[llength [get_files -quiet -all [list $wrapper_file]]] == 0} {
    add_files -norecurse [list $wrapper_file]
}

set_property top design_1_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

# Module-reference blocks have their own out-of-context synthesis runs.  Reset
# them explicitly so a copied project cannot reuse a checkpoint made from the
# older direct-output test controller.
set controller_runs [get_runs -quiet {
    design_1_offset_scale_ctrl_0_0_synth_1
    design_1_offset_scale_ctrl_1_0_synth_1
}]
if {[llength $controller_runs] != 2} {
    error "Expected two controller synthesis runs, found [llength $controller_runs]"
}
foreach controller_run $controller_runs {
    reset_run $controller_run
}

set adc_calibrator_runs [get_runs -quiet {
    design_1_adc_calibrator_0_0_synth_1
    design_1_adc_calibrator_1_0_synth_1
}]
if {[llength $adc_calibrator_runs] == 0} {
    set adc_calibrator_xcis [get_files -quiet -all -filter \
        {NAME =~ *design_1_adc_calibrator_*_0.xci}]
    if {[llength $adc_calibrator_xcis] != 2} {
        error "Expected two ADC calibrator XCI files, found [llength $adc_calibrator_xcis]"
    }
    foreach adc_calibrator_xci $adc_calibrator_xcis {
        create_ip_run $adc_calibrator_xci
    }
    set adc_calibrator_runs [get_runs -quiet {
        design_1_adc_calibrator_0_0_synth_1
        design_1_adc_calibrator_1_0_synth_1
    }]
}
if {[llength $adc_calibrator_runs] != 2} {
    error "Expected two ADC calibrator synthesis runs, found [llength $adc_calibrator_runs]"
}
foreach adc_calibrator_run $adc_calibrator_runs {
    reset_run $adc_calibrator_run
}
launch_runs $adc_calibrator_runs -jobs 2
foreach adc_calibrator_run $adc_calibrator_runs {
    wait_on_run $adc_calibrator_run
    set adc_calibrator_progress [get_property PROGRESS $adc_calibrator_run]
    if {$adc_calibrator_progress ne "100%"} {
        error "ADC calibrator synthesis failed: $adc_calibrator_run ($adc_calibrator_progress)"
    }
}

# Vivado 2025.2 on Windows occasionally corrupts one DAC module-reference
# launch when both DAC OOC jobs start together ("Could not open 'C'").  Build
# these two small runs explicitly and serially before the top-level launch.
set dac_calibrator_runs [get_runs -quiet {
    design_1_dac_calibrator_0_0_synth_1
    design_1_dac_calibrator_1_0_synth_1
}]
if {[llength $dac_calibrator_runs] != 2} {
    error "Expected two DAC calibrator synthesis runs, found [llength $dac_calibrator_runs]"
}
foreach dac_calibrator_run $dac_calibrator_runs {
    reset_run $dac_calibrator_run
    launch_runs $dac_calibrator_run -jobs 1
    wait_on_run $dac_calibrator_run
    set dac_calibrator_progress [get_property PROGRESS $dac_calibrator_run]
    if {$dac_calibrator_progress ne "100%"} {
        error "DAC calibrator synthesis failed: $dac_calibrator_run ($dac_calibrator_progress)"
    }
}

launch_runs $controller_runs -jobs 2
foreach controller_run $controller_runs {
    wait_on_run $controller_run
    set controller_progress [get_property PROGRESS $controller_run]
    if {$controller_progress ne "100%"} {
        error "Controller synthesis failed: $controller_run ($controller_progress)"
    }
}

# SmartConnect invokes Tcl app initialization during OOC synthesis.  Running it
# explicitly and serially avoids a Vivado 2025.2 Windows race seen when many IP
# child runs initialize the Tcl app cache at the same time.
set smartconnect_runs [get_runs -quiet {design_1_axi_smc_1_synth_1}]
if {[llength $smartconnect_runs] != 1} {
    error "Expected one SmartConnect synthesis run, found [llength $smartconnect_runs]"
}
reset_run $smartconnect_runs
launch_runs $smartconnect_runs -jobs 1
wait_on_run $smartconnect_runs
set smartconnect_progress [get_property PROGRESS $smartconnect_runs]
if {$smartconnect_progress ne "100%"} {
    error "SmartConnect synthesis failed ($smartconnect_progress)"
}

reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set progress [get_property PROGRESS [get_runs impl_1]]
set status [get_property STATUS [get_runs impl_1]]
puts "RF_POWER_LOCK_IMPL_STATUS=$status"
puts "RF_POWER_LOCK_IMPL_PROGRESS=$progress"
if {$progress ne "100%"} {
    error "Implementation did not complete successfully: $status ($progress)"
}

open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir "timing_summary_routed.rpt"]
report_utilization -hierarchical \
    -file [file join $report_dir "utilization_hierarchical.rpt"]

set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
set hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
    error "Unable to obtain setup/hold timing paths"
}
set wns [get_property SLACK [lindex $setup_paths 0]]
set whs [get_property SLACK [lindex $hold_paths 0]]
puts "RF_POWER_LOCK_WNS_NS=$wns"
puts "RF_POWER_LOCK_WHS_NS=$whs"
if {$wns < 0.0 || $whs < 0.0} {
    error "Timing failed: WNS=$wns ns, WHS=$whs ns"
}

set bit_file [file join $script_dir "analog_echo.runs" "impl_1" "design_1_wrapper.bit"]
set hwh_file [file join $script_dir "analog_echo.gen" "sources_1" "bd" "design_1" "hw_handoff" "design_1.hwh"]
if {![file exists $bit_file]} {
    error "Missing bitstream: $bit_file"
}
if {![file exists $hwh_file]} {
    error "Missing hardware handoff: $hwh_file"
}

file copy -force $bit_file [file join $output_dir "rf_power_lock_v1.bit"]
file copy -force $hwh_file [file join $output_dir "rf_power_lock_v1.hwh"]

# prepare_safe_build_copy.tcl sets publish_dir so a build performed in the
# bracket-free working copy also refreshes the canonical project's artifacts.
if {[info exists publish_dir] && $publish_dir ne $script_dir} {
    set publish_output_dir [file join $publish_dir "output"]
    set publish_report_dir [file join $publish_dir "reports"]
    file mkdir $publish_output_dir
    file mkdir $publish_report_dir
    file copy -force $bit_file [file join $publish_output_dir "rf_power_lock_v1.bit"]
    file copy -force $hwh_file [file join $publish_output_dir "rf_power_lock_v1.hwh"]
    file copy -force \
        [file join $report_dir "timing_summary_routed.rpt"] \
        [file join $publish_report_dir "timing_summary_routed.rpt"]
    file copy -force \
        [file join $report_dir "utilization_hierarchical.rpt"] \
        [file join $publish_report_dir "utilization_hierarchical.rpt"]
    puts "RF_POWER_LOCK_PUBLISHED=$publish_dir"
}

puts "RF_POWER_LOCK_BIT=[file join $output_dir {rf_power_lock_v1.bit}]"
puts "RF_POWER_LOCK_HWH=[file join $output_dir {rf_power_lock_v1.hwh}]"
close_project
exit
