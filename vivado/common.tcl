# Shared by the Vivado scripts (sourced, not run directly).
# Defines: root, part, rtl_files (from vivado/rtl_sources.txt, also read by
# sim/run_regression.sh), hex, xdc, bench, and two helper procs.
set root [file normalize [file join [file dirname [info script]] ..]]
set part xc7k325tffg900-2

set rtl_files {}
set fh [open [file join $root vivado rtl_sources.txt]]
foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} continue
    lappend rtl_files [file join $root $line]
}
close $fh

set hex   [file join $root rtl firmware.hex]
set xdc   [file join $root constraints Genesys-2-Master.xdc]
set bench [file join $root sim bench.v]

# Positional -tclargs argument $i, or $default when absent.
proc arg_or {i default} {
    global argv
    expr {[llength $argv] > $i ? [lindex $argv $i] : $default}
}

# Print "<prefix> WNS_ns=... WHS_ns=... timing=MET|FAILED" for the open
# implemented design. Setup and hold only; pulse-width and recovery checks
# are in the timing summary report.
proc timing_line {prefix} {
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    puts [format "%s WNS_ns=%.3f WHS_ns=%.3f timing=%s" $prefix $wns $whs \
          [expr {$wns >= 0 && $whs >= 0 ? "MET" : "FAILED"}]]
    return $wns
}
