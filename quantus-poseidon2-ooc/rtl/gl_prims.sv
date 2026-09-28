// SPDX-License-Identifier: MIT
//
// Goldilocks multiplier, S-box and Poseidon2 rounds, each synthesisable alone
// so its DSP cost can be measured rather than estimated.
//
// NOT VERIFIED against the Rust reference. Area and timing only.

// ---------------------------------------------------------------------------
// Delay line. SHREG_EXTRACT="no" for the same reason as the BLAKE2b work: an
// SRL replaces N register hops with one hop into whatever SLICEM was free, and
// phys_opt cannot undo it. See 00-MISTAKES-AND-REMINDERS.md entry 32.
// ---------------------------------------------------------------------------
module gl_delay #(
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
// Goldilocks multiply: full 64x64 product, then the cheap reduction.
// THIS is where every DSP goes. Latency 3.
// ---------------------------------------------------------------------------
module gl_mul
    import gl_pkg::*;
(
    input  logic        clk,
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic [63:0] y
);
    localparam int unsigned LAT = 3;

    logic [127:0] p1, p2;
    always_ff @(posedge clk) begin
        p1 <= a * b;          // 128-bit context: full product, DSPs inferred
        p2 <= p1;
        y  <= gl_reduce128(p2);
    end
endmodule

// ---------------------------------------------------------------------------
// Multiply by a COMPILE-TIME CONSTANT. Separated from gl_mul on purpose: the
// internal linear layer does 12 of these per internal round, and a constant
// multiplier can be markedly cheaper than a general one. Measuring them apart
// is the only way to know by how much.
// ---------------------------------------------------------------------------
module gl_mul_const
    import gl_pkg::*;
#(
    // MATRIX_DIAG[0]. The default was 64'h1 and the OOC run duly reported
    // 0 DSPs and 845 MHz for a multiply by one -- the default-parameter trap
    // from the BLAKE2b work, hit again.
    parameter logic [63:0] K = 64'hc3b6c08e23ba9300
) (
    input  logic        clk,
    input  logic [63:0] a,
    output logic [63:0] y
);
    logic [127:0] p1, p2;
    always_ff @(posedge clk) begin
        p1 <= a * K;
        p2 <= p1;
        y  <= gl_reduce128(p2);
    end
endmodule

// ---------------------------------------------------------------------------
// S-box: x^7, exactly as goldilocks.rs exp7() computes it.
//     let x2 = self.square();  let x3 = x2 * *self;
//     let x4 = x2.square();    x3 * x4
// FOUR multiplies, but only THREE deep: x2, then {x3, x4} in parallel, then
// the product. Latency 3 * gl_mul.
// ---------------------------------------------------------------------------
module gl_exp7
    import gl_pkg::*;
(
    input  logic        clk,
    input  logic [63:0] x,
    output logic [63:0] y
);
    localparam int unsigned MUL_LAT = 3;

    logic [63:0] x2, x_d, x3, x4;

    gl_mul u_x2 (.clk(clk), .a(x),  .b(x),  .y(x2));

    // x must survive the first multiply to meet x2.
    gl_delay #(.W(64), .N(MUL_LAT)) u_dx (.clk(clk), .d(x), .q(x_d));

    gl_mul u_x3 (.clk(clk), .a(x2), .b(x_d), .y(x3));
    gl_mul u_x4 (.clk(clk), .a(x2), .b(x2),  .y(x4));

    gl_mul u_y  (.clk(clk), .a(x3), .b(x4),  .y(y));
endmodule

// ---------------------------------------------------------------------------
// One EXTERNAL (full) round: add round constants, 12 S-boxes, external linear
// layer. The linear layer is adds and doublings only -- no multiplier.
// ---------------------------------------------------------------------------
module pos2_external_round
    import gl_pkg::*;
