# Out-of-context synthesis of the Poseidon2/Goldilocks primitives.
#
# Same method as the XelisHash stage-3 harness: constrain TIGHTER than any
# plausible target so Vivado cannot stop at WNS >= 0 and call it a day, then
# read achievable_period = target - WNS. A passing WNS would be a lower bound,
# not a measurement (00-MISTAKES-AND-REMINDERS.md entry 30).
#
# Counts come from Vivado's own utilisation table as well as a cell count,
# because a previous version of this script filtered on PRIMITIVE_GROUP and
# reported ZERO LUTs for a design full of them (entry 77).

set part      xcu55n-fsvh2892-2L-e
set period    [lindex $argv 0]
if {$period eq ""} { set period 2.500 }
set rtl_dir   [lindex $argv 1]
if {$rtl_dir eq ""} { set rtl_dir "rtl" }

set tops {
    gl_mul
    gl_mul_const
    gl_mul_const_lut
    gl_exp7
    pos2_external_round
    pos2_internal_round
}

puts "OOC_RUN_START part=$part period=$period"

foreach top $tops {
    puts "----------------------------------------------------------------"
    puts "OOC_TOP_BEGIN $top"

    if {[catch {
        create_project -in_memory -part $part
        # The package MUST be read before the modules that import it. glob
        # order is not a contract, and Vivado reports the failure as
        # "'gl_pkg' is not declared" rather than as an ordering problem.
        read_verilog -sv $rtl_dir/gl_pkg.sv
        foreach f [glob $rtl_dir/*.sv] {
            if {[string match *gl_pkg.sv $f]} { continue }
            read_verilog -sv $f
        }
        synth_design -top $top -part $part -mode out_of_context \
                     -flatten_hierarchy rebuilt

        create_clock -name clk -period $period [get_ports clk]

        set n_lut  [llength [get_cells -hier -quiet -filter {REF_NAME =~ LUT*}]]
        set n_ff   [llength [get_cells -hier -quiet -filter {REF_NAME =~ FD*}]]
        set n_car  [llength [get_cells -hier -quiet -filter {REF_NAME == CARRY8}]]
        set n_dsp  [llength [get_cells -hier -quiet -filter {REF_NAME == DSP48E2}]]

        set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
        if {$wns eq ""} { set wns "none" }

        puts "RESULT_AREA   $top LUT=$n_lut FF=$n_ff CARRY8=$n_car DSP48E2=$n_dsp"

        set rpt [report_utilization -return_string]
        foreach ln [split $rpt "\n"] {
            if {[regexp {^\|} $ln] && [regexp -nocase {CLB LUTs|CLB Registers|CARRY8|DSPs} $ln]} {
                puts "UTIL $top $ln"
            }
        }

        puts "RESULT_TIMING $top target=$period wns=$wns"
        if {$wns ne "none"} {
            set achievable [expr {$period - $wns}]
            puts [format "RESULT_FMAX   %s achievable_period=%.3f ns fmax=%.1f MHz" \
                  $top $achievable [expr {1000.0 / $achievable}]]
        }
        close_project
    } err]} {
        puts "RESULT_ERROR  $top $err"
        catch {close_project}
    }
    puts "OOC_TOP_END $top"
}

puts "OOC_RUN_DONE"
