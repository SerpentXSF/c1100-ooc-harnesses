# Out-of-context synthesis of the XelisHash v3 stage-3 primitives.
#
# Reports area and the REAL critical path for each module, one at a time.
#
# On the clock constraint: Vivado stops optimising the moment WNS >= 0, so a
# comfortable target measures nothing (00-MISTAKES-AND-REMINDERS.md entry 30).
# We therefore constrain TIGHTER than any plausible target and read the
# achievable period off the negative slack:
#
#     achievable_period = target_period - WNS
#
# That is a measurement. A passing WNS would only be a lower bound. The
# opposite failure exists too -- entry 9b, overconstraining has a cliff past
# which the tools produce garbage -- so the default below is deliberately only
# moderately tight (2.5 ns / 400 MHz), not absurd.

set part      xcu55n-fsvh2892-2L-e
set period    [lindex $argv 0]
if {$period eq ""} { set period 2.500 }
set rtl_dir   [lindex $argv 1]
if {$rtl_dir eq ""} { set rtl_dir "../rtl" }

set tops {
    xelis_isqrt
    xelis_divu
    xelis_mulhi_u128
    xelis_murmur3
    xelis_map_index
    xelis_branch_alu
}

puts "OOC_RUN_START part=$part period=$period"

foreach top $tops {
    puts "----------------------------------------------------------------"
    puts "OOC_TOP_BEGIN $top"

    if {[catch {
        # Fresh in-memory project per top, so nothing leaks between runs.
        create_project -in_memory -part $part
        read_verilog -sv [glob $rtl_dir/*.sv]

        synth_design -top $top -part $part -mode out_of_context \
                     -flatten_hierarchy rebuilt

        create_clock -name clk -period $period [get_ports clk]

        # Count primitives by REF_NAME pattern. An earlier version of this used
        # PRIMITIVE_GROUP == LUT / == DSP and silently reported ZERO for both on
        # a design that plainly contained thousands of each -- a check that
        # returns a number is not the same as a check that returns the right
        # number. The utilisation report is dumped below as the cross-check.
        set n_lut   [llength [get_cells -hier -quiet -filter {REF_NAME =~ LUT*}]]
        set n_ff    [llength [get_cells -hier -quiet -filter {REF_NAME =~ FD*}]]
        set n_car   [llength [get_cells -hier -quiet -filter {REF_NAME == CARRY8}]]
        set n_dsp   [llength [get_cells -hier -quiet -filter {REF_NAME =~ DSP*}]]
        set n_bram  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]]
        set n_uram  [llength [get_cells -hier -quiet -filter {REF_NAME =~ URAM*}]]
        set n_mux   [llength [get_cells -hier -quiet -filter {REF_NAME =~ MUXF*}]]

        set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
        if {$wns eq ""} { set wns "none" }

        puts "RESULT_AREA   $top LUT=$n_lut FF=$n_ff CARRY8=$n_car DSP=$n_dsp BRAM=$n_bram URAM=$n_uram MUXF=$n_mux"

        # Authoritative cross-check: Vivado's own utilisation table.
        set rpt [report_utilization -return_string]
        foreach ln [split $rpt "
"] {
            if {[regexp {^\|} $ln] && [regexp -nocase {LUT|Register|CARRY|DSP|RAMB|Block RAM|URAM|MUXF} $ln]} {
                puts "UTIL $top $ln"
            }
        }
        puts "RESULT_TIMING $top target=$period wns=$wns"
        if {$wns ne "none"} {
            set achievable [expr {$period - $wns}]
            set fmax       [expr {1000.0 / $achievable}]
            puts [format "RESULT_FMAX   %s achievable_period=%.3f ns fmax=%.1f MHz" \
                  $top $achievable $fmax]
        }
        close_project
    } err]} {
        puts "RESULT_ERROR  $top $err"
        catch {close_project}
    }
    puts "OOC_TOP_END $top"
}

puts "OOC_RUN_DONE"