(
    input  logic        clk,
    input  logic [63:0] s_in  [0:11],
    output logic [63:0] s_out [0:11]
);
    logic [63:0] rc [0:11];
    logic [63:0] sb [0:11];

    // state[i] += rc[i]; state[i] = state[i].exp7();
    for (genvar i = 0; i < 12; i++) begin : g_sbox
        always_comb rc[i] = gl_add(s_in[i], RC0[i]);
        gl_exp7 u_sb (.clk(clk), .x(rc[i]), .y(sb[i]));
    end

    // apply_mat4 on each 4-element chunk, transcribed from poseidon2.rs.
    logic [63:0] m [0:11];
    for (genvar c = 0; c < 3; c++) begin : g_mat4
        logic [63:0] t01, t23, t0123, t01123, t01233;
        always_comb begin
            t01    = gl_add(sb[4*c+0], sb[4*c+1]);
            t23    = gl_add(sb[4*c+2], sb[4*c+3]);
            t0123  = gl_add(t01, t23);
            t01123 = gl_add(t0123, sb[4*c+1]);
            t01233 = gl_add(t0123, sb[4*c+3]);
            m[4*c+3] = gl_add(t01233, gl_dbl(sb[4*c+0]));
            m[4*c+1] = gl_add(t01123, gl_dbl(sb[4*c+2]));
            m[4*c+0] = gl_add(t01123, t01);
            m[4*c+2] = gl_add(t01233, t23);
        end
    end

    // sums[k] = sum of m[j+k] for j in {0,4,8};  state[i] += sums[i % 4]
    logic [63:0] sums [0:3];
    for (genvar k = 0; k < 4; k++) begin : g_sums
        always_comb sums[k] = gl_add(gl_add(m[k], m[4+k]), m[8+k]);
    end

    for (genvar i = 0; i < 12; i++) begin : g_out
        always_ff @(posedge clk) s_out[i] <= gl_add(m[i], sums[i % 4]);
    end
endmodule

// ---------------------------------------------------------------------------
// One INTERNAL (partial) round: one S-box on lane 0, then the internal linear
// layer -- 12 constant multiplies plus a full-width sum.
//     let sum = state.iter().sum();
//     state[i] = sum + state[i] * matrix_diag[i];
// ---------------------------------------------------------------------------
module pos2_internal_round
    import gl_pkg::*;
(
    input  logic        clk,
    input  logic [63:0] s_in  [0:11],
    output logic [63:0] s_out [0:11]
);
    localparam int unsigned SBOX_LAT  = 9;   // 3 gl_mul deep
    localparam int unsigned CMUL_LAT  = 3;

    // state[0] += rc; state[0] = exp7(state[0]);
    logic [63:0] rc0, sb0;
    always_comb rc0 = gl_add(s_in[0], RC0[0]);
    gl_exp7 u_sb0 (.clk(clk), .x(rc0), .y(sb0));

    // The other 11 lanes are untouched by the S-box but must arrive together.
    logic [63:0] s_al [0:11];
    assign s_al[0] = sb0;
    for (genvar i = 1; i < 12; i++) begin : g_align
        gl_delay #(.W(64), .N(SBOX_LAT)) u_d (.clk(clk), .d(s_in[i]), .q(s_al[i]));
    end

    // sum over the whole state
    logic [63:0] sum_l1 [0:5];
    logic [63:0] sum_l2 [0:2];
    logic [63:0] sum_all;
    for (genvar i = 0; i < 6; i++) begin : g_s1
        always_comb sum_l1[i] = gl_add(s_al[2*i], s_al[2*i+1]);
    end
    for (genvar i = 0; i < 3; i++) begin : g_s2
        always_comb sum_l2[i] = gl_add(sum_l1[2*i], sum_l1[2*i+1]);
    end
    always_comb sum_all = gl_add(gl_add(sum_l2[0], sum_l2[1]), sum_l2[2]);

    // state[i] * matrix_diag[i]  -- twelve CONSTANT multiplies
    logic [63:0] dm [0:11];
    logic [63:0] sum_d;
    for (genvar i = 0; i < 12; i++) begin : g_diag
        gl_mul_const #(.K(MATRIX_DIAG[i])) u_cm (.clk(clk), .a(s_al[i]), .y(dm[i]));
    end
    gl_delay #(.W(64), .N(CMUL_LAT)) u_ds (.clk(clk), .d(sum_all), .q(sum_d));

    for (genvar i = 0; i < 12; i++) begin : g_out
        always_ff @(posedge clk) s_out[i] <= gl_add(sum_d, dm[i]);
    end
endmodule

// ---------------------------------------------------------------------------
// The same constant multiply with DSPs forbidden. If the 22 internal rounds'
// 12 constant multiplies can live in LUTs, they stop competing with the S-boxes
// for the 5,640 DSPs that set the whole ceiling -- worth about a third of the
// multiply budget, so worth measuring rather than assuming.
// ---------------------------------------------------------------------------
module gl_mul_const_lut
    import gl_pkg::*;
#(
    parameter logic [63:0] K = 64'hc3b6c08e23ba9300
) (
    input  logic        clk,
    input  logic [63:0] a,
    output logic [63:0] y
);
    (* use_dsp = "no" *) logic [127:0] p1;
    logic [127:0] p2;
    always_ff @(posedge clk) begin
        p1 <= a * K;
        p2 <= p1;
        y  <= gl_reduce128(p2);
    end
endmodule
