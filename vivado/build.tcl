# Synthesize, implement and write the bitstream without the GUI.
#
#   vivado -mode batch -nojournal -nolog -source vivado/build.tcl [-tclargs <project_dir> [synth|bitstream]]
#
# Opens <project_dir>/soc.xpr (default build/vivado/), creating it first with
# vivado/create_project.tcl if it does not exist. Runs synth_1 and impl_1
# through write_bitstream and copies the bitstream to build/SOC.bit. The second
# argument "synth" stops after synthesis. Prints the post-route WNS/WHS and a
# "BUILD ... timing=MET|FAILED" line; the script errors out if a run fails.

source [file join [file dirname [info script]] common.tcl]
set jobs 4
set proj_dir [file normalize [arg_or 0 [file join $root build vivado]]]
set stage    [arg_or 1 bitstream]
if {$stage ni {synth bitstream}} { error "second argument must be synth or bitstream, got '$stage'" }
set xpr [file join $proj_dir soc.xpr]

if {![file exists $xpr]} {
    source [file join $root vivado create_project.tcl]   ;# reads proj_dir
}
open_project $xpr

proc run_and_check {run args} {
    global jobs
    reset_run $run
    launch_runs $run -jobs $jobs {*}$args
    wait_on_run $run
    set status [get_property STATUS [get_runs $run]]
    if {[get_property PROGRESS [get_runs $run]] ne "100%" || [string match -nocase "*error*" $status]} {
        error "BUILD $run failed: $status"
    }
    puts "BUILD $run: $status"
}

run_and_check synth_1
if {$stage eq "synth"} {
    puts "BUILD stopped after synthesis (reports in [get_property DIRECTORY [get_runs synth_1]])"
    close_project
    return
}

run_and_check impl_1 -to_step write_bitstream
set bit [file join [get_property DIRECTORY [get_runs impl_1]] SOC.bit]
if {![file exists $bit]} { error "BUILD no bitstream at $bit" }
file mkdir [file join $root build]
file copy -force $bit [file join $root build SOC.bit]

open_run impl_1
timing_line BUILD
puts "BUILD bitstream [file join $root build SOC.bit]"
close_project
