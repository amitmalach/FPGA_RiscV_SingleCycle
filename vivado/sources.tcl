# Source locations shared by the Vivado scripts. Sourced, not run directly.
# Defines: root, part, rtl_files (from vivado/rtl_sources.txt, also read by
# sim/run_regression.sh), hex, xdc, bench.
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
