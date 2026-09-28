// SPDX-License-Identifier: MIT
// Expensive primitives of XelisHash v3 stage 3, each synthesisable on its own
// so its area can be measured in isolation.
//
// Verification status, module by module -- do not assume uniformity:
//   xelis_isqrt      VERIFIED behaviourally against the reference (tb/verify_*)
//   everything else  NOT VERIFIED. Area and timing only.
// Do not build a miner on the unverified ones until a testbench has checked
// them. The isqrt story below is why: the one assumption that got tested turned
// out to be false.

// ---------------------------------------------------------------------------
// Delay line. SHREG_EXTRACT="no" is load-bearing, not cosmetic: synthesis
// collapses untapped stretches into SRLs, which replaces N register hops with
// one hop into whatever SLICEM was free, and phys_opt cannot undo it.
// See 00-MISTAKES-AND-REMINDERS.md entry 32.
// ---------------------------------------------------------------------------
module xelis_delay #(
    parameter int unsigned W = 64,
    parameter int unsigned N = 1
) (
    input  logic         clk,
    input  logic [W-1:0] d,
    output logic [W-1:0] q
);
    if (N == 0) begin : g_pass
        assign q = d;
    end else begin : g_reg
        (* SHREG_EXTRACT = "no" *) logic [W-1:0] pipe [0:N-1];
        always_ff @(posedge clk) begin
            pipe[0] <= d;
            for (int k = 1; k < N; k++) pipe[k] <= pipe[k-1];
        end
        assign q = pipe[N-1];
    end
endmodule

