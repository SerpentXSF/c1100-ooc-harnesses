// SPDX-License-Identifier: MIT
//
// Goldilocks field (p = 2^64 - 2^32 + 1) helpers, transcribed from
// Quantus-Network/qp-poseidon src/goldilocks.rs and src/poseidon2.rs.
//
// The point of this package is that NONE of these need a multiplier:
//   - the modular reduction's only "multiply" is by NEG_ORDER = 2^32 - 1,
//     which is a shift and a subtract;
//   - the Poseidon2 external linear layer (apply_mat4) is adds and doublings.
// So every DSP this design consumes belongs to the S-box, which is what the
// out-of-context measurement is for.
//
// NOT VERIFIED against the Rust reference. Area and timing only.

package gl_pkg;

    // goldilocks.rs: pub const P: u64 = 0xFFFF_FFFF_0000_0001;
    localparam logic [63:0] P         = 64'hFFFF_FFFF_0000_0001;
    // goldilocks.rs: const NEG_ORDER: u64 = P.wrapping_neg();  == 2^32 - 1
    localparam logic [63:0] NEG_ORDER = 64'h0000_0000_FFFF_FFFF;

    localparam int unsigned WIDTH           = 12;
    localparam int unsigned EXTERNAL_ROUNDS = 8;
    localparam int unsigned INTERNAL_ROUNDS = 22;

    // poseidon2.rs MATRIX_DIAG. These are arbitrary 64-bit values, so the
    // internal linear layer is 12 CONSTANT multiplies per internal round --
    // cheaper than general multiplies, but not free, and worth measuring
    // separately from the S-box.
    localparam logic [63:0] MATRIX_DIAG [0:11] = '{
        64'hc3b6c08e23ba9300, 64'hd84b5de94a324fb6, 64'h0d0c371c5b35b84f,
        64'h7964f570e7188037, 64'h5daf18bbd996604b, 64'h6743bc47b9595257,
        64'h5528b9362c59bb70, 64'hac45e25b7127b68b, 64'ha2077d7dfbb606b5,
        64'hf3faac6faee378ae, 64'h0c6388b51545e883, 64'hd27dbb6944917b60
    };

    // First row of INITIAL_EXTERNAL_CONSTANTS, used so the measured round is a
    // real one rather than a round with convenient constants.
    localparam logic [63:0] RC0 [0:11] = '{
        64'hc002e770975b1607, 64'hbca51a8dfe14593a, 64'h72938dfbe774f7f9,
        64'he4f2fe29e03234ac, 64'hd5e0ba2f541b6449, 64'hec33b868f3cc46c1,
        64'h486dcb55419d475a, 64'h6c1cb2a358cc24f1, 64'he3f30d509a1436bb,
        64'hd9a64f068dca7c29, 64'he59b3f57aabba1ae, 64'h2a3dd4505b478fdc
    };

    // ---- modular add / sub -------------------------------------------------
    // 2^64 mod p == NEG_ORDER, so a carry out is folded back by adding it.
    function automatic logic [63:0] gl_add(input logic [63:0] a,
                                           input logic [63:0] b);
        logic [64:0] t;
        logic [63:0] s;
        begin
            t = {1'b0, a} + {1'b0, b};
            s = t[63:0] + (t[64] ? NEG_ORDER : 64'd0);
            gl_add = (s >= P) ? (s - P) : s;
        end
    endfunction

    function automatic logic [63:0] gl_sub(input logic [63:0] a,
                                           input logic [63:0] b);
        logic [64:0] d;
        begin
            d = {1'b0, a} - {1'b0, b};
            gl_sub = d[64] ? (d[63:0] - NEG_ORDER) : d[63:0];
        end
    endfunction

    function automatic logic [63:0] gl_dbl(input logic [63:0] a);
        begin
            gl_dbl = gl_add(a, a);
        end
    endfunction

    // ---- reduce128, transcribed line for line ------------------------------
    //   let x_hi_hi = x_hi >> 32;  let x_hi_lo = x_hi & NEG_ORDER;
    //   let (t0, borrow) = x_lo.overflowing_sub(x_hi_hi);
    //   if borrow { t0 -= NEG_ORDER; }
    //   let t1 = x_hi_lo * NEG_ORDER;       <-- (v << 32) - v, NOT a multiplier
    //   let t2 = add_no_canonicalize(t0, t1);
    function automatic logic [63:0] gl_reduce128(input logic [127:0] x);
        logic [63:0] x_lo, x_hi, t0, t1;
        logic [31:0] x_hi_hi, x_hi_lo;
        logic [64:0] sub0, add2;
        begin
            x_lo    = x[63:0];
            x_hi    = x[127:64];
            x_hi_hi = x_hi[63:32];
            x_hi_lo = x_hi[31:0];

            sub0 = {1'b0, x_lo} - {33'b0, x_hi_hi};
            t0   = sub0[64] ? (sub0[63:0] - NEG_ORDER) : sub0[63:0];

            t1   = {x_hi_lo, 32'd0} - {32'd0, x_hi_lo};

            add2 = {1'b0, t0} + {1'b0, t1};
            gl_reduce128 = add2[64] ? (add2[63:0] + NEG_ORDER) : add2[63:0];
        end
    endfunction

endpackage
