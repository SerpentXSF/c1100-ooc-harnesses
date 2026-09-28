# XelisHash v3 stage-3 — out-of-context area/timing harness

This is **measurement 2** from
`fpga notes/02-XELISHASH-FEASIBILITY.md` section 8: synthesise one stage-3
iteration's arithmetic out of context, so its area and achievable period are
known numbers instead of guesses, before anyone writes a miner.

Results are recorded in that document under
*MEASURED: stage-3 out-of-context synthesis*.

## Status: PARTIALLY VERIFIED

**`xelis_isqrt` has been verified behaviourally against the Rust reference.
Nothing else has.** The rest was written to be synthesised, and area and timing
are all it has produced. A wrong hash
core still produces well-formed output, and nothing about one looks broken --
that is the whole reason section 5 of `00-START-HERE` exists. Do not build a
miner on this until a testbench cross-checks it per-cycle against
`xelis-hash`'s own implementation.

The specific things a testbench has to settle:

1. ~~`xelis_isqrt` vs the reference's floating-point `isqrt`~~ — **DONE
   2026-09-22, and the assumption was WRONG.** `tb/verify_isqrt.py` found
   2,003,151 mismatches: the reference's `wrapping_mul` overflows u64 for
   n >= (2^32-1)^2, so it returns a root 1 or 2 too high, and that is the
   network's definition of the function. `tb/verify_isqrt_fix.py` verified a
   closed form (two constant compares over exact integer sqrt, output widened to
   u64 because 2^32+1 does not fit in 32 bits) against the reference on
   2,216,060 values with zero mismatches, exhaustive across both boundaries.
   The RTL now implements the reference including its overflow, at a cost of
   +211 LUTs on the ALU and no Fmax. Full write-up in
   `fpga notes/02-XELISHASH-FEASIBILITY.md`.

   The lesson generalises to the rest of this module and is the reason items 2
   and 3 below matter more than they did: **port the reference's bugs, not its
   intent.** A PoW has no specification other than the code the network runs.
   Every `wrapping_add`, `wrapping_sub` and `wrapping_mul` in cases 3-9 is
   currently implemented as plain SystemVerilog arithmetic on the assumption
   that it truncates identically. That assumption has not been tested, and it is
   the same shape as the one that just failed.
2. **All 16 branch cases**, each with its own directed vectors. A case that is
   never selected by random stimulus is a case that is not tested.
3. **Latency alignment.** The shared-unit structure carries operands across the
   divider by explicit delay lines; an off-by-one there produces plausible
   garbage.

## Layout

    rtl/xelis_pkg.sv         constants transcribed from src/v3.rs, plus rot helpers
    rtl/xelis_prims.sv       isqrt, restoring divider, multiply-high, murmur3,
                             map_index, and the delay line
    rtl/xelis_branch_alu.sv  all 16 cases with shared divider/isqrt/mulhi
    tcl/ooc_synth.tcl        per-module OOC synth, area + achievable period
    run_ooc.sh               WSL runner (Vivado 2023.1)

## Running it

    ./run_ooc.sh [target_period_ns]     # default 2.500

From Windows, via WSL:

    wsl.exe -d Ubuntu -- bash "/mnt/d/.../xelis-stage3-ooc/run_ooc.sh" 2.500

It stages the sources into `$HOME/fpga/xelis-ooc` and builds there, because
Vivado on a 9p mount with spaces in the path is a fight not worth having.
Nothing is deleted; each run writes its own timestamped log.

## Two things about the method

**The clock target is deliberately too tight.** Vivado stops optimising the
moment WNS >= 0, so a comfortable constraint measures nothing. We constrain
tighter than any plausible operating point and read
`achievable_period = target - WNS`. That is a measurement; a passing WNS would
only be a lower bound.

**The area counts are cross-checked.** The first version of `ooc_synth.tcl`
filtered on `PRIMITIVE_GROUP == LUT` and `== DSP` and reported **zero of both**
for a design containing tens of thousands of LUTs -- and every other number in
the row looked plausible, so the table read as a result rather than as a bug. It
now counts by `REF_NAME` pattern *and* dumps Vivado's own utilisation table
alongside, so the two can disagree visibly. Quote the `UTIL` rows, not the
`RESULT_AREA` line: the cell count and the utilisation table legitimately differ
(LUT combining, and DSP48E2 decomposing into ~9 sub-cells each, which inflated
the raw DSP count by exactly that factor).

## Known gaps in the harness

- Only the branch ALU is built. The full iteration also needs five `map_index`
  instances in a dependency chain, `pick_half`, the `r` counter, and the memory
  interface. Add roughly 3,000 LUTs for those, plus their own delay lines.
- No memory model at all. The scratchpad, and therefore the HBM question that
  actually decides this project, is untouched here. That is measurement 1.
- `xelis_divu` is a plain radix-2 restoring divider, 128 stages. It is 79% of
  the ALU's LUTs and sets the 162-cycle latency that forces HBM. A radix-4
  version, or a reciprocal-based one, attacks both the area and the latency, and
  is the obvious next experiment if the project continues.
