# Vivado 2022.2 batch entry. Set Y26_BUILD_DIR to an empty work directory.
# Source RTL and the complete, verified board PS/DDR/MIO BD are repository-local.
set y26_root [file normalize [file join [file dirname [info script]] ..]]
if {[version -short] ne "2022.2"} {error "Use Vivado 2022.2; do not silently upgrade the board design"}
if {[llength [get_projects -quiet]]} {error "Run this entry in an empty batch Vivado process"}
if {![info exists ::env(Y26_BUILD_DIR)]} {error "Set Y26_BUILD_DIR before starting Vivado"}
set y26_work [file normalize $::env(Y26_BUILD_DIR)]
if {$y26_work eq $y26_root || [string first "$y26_root/" "$y26_work/"]==0} {error "Build outputs must be outside the checkout"}
if {[file exists [file join $y26_work project]]} {error "Use a fresh work directory; preserve earlier reports"}
file mkdir $y26_work
set_param general.maxThreads 2
create_project yolo26n_pl30 [file join $y26_work project] -part xc7z020clg400-2
config_ip_cache -disable_cache
foreach y26_file [concat [glob [file join $y26_root src rtl *.sv]] [glob [file join $y26_root src rtl *.v]]] {add_files -norecurse $y26_file}
update_compile_order -fileset sources_1
source [file join $y26_root build bd sys_resident.tcl]
if {![llength [get_files -quiet */sys.bd]]} {error "Verified board BD did not load"}
validate_bd_design
save_bd_design
generate_target all [get_files */sys.bd]
set y26_wrappers [make_wrapper -files [get_files */sys.bd] -top]
add_files -norecurse $y26_wrappers
set_property top sys_wrapper [current_fileset]
update_compile_order -fileset sources_1
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE AltSpreadLogic_high [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {![string match {*Complete*} [get_property STATUS [get_runs synth_1]]]} {error "Synthesis failed; no implementation or board upload"}
launch_runs impl_1 -to_step {phys_opt_design (Post-Route)} -jobs 2
wait_on_run impl_1
if {![string match {*Complete*} [get_property STATUS [get_runs impl_1]]]} {error "Implementation failed; no bit export"}
open_run impl_1
source [file join $y26_root build signoff.tcl]
set y26_reports [file join $y26_work reports]
y26_signoff $y26_reports
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1
if {![string match {*write_bitstream Complete*} [get_property STATUS [get_runs impl_1]]]} {error "Bitstream export failed"}
file copy -force [file join [get_property DIRECTORY [get_runs impl_1]] sys_wrapper.bit] [file join $y26_reports sys_wrapper.bit]
write_hw_platform -fixed -include_bit -force -file [file join $y26_reports sys_resident.xsa]
puts "Y26 PL30 REBUILD PASS: $y26_reports"
