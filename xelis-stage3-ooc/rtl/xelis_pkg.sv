// SPDX-License-Identifier: MIT
// Constants and helpers for the XelisHash v3 stage-3 datapath.
//
// Every constant here is transcribed from src/v3.rs at
// github.com/xelis-project/xelis-hash, sha256
// ee9c746ef9765b9efa7bca3670c2a6ca380ba8fcc9ce4a376704d022bcd34254.
// Do not "tidy" these values.

package xelis_pkg;

    // const MEMORY_SIZE: usize = 531 * 128;
    localparam int unsigned MEMORY_SIZE = 531 * 128;   // 67,968 u64
    localparam int unsigned BUFFER_SIZE = MEMORY_SIZE / 2; // 33,984 u64
    localparam int unsigned SCRATCHPAD_ITERS = 2;

    // Index into a half-buffer: 0 .. 33,983 fits in 16 bits.
    localparam int unsigned IDX_W = 16;
    // Index into the whole scratchpad (r): 0 .. 67,967 fits in 17 bits.
    localparam int unsigned R_W   = 17;
    // j counts 0 .. BUFFER_SIZE-1, same width as an index.
    localparam int unsigned J_W   = 16;

    // MurmurHash3 finalizer multipliers.
    localparam logic [63:0] MURMUR_C1 = 64'hff51afd7ed558ccd;
    localparam logic [63:0] MURMUR_C2 = 64'hc4ceb9fe1a85ec53;

    // Constants folded into the index derivation at the tail of the inner loop.
    localparam logic [63:0] GOLDEN_A = 64'h9e3779b97f4a7c15;
    localparam logic [63:0] GOLDEN_B = 64'hd2b74407b1ce6e93;

    // Structural latencies. These are properties of the implementations in
    // xelis_prims.sv, not free parameters -- change the module, change these.
    localparam int unsigned L_ISQRT  = 32;   // 2 bits of radicand per stage
    localparam int unsigned L_DIV    = 128;  // 1 quotient bit per stage
    localparam int unsigned L_MULHI  = 2;
    localparam int unsigned L_MURMUR = 2;

    // Rotations in the reference are on u64, so only the low 6 bits of any
    // shift amount can matter.
    function automatic logic [63:0] rotl64(input logic [63:0] x, input logic [5:0] n);
        logic [6:0] m;
        m = 7'd64 - {1'b0, n};
        rotl64 = (n == 6'd0) ? x : ((x << n) | (x >> m));
    endfunction

    function automatic logic [63:0] rotr64(input logic [63:0] x, input logic [5:0] n);
        logic [6:0] m;
        m = 7'd64 - {1'b0, n};
        rotr64 = (n == 6'd0) ? x : ((x >> n) | (x << m));
    endfunction

endpackage
