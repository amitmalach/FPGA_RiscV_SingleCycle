# Baseline synthesis and implementation (seam 2), non-project mode.
#
#   vivado -mode batch -nojournal -nolog -source vivado/baseline.tcl [-tclargs <out_dir>]
#
# Synthesizes SOC for the Genesys 2 part, runs opt/place/route, and writes
# utilization and timing reports plus a routed checkpoint to <out_dir>
# (default build/baseline/). Prints WNS and the implied Fmax at the end.
# Run before and after a refactor and compare the reports.

source [file join [file dirname [info script]] common.tcl]
set out [file normalize [arg_or 0 [file join $root build baseline]]]

file mkdir $out
read_verilog $rtl_files
read_xdc $xdc

# Memory.v initializes the RAM with $readmemh("firmware.hex"), a bare file
# name that Vivado resolves against the working directory. Work from the
# output directory so Vivado's by-products (.Xil/, clockInfo.txt) land there.
file copy -force $hex $out
cd $out
synth_design -top SOC -part $part

report_utilization    -file [file join $out post_synth_utilization.rpt]
write_checkpoint -force    [file join $out post_synth.dcp]

opt_design
place_design
route_design

report_utilization    -file [file join $out post_route_utilization.rpt]
report_timing_summary -file [file join $out post_route_timing_summary.rpt]
write_checkpoint -force    [file join $out post_route.dcp]

puts "BASELINE part=$part"
set wns [timing_line BASELINE]
set period [get_property PERIOD [get_clocks sys_clk_p]]
puts [format "BASELINE clock=%s period_ns=%.3f Fmax_MHz=%.1f" sys_clk_p $period [expr {1000.0 / ($period - $wns)}]]
# Table rows look like: | Slice LUTs | 930 | 0 | 0 | 203800 | 0.46 |  (Used, Fixed, Prohibited, Available, Util%)
set fh [open [file join $out post_route_utilization.rpt]]
set util_txt [read $fh]
close $fh
foreach {name row} {LUT {Slice LUTs} FF {Slice Registers} BRAM {Block RAM Tile} DSP {DSPs}} {
    set pat [string map [list @ROW@ $row] {^\|\s*@ROW@\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|}]
    if {[regexp -line $pat $util_txt -> used avail pct]} {
        puts "BASELINE $name used=$used available=$avail percent=$pct"
    } else {
        puts "BASELINE $name not found in utilization report"
    }
}
puts "BASELINE reports in $out"
