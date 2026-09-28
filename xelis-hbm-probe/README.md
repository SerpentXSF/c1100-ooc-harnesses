# HBM random-access probe — Varium C1100

**Measurement 1** from `fpga notes/02-XELISHASH-FEASIBILITY.md` section 8: what
rate can this card actually sustain on random 8-byte accesses to HBM, and what
is the round-trip latency?

This decides whether XelisHash v3 is worth building here, because stage 3 is
67,968 dependent random accesses per hash and the on-chip memory holds only ~45
scratchpads. But the number is a **property of the hardware**, not of Xelis, so
it is worth having whatever happens to that project. The C1100's HBM has never
been used by anything in this repo — the BLAKE2b design does not instantiate it.

## What it measures, and what it does not

Two modes, both selected at **runtime**, so the whole sweep comes out of one
link instead of one link per data point:

| mode | what it isolates |
|---|---|
| `MODE_CHASE` (0) | `chains` independent dependent pointer chases on one port. At `chains=1` the per-access time **is** the round-trip latency. The knee of the sweep gives the concurrency needed to hide it — directly comparable to the 162 in-flight nonces the stage-3 datapath needs. |
| `MODE_STREAM` (1) | independent random accesses, four ports, no dependencies. The rate ceiling with latency taken out of the picture. |

Required concurrency is latency x rate, so the two together say which of the two
limits binds — and if the answer is bad, which one killed it.

**The honest limit of this build: four AXI ports cannot saturate 32 HBM banks.**
The latency number is exact and port-count independent. The rate number is
**per-port**, and scaling it to the full stack is an extrapolation, not a
measurement — HBM interconnect contention is not linear. If the per-port numbers
look promising, a 16–32 port follow-up build is the honest way to get the
ceiling. Do not quote a full-stack GB/s figure out of this build.

Accesses are 8 bytes at random addresses, which is deliberate: HBM2's access
granularity is 32 bytes, so the ~4x amplification is part of what is being
measured, not an artefact to design away.

## Layout

    src/hbm_probe.cpp        HLS kernel, both modes
    hbm_probe.cfg            HBM bank assignment, SLR0 placement, pinned clock
    host/hbm_probe_host.cpp  XRT host; runs the sweep, asserts the access counts
    build_hbm.sh             WSL build (Vitis 2023.1), compile then link

## Two guards worth keeping

**The host asserts the work happened.** The kernel writes back the number of
accesses it performed and the host compares it to what was requested, refusing
to report a rate otherwise. A benchmark that prints a bandwidth figure without
proving the loop ran is the same failure as a testbench printing PASS having
checked nothing.

**The build refuses to link for a clock the kernel cannot make.** HLS prints its
own Fmax estimate during compile; `build_hbm.sh` greps it and aborts before the
multi-hour link if it is below the pinned `freqHz`. This was added the hard way —
the first attempt pinned 300 MHz while the compile log had already said
186.46 MHz, and the link started anyway. v++ writes no bitstream at all when
WNS < 0, so that path costs two hours and yields nothing.

## Why the clock is 250 MHz

The 186 MHz was one loop-carried line, `s = mix64(s + it)`, which put two chained
64x64 multiplies in a single II=1 stage. Deriving the seed from the loop counter
instead removed the dependence and HLS went to **301.83 MHz**.

That is still only 0.6% above a 300 MHz target, and HLS estimates the kernel
logic alone, before the PR region's real routing. This project's record is that
targets picked by guessing failed and targets picked from a measurement closed
first time, so the cfg pins **250 MHz** — and, decisively, **nothing being
measured needs 300**: latency is reported in nanoseconds and is clock-independent,
and the rate mode is port-limited rather than clock-limited (4 accesses/cycle at
250 MHz is already ~32 GB/s of HBM traffic, far short of the stack).

## Running it

    ./build_hbm.sh                      # in WSL; compile + link
    # then, on the machine with the card:
    ./hbm_probe_host hbm_probe.xclbin

**Before loading it on the card**, `card_monitor.sh` must be running — a probe
that hammers HBM draws real power, and prohibition 4 has no exception for
benchmarks. Note also that this is the first design in this project to
instantiate HBM at all, which brings in HBM power against a 225 W *electrical*
budget, HBM's own thermal trip, and the VCC_HBM / VCCAUX_HBM rails. `hbm_cattrip`
is handled by the platform's `hmss_0` here rather than by tying the pin low, so
the rule recorded in `00-START-HERE` section 7 inverts for this bitstream.
