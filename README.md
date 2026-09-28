# OOC harnesses — measuring an algorithm before building it

Out-of-context Vivado synthesis harnesses for the Xilinx Varium C1100
(`xcu55n-fsvh2892-2L-e`, VU35P). Each one answers a single question about a
candidate proof-of-work algorithm — *what does one round cost in LUTs, FFs, DSPs
and BRAM, and how fast will it close?* — in about an hour, without a four-hour
place-and-route and without touching the card.

**These do not compute correct hashes and are not meant to.** Every source file
says so in its header: *"NOT VERIFIED against the reference. Area and timing
only."* See [NOTICE](NOTICE) for what was transcribed from where, and for the
one component that *was* verified.

They are the evidence behind the feasibility screens in the notes repository.

## The method

Constrain tighter than any plausible target, then read the slack, so that

    achievable_period = target − WNS

is a measurement rather than a lower bound. Report Vivado's own utilisation
table alongside a raw cell count, because the two disagree in instructive ways —
`REF_NAME` filtering counts primitives, the utilisation report counts occupied
slices.

## The harnesses

| directory | question | verdict |
|---|---|---|
| `xelis-stage3-ooc` | XelisHash v3 stage-3 datapath | memory-bound; ~11–17 kH/s against 394 kH/s for a 4090 |
| `quantus-poseidon2-ooc` | Poseidon2 over Goldilocks | multiply-bound; 73–115 MH/s, loses to GPUs |
| `odocrypt-ooc` | one Odocrypt round | **596 MHz/round, 0 DSPs** — passes technically, fails on market room |
| `xelis-hbm-probe` | measured HBM bandwidth, on hardware | the input to the XelisHash verdict |

Odocrypt is the interesting one: 10 BRAMs per round, 840 for a fully unrolled
84-round core, 71% of the device's 1,188 — BRAM, not registers, is what stops a
second core.

## Running one

    bash odocrypt-ooc/run_ooc.sh 2.500      # target period in ns

Needs Vivado 2023.1 and a licence. The scripts stage sources into
`$HOME/fpga/<harness>/` and run `vivado -mode batch`, printing `RESULT_AREA`,
`RESULT_TIMING` and `RESULT_FMAX` lines that the feasibility docs quote directly.

`xelis-hbm-probe` is the exception: it builds a real `.xclbin` and runs on the
card, so it costs a full build and card time.

Each script locates its own sources from `${BASH_SOURCE[0]}`. They previously
hardcoded an absolute `/mnt/d/...` path, which meant the tree could not be moved
or checked out anywhere else.

## The screening rule these produced

Four candidates screened, four correct predictions, about an hour each.

> **Suits this card** when the inner loop is adds, XORs, rotations and table
> lookups over a register-sized state, with no per-nonce memory and no serial
> dependence between nonces.
>
> **Reject** on: a per-nonce scratchpad (memory-bound, a GPU's bandwidth wins),
> multiplies in the inner loop (DSP-bound, GPUs have far more multiply
> throughput), serial dependence between nonces, or a state much larger than
> ~1024 bits.

And the correction that Odocrypt forced, which no synthesis run can tell you:

> Passing the technical screen means the card can mine it well. It says nothing
> about whether there is **room**. Check network hashrate and emission value
> *before* the synthesis run — it is a two-minute lookup, and it would have
> ranked Odocrypt below a newer, emptier chain of the same shape.

The register law, for estimating core count before synthesising:

    FF per core = STATE_BITS × ROUNDS × STAGES + TAG_BITS × LATENCY

Device budget (PR region): 788,640 LUTs, 1,577,280 FFs, 1,188 BRAM, 5,640 DSPs,
640 URAM. Whichever the algorithm exhausts first is the binding resource.

## Related

| repo | holds |
|---|---|
| [blake2b-c1100](https://github.com/SerpentXSF/blake2b-c1100) | the RTL and bitstream that shipped |
| [x-miner](https://github.com/SerpentXSF/x-miner) | the Stratum miner |
| [fpga-mining-notes](https://github.com/SerpentXSF/fpga-mining-notes) | the feasibility screens these fed, and 83 recorded mistakes |
