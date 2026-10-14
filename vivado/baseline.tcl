# Baseline synthesis and implementation (seam 2), non-project mode.
#
#   vivado -mode batch -nojournal -nolog -source vivado/baseline.tcl [-tclargs <out_dir>]
#
# Synthesizes SOC for the Genesys 2 part, runs opt/place/route, and writes
# utilization and timing reports plus a routed checkpoint to <out_dir>
# (default build/baseline/). Prints WNS and the implied Fmax at the end.
# Run before and after a refactor and compare the reports.

set root [file normalize [file join [file dirname [info script]] ..]]
set out  [expr {[llength $argv] ? [lindex $argv 0] : [file join $root build baseline]}]
set part xc7k325tffg900-2

# Source locations. The RTL list is shared with sim/run_regression.sh.
# Ticket #4 moves the image and constraints into rtl/ and constraints/.
set hex_dir [file join $root Bruno_RISCV.srcs sources_1 imports FROM_BLINKER_TO_RISCV]
set xdc     [file join $root Bruno_RISCV.srcs constrs_1 imports Desktop Genesys-2-Master.xdc]
set rtl_files {}
set fh [open [file join $root vivado rtl_sources.txt]]
foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} continue
    lappend rtl_files [file join $root $line]
}
close $fh

file mkdir $out
read_verilog $rtl_files
read_xdc $xdc

# Memory.v initializes the RAM with $readmemh("firmware.hex"), a bare file
# name that Vivado resolves against the working directory.
set cwd [pwd]
cd $hex_dir
synth_design -top SOC -part $part
cd $cwd

report_utilization    -file [file join $out post_synth_utilization.rpt]
write_checkpoint -force    [file join $out post_synth.dcp]

opt_design
place_design
route_design

report_utilization    -file [file join $out post_route_utilization.rpt]
report_timing_summary -file [file join $out post_route_timing_summary.rpt]
write_checkpoint -force    [file join $out post_route.dcp]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set period [get_property PERIOD [get_clocks sys_clk_p]]
set fmax [expr {1000.0 / ($period - $wns)}]
puts "BASELINE part=$part"
puts [format "BASELINE clock=%s period_ns=%.3f WNS_ns=%.3f WHS_ns=%.3f Fmax_MHz=%.1f timing=%s" \
      sys_clk_p $period $wns $whs $fmax [expr {$wns >= 0 && $whs >= 0 ? "MET" : "FAILED"}]]
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
