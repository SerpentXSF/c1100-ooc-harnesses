// SPDX-License-Identifier: MIT
// XelisHash v3 stage-3 branch ALU: all 16 data-selected cases, transcribed
// from the `match branch_idx` in src/v3.rs.
//
// NOT VERIFIED against the Rust reference. This exists to be synthesised, so
// that the area and achievable period of the 16 cases can be measured before
// anyone commits to building a miner. Treat every value it produces as
// unverified until a testbench says otherwise.
//
// ---------------------------------------------------------------------------
// The one architectural decision worth arguing about
// ---------------------------------------------------------------------------
// Five of the sixteen cases divide or take a remainder (0, 1, 10, 11, 12, 13
// -- six, counting case 1's u64 remainder). The naive structure instantiates a
// divider per case. But `branch_idx` is known from `result` and `c` at the
// START of the iteration, and exactly one case executes, so the operands can
// be MUXED into a single shared divider instead. That trades six dividers for
// one divider plus a mux, and it is the difference between this datapath
// fitting and not fitting.
//
// The same argument applies to the multiply-high unit (cases 14, 15 share one)
// and to isqrt, where the binding constraint is that no single case needs more
// than two concurrent roots -- so there are two isqrt units, not six.
//
// What the sharing costs is delay registers: operands that a later stage still
// needs have to be carried across the divider's 128 stages. Those registers
// are not waste, they are the iteration state having to exist somewhere --
// the same law that governed the BLAKE2b pipeline, reappearing in a different
// shape. They are the bulk of this module's FF count and they are honest.
// ---------------------------------------------------------------------------

module xelis_branch_alu
    import xelis_pkg::*;
