// SPDX-License-Identifier: MIT
//
// HBM random-access probe for the Varium C1100 (Alveo U55N).
//
// This is measurement 1 from fpga notes/02-XELISHASH-FEASIBILITY.md section 8.
// It answers the one question that decides whether XelisHash v3 is worth
// building on this card, and it is deliberately algorithm-independent: the
// number it produces is a property of the hardware and is worth having whatever
// happens to the Xelis project.
//
// WHY TWO MODES INSTEAD OF ONE COMBINED KERNEL
// --------------------------------------------
// XelisHash stage 3 is a dependent chain of random 8-byte accesses. The obvious
// probe is "run that and see how fast it goes", but that conflates two
// different hardware properties and gives one number that cannot be reasoned
// about. Split instead:
//
//   MODE_CHASE (0): C independent dependent pointer chases on ONE port.
//       Sweeping C shows where memory latency stops being the limit. At C=1
//       the per-access time IS the full round-trip latency. The knee gives the
//       concurrency needed to hide it -- directly comparable to the 162 in-
//       flight nonces the stage-3 datapath requires.
//
//   MODE_STREAM (1): independent random accesses across all ports, no
//       dependencies, pipelined as hard as the tool will allow. This is the
//       ceiling on random-access rate, i.e. the bandwidth question, with
//       latency taken out of the picture.
//
// Required concurrency = latency x rate. If MODE_CHASE's knee is far beyond
// what we can hold in flight, or MODE_STREAM's ceiling is far below
// 8 accesses/iteration x the iteration rate we need, the project is over --
// and we will know which of the two killed it.
//
// Both modes are selected at RUNTIME, as are the chain count and iteration
// count, so the whole sweep comes out of ONE four-hour link rather than one
// link per data point.
//
// Accesses are 8 bytes and the addresses are random, which is the point: HBM2's
// access granularity is 32 bytes, so the amplification this provokes is part of
// what is being measured, not an artefact to be designed away.

#include <ap_int.h>
#include <stdint.h>

#define MAX_CHAINS 256

// Cheap avalanche. Not the algorithm's map_index -- this probe is measuring
// memory, not arithmetic, so it only has to decorrelate addresses.
static inline uint64_t mix64(uint64_t x) {
#pragma HLS inline
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 29;
    return x;
}

extern "C" void hbm_probe(
    uint64_t *m0, uint64_t *m1, uint64_t *m2, uint64_t *m3,
    unsigned mode,        // 0 = MODE_CHASE, 1 = MODE_STREAM
    unsigned chains,      // 1..MAX_CHAINS  (MODE_CHASE)
    unsigned iters,       // iterations per chain
    uint64_t words,       // usable 64-bit words per port (power of two)
    uint64_t *out)        // [0]=checksum  [1]=accesses
{
    // One AXI master per HBM pseudo-channel group. Deep outstanding-read queues
    // and a burst length of 1: we want many single-beat random reads in flight,
    // which is the opposite of what the defaults are tuned for.
#pragma HLS interface m_axi port=m0 bundle=g0 offset=slave \
    num_read_outstanding=64 num_write_outstanding=16 max_read_burst_length=1
#pragma HLS interface m_axi port=m1 bundle=g1 offset=slave \
    num_read_outstanding=64 num_write_outstanding=16 max_read_burst_length=1
#pragma HLS interface m_axi port=m2 bundle=g2 offset=slave \
    num_read_outstanding=64 num_write_outstanding=16 max_read_burst_length=1
#pragma HLS interface m_axi port=m3 bundle=g3 offset=slave \
    num_read_outstanding=64 num_write_outstanding=16 max_read_burst_length=1
#pragma HLS interface m_axi port=out bundle=gout offset=slave
#pragma HLS interface s_axilite port=mode
#pragma HLS interface s_axilite port=chains
#pragma HLS interface s_axilite port=iters
#pragma HLS interface s_axilite port=words
#pragma HLS interface s_axilite port=return

    const uint64_t mask = words - 1;   // host guarantees a power of two
    uint64_t checksum = 0;
    uint64_t accesses = 0;

    if (mode == 0) {
        // ---------------- MODE_CHASE ----------------
        // `chains` independent chases, round-robined. Consecutive loop
        // iterations touch different chains, so they are independent; a given
        // chain is revisited every `chains` iterations. If `chains` exceeds the
        // memory latency in cycles, the pipeline should never stall.
        uint64_t idx[MAX_CHAINS];
#pragma HLS bind_storage variable=idx type=RAM_2P impl=BRAM

        for (unsigned c = 0; c < MAX_CHAINS; c++) {
#pragma HLS pipeline II=1
            idx[c] = mix64(0x9e3779b97f4a7c15ULL + c) & mask;
        }

        for (unsigned it = 0; it < iters; it++) {
            for (unsigned c = 0; c < chains; c++) {
#pragma HLS loop_tripcount min=1 max=MAX_CHAINS
#pragma HLS pipeline II=1
                uint64_t a = idx[c];
                uint64_t v = m0[a];
                checksum ^= v;
                idx[c] = mix64(v ^ a) & mask;
                accesses++;
            }
        }
    } else {
        // ---------------- MODE_STREAM ----------------
        // Independent random addresses, four ports in parallel, nothing
        // carried between iterations except the checksum. This is the rate
        // ceiling.
        // Derive the seed from `it` rather than carrying it between iterations.
        // The loop-carried `s = mix64(s + it)` put two chained 64x64 multiplies
        // in a single II=1 stage and capped the kernel at 186 MHz; with no
        // dependence, HLS is free to pipeline the multiplies across stages.
        // The addresses stay pseudo-random and independent, which is all this
        // mode requires.
        for (unsigned it = 0; it < iters; it++) {
#pragma HLS pipeline II=1
            uint64_t s = mix64(0xda3e39cb94b95bdbULL ^ (uint64_t)it);
            uint64_t a0 = s & mask;
            uint64_t a1 = mix64(s ^ 0x1111111111111111ULL) & mask;
            uint64_t a2 = mix64(s ^ 0x2222222222222222ULL) & mask;
            uint64_t a3 = mix64(s ^ 0x3333333333333333ULL) & mask;
            checksum ^= m0[a0] ^ m1[a1] ^ m2[a2] ^ m3[a3];
            accesses += 4;
        }
    }

    // Written back so the loops cannot be optimised away, and so the host can
    // assert the access count instead of assuming it. A benchmark that reports
    // a rate without proving it did the work is the same failure as a
    // testbench printing PASS with nothing checked.
    out[0] = checksum;
    out[1] = accesses;
}
