# Regenerate the Vivado project from the plain source tree.
#
#   vivado -mode batch -nojournal -nolog -source vivado/create_project.tcl [-tclargs <project_dir>]
#
# Creates <project_dir>/soc.xpr (default build/vivado/) for the Genesys 2 part,
# with the RTL from vivado/rtl_sources.txt, the Genesys 2 constraints and the
# simulation testbench. Sources are referenced in place, not copied, so editing
# a file under rtl/ edits the project. The project directory is ignored by git;
# rerun this script after a clean clone or whenever the file lists change.
#
# The firmware image is added to both filesets as a memory file: Vivado then
# copies it into the synthesis and simulation run directories, where
# Memory.v's $readmemh("firmware.hex") resolves the bare file name.

source [file join [file dirname [info script]] sources.tcl]
# build.tcl sets proj_dir before sourcing this script; standalone runs take it from -tclargs.
if {![info exists proj_dir]} {
    set proj_dir [expr {[llength $argv] ? [lindex $argv 0] : [file join $root build vivado]}]
}
set proj_dir [file normalize $proj_dir]
set proj_name soc

create_project -force $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]

add_files -norecurse -fileset sources_1 $rtl_files
add_files -norecurse -fileset sources_1 $hex
set_property file_type {Memory File} [get_files -of_objects [get_filesets sources_1] $hex]
set_property top SOC [get_filesets sources_1]

add_files -norecurse -fileset constrs_1 $xdc

add_files -norecurse -fileset sim_1 $bench
add_files -norecurse -fileset sim_1 $hex
set_property file_type {Memory File} [get_files -of_objects [get_filesets sim_1] $hex]
set_property top bench [get_filesets sim_1]
# Let the testbench's own stop conditions end the run instead of xsim's default 1 us.
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "PROJECT [file join $proj_dir $proj_name.xpr]"
puts "PROJECT top=[get_property top [get_filesets sources_1]] sim_top=[get_property top [get_filesets sim_1]] part=$part"
close_project