(
    input  logic                clk,

    // Iteration inputs, all valid on the same edge.
    input  logic [63:0]         a_i,
    input  logic [63:0]         b_i,
    input  logic [63:0]         c_i,
    input  logic [63:0]         result_i,
    input  logic                i_i,        // 0..SCRATCHPAD_ITERS-1
    input  logic [J_W-1:0]      j_i,        // 0..BUFFER_SIZE-1
    input  logic [R_W-1:0]      r_i,        // 0..MEMORY_SIZE-1

    output logic [63:0]         v_o
);
    // Total latency: isqrt, then the shared divider, then multiply-high.
    localparam int unsigned L_TOTAL = L_ISQRT + L_DIV + L_MULHI;   // 162

    // -----------------------------------------------------------------------
    // T0 -- register inputs, select the branch, launch isqrt and murmur.
    // -----------------------------------------------------------------------
    logic [63:0] a0, b0, c0, res0;
    logic        i0;
    logic [J_W-1:0] j0;
    logic [R_W-1:0] r0;

    always_ff @(posedge clk) begin
        a0 <= a_i; b0 <= b_i; c0 <= c_i; res0 <= result_i;
        i0 <= i_i; j0 <= j_i; r0 <= r_i;
    end

    // let branch_idx = (result.rotate_left(c as u32) & 0xf) as u8;
    // rotl64(...)[3:0] is illegal -- a function call's return value cannot be
    // part-selected directly. Land it in a variable first.
    logic [63:0] br_rot0;
    logic [3:0]  br0;
    always_comb begin
        br_rot0 = rotl64(res0, c0[5:0]);
        br0     = br_rot0[3:0];
    end

    logic [63:0] i64_0, j64_0;
    always_comb begin
        i64_0 = {63'b0, i0};
        j64_0 = {{(64-J_W){1'b0}}, j0};
    end

    // Two isqrt units. Case 1 and case 2 each need two roots; no case needs
    // more, so two is sufficient for all sixteen.
    logic [63:0] sq0_in, sq1_in;
    always_comb begin
        unique case (br0)
            4'd0:    begin sq0_in = b0 + j64_0;  sq1_in = 64'd0;     end
            4'd1:    begin sq0_in = b0 | 64'd2;  sq1_in = a0 + j64_0; end
            4'd2:    begin sq0_in = a0 + i64_0;  sq1_in = c0 + j64_0; end
            default: begin sq0_in = 64'd0;       sq1_in = 64'd0;     end
        endcase
    end

    // 64 bits now: the reference's isqrt can return 2^32+1.
    logic [63:0] sq0_out, sq1_out;
    xelis_isqrt u_sq0 (.clk(clk), .n(sq0_in), .q(sq0_out));
    xelis_isqrt u_sq1 (.clk(clk), .n(sq1_in), .q(sq1_out));

    // Case 0's divisor: murmurhash3(c ^ result ^ i ^ j) | 1.
    // Murmur is 2 cycles and isqrt is 32, so hold it to align at T1.
    logic [63:0] murm_out, murm_al;
    xelis_murmur3 u_murm (
        .clk(clk), .seed_i(c0 ^ res0 ^ i64_0 ^ j64_0), .seed_o(murm_out)
    );
    xelis_delay #(.W(64), .N(L_ISQRT - L_MURMUR))
        u_dly_murm (.clk(clk), .d(murm_out), .q(murm_al));

    // -----------------------------------------------------------------------
    // Operands carried to T1 (divider issue) and T2 (everything cheap).
    // -----------------------------------------------------------------------
    logic [63:0] a1, b1, c1, res1;
    logic        i1;
    logic [J_W-1:0] j1;
    logic [R_W-1:0] r1;
    logic [3:0]  br1;

    xelis_delay #(.W(64),   .N(L_ISQRT)) u_d1_a  (.clk(clk), .d(a0),   .q(a1));
    xelis_delay #(.W(64),   .N(L_ISQRT)) u_d1_b  (.clk(clk), .d(b0),   .q(b1));
    xelis_delay #(.W(64),   .N(L_ISQRT)) u_d1_c  (.clk(clk), .d(c0),   .q(c1));
    xelis_delay #(.W(64),   .N(L_ISQRT)) u_d1_rs (.clk(clk), .d(res0), .q(res1));
    xelis_delay #(.W(1),    .N(L_ISQRT)) u_d1_i  (.clk(clk), .d(i0),   .q(i1));
    xelis_delay #(.W(J_W),  .N(L_ISQRT)) u_d1_j  (.clk(clk), .d(j0),   .q(j1));
    xelis_delay #(.W(R_W),  .N(L_ISQRT)) u_d1_r  (.clk(clk), .d(r0),   .q(r1));
    xelis_delay #(.W(4),    .N(L_ISQRT)) u_d1_br (.clk(clk), .d(br0),  .q(br1));

    logic [63:0] i64_1, j64_1;
    always_comb begin
        i64_1 = {63'b0, i1};
        j64_1 = {{(64-J_W){1'b0}}, j1};
    end

    // -----------------------------------------------------------------------
    // T1 -- the single shared divider. combine_u64(hi, lo) is {hi, lo}.
    // Every divisor below is forced nonzero by the reference.
    // -----------------------------------------------------------------------
    logic [127:0] dv_num, dv_den;
    logic [127:0] t1_11, t2_11, t1_13, t2_13;

    always_comb begin
        t1_11 = {b1, c1};
        t2_11 = {rotl64(res1, r1[5:0]), a1 | 64'd2};
        t1_13 = {rotl64(res1, r1[5:0]), b1};
        t2_13 = {a1, c1 | 64'd8};
    end

    always_comb begin
        unique case (br1)
            // combine_u64(a+i, isqrt(b+j)) % (murmurhash3(...) | 1)
            4'd0:  begin dv_num = {a1 + i64_1, sq0_out};
                         dv_den = {64'b0, murm_al | 64'd1};           end
            // (c + i) % isqrt(b | 2)
            4'd1:  begin dv_num = {64'b0, c1 + i64_1};
                         dv_den = {64'b0, sq0_out};                   end
            // combine_u64(a, b) % (c | 1)
            4'd10: begin dv_num = {a1, b1};
                         dv_den = {64'b0, c1 | 64'd1};                end
            // combine_u64(b, c) % combine_u64(ROTL(result,r), a|2)
            4'd11: begin dv_num = t1_11;  dv_den = t2_11;             end
            // combine_u64(c, a) / (b | 4)
            4'd12: begin dv_num = {c1, a1};
                         dv_den = {64'b0, b1 | 64'd4};                end
            // combine_u64(ROTL(result,r), b) / combine_u64(a, c|8)
            4'd13: begin dv_num = t1_13;  dv_den = t2_13;             end
            default: begin dv_num = 128'd1; dv_den = 128'd1;          end
        endcase
    end

    logic [127:0] dv_quo, dv_rem;
    xelis_divu #(.W(128)) u_div (
        .clk(clk), .num(dv_num), .den(dv_den), .quo(dv_quo), .rem(dv_rem)
    );

    // The two comparisons that decide whether the division is used at all.
    logic use_div_11, use_div_13;
    always_comb begin
        use_div_11 = !(t2_11 > t1_11);   // case 11: t2 > t1 -> take c
        use_div_13 =  (t1_13 > t2_13);   // case 13: else take a^b
    end

    logic use_div_11_al, use_div_13_al;
    xelis_delay #(.W(1), .N(L_DIV)) u_dv11 (.clk(clk), .d(use_div_11), .q(use_div_11_al));
    xelis_delay #(.W(1), .N(L_DIV)) u_dv13 (.clk(clk), .d(use_div_13), .q(use_div_13_al));

    // Case 1 multiplies the remainder by isqrt(a+j); case 2 is a pure isqrt
    // case. Both need roots carried across the divider.
    logic [63:0] case2_val, case2_val_al;
    always_comb begin
        // (isqrt(a+i) * isqrt(c+j)) ^ (b + i + j)
        case2_val = (sq0_out * sq1_out) ^ (b1 + i64_1 + j64_1);
    end
    xelis_delay #(.W(64), .N(L_DIV)) u_d2_c2 (.clk(clk), .d(case2_val), .q(case2_val_al));

    logic [63:0] sq1_al;
    xelis_delay #(.W(64), .N(L_DIV)) u_d2_sq1 (.clk(clk), .d(sq1_out), .q(sq1_al));

    // -----------------------------------------------------------------------
    // Operands carried to T2. The cheap cases are computed HERE, from delayed
    // operands, rather than computed early and delayed -- that way their
    // results never need a delay line of their own.
    // -----------------------------------------------------------------------
    logic [63:0] a2, b2, c2, res2;
    logic        i2;
    logic [J_W-1:0] j2;
    logic [R_W-1:0] r2;
    logic [3:0]  br2;

    xelis_delay #(.W(64),  .N(L_DIV)) u_d2_a  (.clk(clk), .d(a1),   .q(a2));
    xelis_delay #(.W(64),  .N(L_DIV)) u_d2_b  (.clk(clk), .d(b1),   .q(b2));
    xelis_delay #(.W(64),  .N(L_DIV)) u_d2_c  (.clk(clk), .d(c1),   .q(c2));
    xelis_delay #(.W(64),  .N(L_DIV)) u_d2_rs (.clk(clk), .d(res1), .q(res2));
    xelis_delay #(.W(1),   .N(L_DIV)) u_d2_i  (.clk(clk), .d(i1),   .q(i2));
    xelis_delay #(.W(J_W), .N(L_DIV)) u_d2_j  (.clk(clk), .d(j1),   .q(j2));
    xelis_delay #(.W(R_W), .N(L_DIV)) u_d2_r  (.clk(clk), .d(r1),   .q(r2));
    xelis_delay #(.W(4),   .N(L_DIV)) u_d2_br (.clk(clk), .d(br1),  .q(br2));

    logic [63:0] i64_2, j64_2;
    always_comb begin
        i64_2 = {63'b0, i2};
        j64_2 = {{(64-J_W){1'b0}}, j2};
    end

    // -----------------------------------------------------------------------
    // T2 -- one shared multiply-high unit for cases 14 and 15.
    // -----------------------------------------------------------------------
    logic [127:0] mh_a, mh_b;
    always_comb begin
        unique case (br2)
            // (combine_u64(b, a) * c) >> 64
            4'd14:   begin mh_a = {b2, a2}; mh_b = {64'b0, c2};              end
            // (combine_u64(a, c) * combine_u64(ROTR(result,r), b)) >> 64
            4'd15:   begin mh_a = {a2, c2}; mh_b = {rotr64(res2, r2[5:0]), b2}; end
            default: begin mh_a = 128'd0;   mh_b = 128'd0;                   end
        endcase
    end

    logic [63:0] mh_hi;
    xelis_mulhi_u128 u_mh (.clk(clk), .a(mh_a), .b(mh_b), .hi(mh_hi));

    // Everything else has to survive the multiply-high latency.
    logic [63:0] a3, b3, c3;
    logic [63:0] dvq3, dvr3, c2v3;
    logic [63:0] sq1_3;
    logic        i3;
    logic [J_W-1:0] j3;
    logic [R_W-1:0] r3;
    logic [3:0]  br3;
    logic        ud11_3, ud13_3;

    xelis_delay #(.W(64),  .N(L_MULHI)) u_d3_a  (.clk(clk), .d(a2), .q(a3));
    xelis_delay #(.W(64),  .N(L_MULHI)) u_d3_b  (.clk(clk), .d(b2), .q(b3));
    xelis_delay #(.W(64),  .N(L_MULHI)) u_d3_c  (.clk(clk), .d(c2), .q(c3));
    xelis_delay #(.W(64),  .N(L_MULHI)) u_d3_q  (.clk(clk), .d(dv_quo[63:0]), .q(dvq3));
    xelis_delay #(.W(64),  .N(L_MULHI)) u_d3_r  (.clk(clk), .d(dv_rem[63:0]), .q(dvr3));
    xelis_delay #(.W(64),  .N(L_MULHI)) u_d3_c2 (.clk(clk), .d(case2_val_al), .q(c2v3));
    xelis_delay #(.W(64),  .N(L_MULHI)) u_d3_s1 (.clk(clk), .d(sq1_al), .q(sq1_3));
    xelis_delay #(.W(1),   .N(L_MULHI)) u_d3_i  (.clk(clk), .d(i2), .q(i3));
    xelis_delay #(.W(J_W), .N(L_MULHI)) u_d3_j  (.clk(clk), .d(j2), .q(j3));
    xelis_delay #(.W(R_W), .N(L_MULHI)) u_d3_rr (.clk(clk), .d(r2), .q(r3));
    xelis_delay #(.W(4),   .N(L_MULHI)) u_d3_br (.clk(clk), .d(br2), .q(br3));
    xelis_delay #(.W(1),   .N(L_MULHI)) u_d3_u1 (.clk(clk), .d(use_div_11_al), .q(ud11_3));
    xelis_delay #(.W(1),   .N(L_MULHI)) u_d3_u3 (.clk(clk), .d(use_div_13_al), .q(ud13_3));

    // -----------------------------------------------------------------------
    // T3 -- final selection. Cheap cases evaluate here from delayed operands.
    // -----------------------------------------------------------------------
    logic [63:0] i64_3, j64_3, ij_sum3, v_next;
    always_comb begin
        i64_3 = {63'b0, i3};
        j64_3 = {{(64-J_W){1'b0}}, j3};
        // (i64_3 + j64_3)[5:0] is illegal for the same reason as above.
        ij_sum3 = i64_3 + j64_3;
    end

    always_comb begin
        unique case (br3)
            4'd0:  v_next = dvr3;
            // ROTL((c+i) % isqrt(b|2), i+j) * isqrt(a+j)
            4'd1:  v_next = rotl64(dvr3, ij_sum3[5:0]) * sq1_3;
            4'd2:  v_next = c2v3;
            4'd3:  v_next = (a3 + b3) * c3;
            4'd4:  v_next = (b3 - c3) * a3;
            4'd5:  v_next = c3 - a3 + b3;
            4'd6:  v_next = a3 - b3 + c3;
            4'd7:  v_next = b3 * c3 + a3;
            4'd8:  v_next = c3 * a3 + b3;
            4'd9:  v_next = a3 * b3 * c3;
            4'd10: v_next = dvr3;
            4'd11: v_next = ud11_3 ? dvr3 : c3;
            4'd12: v_next = dvq3;
            4'd13: v_next = ud13_3 ? dvq3 : (a3 ^ b3);
            4'd14: v_next = mh_hi;
            4'd15: v_next = mh_hi;
        endcase
    end

    always_ff @(posedge clk) v_o <= v_next;

endmodule
