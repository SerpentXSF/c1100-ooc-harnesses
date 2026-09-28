# OOC synthesis of one Odocrypt round, both ROM styles.
# Method as in the earlier harnesses: constrain tighter than any plausible
# target so achievable_period = target - WNS is a measurement rather than a
# lower bound, and dump Vivado's own utilisation table alongside the cell count.

set part   xcu55n-fsvh2892-2L-e
set period [lindex $argv 0]
if {$period eq ""} { set period 2.500 }
set rtl    [lindex $argv 1]
if {$rtl eq ""} { set rtl "rtl" }

set tops { odo_round odo_round_lut }

puts "OOC_RUN_START part=$part period=$period"

foreach top $tops {
    puts "----------------------------------------------------------------"
    puts "OOC_TOP_BEGIN $top"
    if {[catch {
        create_project -in_memory -part $part
        # include dir for odo_tables.svh
        set_property include_dirs [list $rtl] [current_fileset]
        read_verilog -sv $rtl/odo_round.sv
        synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt
        create_clock -name clk -period $period [get_ports clk]

        set n_lut  [llength [get_cells -hier -quiet -filter {REF_NAME =~ LUT*}]]
        set n_ff   [llength [get_cells -hier -quiet -filter {REF_NAME =~ FD*}]]
        set n_b18  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB18*}]]
        set n_b36  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36*}]]
        set n_dsp  [llength [get_cells -hier -quiet -filter {REF_NAME == DSP48E2}]]
        set n_lutm [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAM*X*}]]

        set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
        if {$wns eq ""} { set wns "none" }

        puts "RESULT_AREA   $top LUT=$n_lut FF=$n_ff RAMB18=$n_b18 RAMB36=$n_b36 LUTRAM=$n_lutm DSP=$n_dsp"
        set rpt [report_utilization -return_string]
        foreach ln [split $rpt "\n"] {
            if {[regexp {^\|} $ln] && [regexp -nocase {CLB LUTs|CLB Registers|Block RAM Tile|RAMB|LUT as Memory|DSPs} $ln]} {
                puts "UTIL $top $ln"
            }
        }
        puts "RESULT_TIMING $top target=$period wns=$wns"
        if {$wns ne "none"} {
            set ach [expr {$period - $wns}]
            puts [format "RESULT_FMAX   %s achievable_period=%.3f ns fmax=%.1f MHz" $top $ach [expr {1000.0/$ach}]]
        }
        close_project
    } err]} {
        puts "RESULT_ERROR  $top $err"
        catch {close_project}
    }
    puts "OOC_TOP_END $top"
}
puts "OOC_RUN_DONE"