// ---------------------------------------------------------------------------
// isqrt: the reference's isqrt, INCLUDING its integer-overflow behaviour.
//
// VERIFIED 2026-09-22 by tb/verify_isqrt.py and tb/verify_isqrt_fix.py.
//
// An earlier version of this module computed plain floor(sqrt(n)), on the
// argument that the reference's floating-point implementation must agree with
// it. THE ARGUMENT WAS WRONG, and the test said so: 2,003,151 mismatches.
//
// The reference is
//     let approx = (n as f64).sqrt() as u64;
//     if approx.wrapping_mul(approx) > n { approx - 1 }
//     else if (approx + 1).wrapping_mul(approx + 1) <= n { approx + 1 }
//     else { approx }
// and the `wrapping_mul` is the whole story. For n >= (2^32-1)^2 the true root
// is always 2^32-1, but (approx+1)^2 is then at least 2^64, which WRAPS to a
// small value, so the `<= n` test passes and the reference increments when it
// must not. Near 2^64 it happens twice over: `n as f64` rounds up to 2^64
// (the binary64 ulp there is 2048, so this happens for n >= 2^64 - 1024),
// approx becomes 2^32, its square also wraps, and the result is 2^32+1 --
// two above the true root.
//
// So the reference is exactly:
//     n >= 2^64 - 1024   ->  2^32 + 1
//     n >= (2^32 - 1)^2  ->  2^32
//     otherwise          ->  floor(sqrt(n))
// which is two constant comparisons on top of an exact integer sqrt. Verified
// equal to the reference on every value tested, including exhaustively for
// +/-300,000 around both boundaries.
//
// The divergent range is 8,589,934,591 wide, 4.657e-10 of the u64 space. That
// is small enough to never appear in a random test and large enough to be hit
// roughly once in 10^5 hashes. It is precisely the class of bug section 5 of
// 00-START-HERE exists to catch: a wrong hash core still produces well-formed
// output.
//
// NOTE the output is 64 bits, not 32: 2^32+1 does not fit in 32 bits, and the
// reference's return type is u64.
// ---------------------------------------------------------------------------
module xelis_isqrt (
    input  logic        clk,
    input  logic [63:0] n,
    output logic [63:0] q
);
    // (2^32-1)^2 = 2^64 - 2^33 + 1
    localparam logic [63:0] BOUND_LO_SQ = 64'hFFFF_FFFE_0000_0001;
    // 2^64 - 1024
    localparam logic [63:0] BOUND_HI    = 64'hFFFF_FFFF_FFFF_FC00;
    // Invariant: rem <= 2*root, so rem < 2^33; rem*4+3 < 2^35. 36 bits is safe.
    logic [35:0] rem  [0:32];
    logic [31:0] root [0:32];
    logic [63:0] rad  [0:32];

    assign rem[0]  = '0;
    assign root[0] = '0;
    assign rad[0]  = n;

    for (genvar i = 0; i < 32; i++) begin : g_stage
        logic [35:0] rsh, trial, rem_n;
        logic [31:0] root_n;
        logic        ge;
        always_comb begin
            rsh    = {rem[i][33:0], rad[i][63:62]};   // rem*4 + next two bits
            trial  = {2'b00, root[i], 2'b01};         // root*4 + 1
            ge     = (rsh >= trial);
            rem_n  = ge ? (rsh - trial) : rsh;
            root_n = {root[i][30:0], ge};
        end
        always_ff @(posedge clk) begin
            rem[i+1]  <= rem_n;
            root[i+1] <= root_n;
            rad[i+1]  <= rad[i] << 2;
        end
    end

    // Decide the correction at the INPUT and carry two bits, rather than
    // carrying all 64 bits of n to the output to compare there: 64 FFs instead
    // of 2048.
    logic sel_lo_i, sel_hi_i, sel_lo_o, sel_hi_o;
    always_comb begin
        sel_lo_i = (n >= BOUND_LO_SQ);
        sel_hi_i = (n >= BOUND_HI);
    end

    xelis_delay #(.W(1), .N(32)) u_dly_lo (.clk(clk), .d(sel_lo_i), .q(sel_lo_o));
    xelis_delay #(.W(1), .N(32)) u_dly_hi (.clk(clk), .d(sel_hi_i), .q(sel_hi_o));

    always_comb begin
        if (sel_hi_o)      q = 64'h0000_0001_0000_0001;   // 2^32 + 1
        else if (sel_lo_o) q = 64'h0000_0001_0000_0000;   // 2^32
        else               q = {32'b0, root[32]};
    end
endmodule

// ---------------------------------------------------------------------------
// Unsigned restoring divider, W stages, one quotient bit per stage.
// Returns both quotient and remainder because stage 3 needs both (cases
// 12/13 divide, cases 0/1/10/11 take a remainder) and one shared unit serves
// all of them.
//
// No divide-by-zero guard: every divisor in stage 3 is forced nonzero by the
// reference itself (denom|1, b|4, a|2, c|1, c|8). If that ever stops being
// true this module returns garbage rather than trapping.
// ---------------------------------------------------------------------------
module xelis_divu #(
    parameter int unsigned W = 128
) (
    input  logic         clk,
    input  logic [W-1:0] num,
    input  logic [W-1:0] den,
    output logic [W-1:0] quo,
    output logic [W-1:0] rem
);
    logic [W-1:0] r [0:W];
    logic [W-1:0] qq[0:W];
    logic [W-1:0] nn[0:W];
    logic [W-1:0] dd[0:W];

    assign r[0]  = '0;
    assign qq[0] = '0;
    assign nn[0] = num;
    assign dd[0] = den;

    for (genvar i = 0; i < W; i++) begin : g_stage
        // r*2 + next bit needs W+1 bits: r can be as large as den-1.
        logic [W:0] rsh, dext, sub;
        logic       ge;
        always_comb begin
            rsh  = {r[i], nn[i][W-1]};
            dext = {1'b0, dd[i]};
            ge   = (rsh >= dext);
            sub  = ge ? (rsh - dext) : rsh;
        end
        always_ff @(posedge clk) begin
            r[i+1]  <= sub[W-1:0];
            qq[i+1] <= {qq[i][W-2:0], ge};
            nn[i+1] <= nn[i] << 1;
            dd[i+1] <= dd[i];
        end
    end

    assign quo = qq[W];
    assign rem = r[W];
endmodule

// ---------------------------------------------------------------------------
// (a * b) >> 64 for 128-bit a, b -- what cases 14 and 15 need.
//
// Only bits [127:64] of the 256-bit product are wanted, and those depend on
// just two terms: the high half of a0*b0, plus the low half of
// (a0*b1 + a1*b0). The a1*b1 term lands entirely at bit 128 and above, so it
// is never computed. Three of the four 64x64 products, not four.
// ---------------------------------------------------------------------------
module xelis_mulhi_u128 (
    input  logic         clk,
    input  logic [127:0] a,
    input  logic [127:0] b,
    output logic [63:0]  hi
);
    logic [127:0] p00_q, p01_q, p10_q;

    always_ff @(posedge clk) begin
        p00_q <= a[63:0]   * b[63:0];
        p01_q <= a[63:0]   * b[127:64];
        p10_q <= a[127:64] * b[63:0];
    end

    logic [128:0] mid;
    always_comb mid = {1'b0, p01_q} + {1'b0, p10_q};

    always_ff @(posedge clk) hi <= p00_q[127:64] + mid[63:0];
endmodule

// ---------------------------------------------------------------------------
// MurmurHash3 finalizer, exactly as the reference writes it.
// ---------------------------------------------------------------------------
module xelis_murmur3 (
    input  logic        clk,
    input  logic [63:0] seed_i,
    output logic [63:0] seed_o
);
    import xelis_pkg::*;

    logic [63:0] s1_q, s2_q;

    always_ff @(posedge clk) begin
        s1_q <= (seed_i ^ (seed_i >> 55)) * MURMUR_C1;
    end

    logic [63:0] s1x;
    always_comb s1x = s1_q ^ (s1_q >> 32);

    always_ff @(posedge clk) s2_q <= s1x * MURMUR_C2;

    always_comb seed_o = s2_q ^ (s2_q >> 15);
endmodule

// ---------------------------------------------------------------------------
// map_index: finalizer, then a multiply-high reduction into [0, BUFFER_SIZE).
//
// The reduction is ((x as u128) * BUFFER_SIZE) >> 64. BUFFER_SIZE is 33,984,
// which is 16 bits, so this is a 64x16 product and we take its top 16 bits --
// not a 128-bit multiply. This is the cheapest expensive-looking operation in
// the whole algorithm.
// ---------------------------------------------------------------------------
module xelis_map_index (
    input  logic        clk,
    input  logic [63:0] x,
    output logic [15:0] idx
);
    import xelis_pkg::*;

    logic [63:0] m_q;
    always_ff @(posedge clk) m_q <= (x ^ (x >> 33)) * MURMUR_C1;

    logic [79:0] p;
    always_comb p = m_q * 64'(BUFFER_SIZE);

    always_ff @(posedge clk) idx <= p[79:64];
endmodule
