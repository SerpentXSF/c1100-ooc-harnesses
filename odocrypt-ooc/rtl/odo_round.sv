// SPDX-License-Identifier: MIT
//
// One Odocrypt round, transcribed from DigiByte's src/crypto/odocrypt.cpp:
//
//   ApplyPbox(Permutation[0]) -> ApplySboxes -> ApplyPbox(Permutation[1])
//   -> ApplyRotations -> ApplyRoundKey
//
// State is 10 x 64 = 640 bits. Odocrypt runs 84 rounds over an 80-byte block.
//
// The round has NO multiplies and NO per-nonce memory. Every rotation, word
// shuffle and mask is a per-epoch constant, so shuffles and rotations are
// WIRING and masks are constant AND/XOR. The only real logic is the S-boxes,
// and the algorithm's own header says the 6-bit ones suit "FPGA logic elements"
// and the 10-bit ones "FPGA RAM elements".
//
// USE_BRAM picks where the 10-bit S-boxes land, which is the open question:
// 84 rounds x 10 large S-boxes per core is 840 ROMs, so the choice decides
// whether BRAM or LUTs is the binding resource.
//
// NOTE the two styles are NOT structurally identical: a block ROM read is
// synchronous, so the BRAM variant has an extra register inside the round.
// That is a real difference, not a measurement artefact.
//
// NOT VERIFIED against the reference. Area and timing only.

// ---------------------------------------------------------------------------
// One 10-bit S-box. Separate module so the rom_style attribute can be a string
// LITERAL -- Vivado rejects a parameter there ("expression must be of a packed
// type"), which reads like a type error rather than an attribute restriction.
// ---------------------------------------------------------------------------
module odo_sbox2 #(
    parameter int IDX      = 0,
    parameter bit USE_BRAM = 1
) (
    input  logic        clk,
    input  logic [9:0]  a,
    output logic [9:0]  q
);
    `include "odo_tables.svh"

    if (USE_BRAM) begin : g_block
        (* rom_style = "block" *) logic [9:0] rom [0:1023];
        initial for (int j = 0; j < 1024; j++) rom[j] = SBOX2[IDX][j];
        always_ff @(posedge clk) q <= rom[a];
    end else begin : g_dist
        (* rom_style = "distributed" *) logic [9:0] rom [0:1023];
        initial for (int j = 0; j < 1024; j++) rom[j] = SBOX2[IDX][j];
        always_comb q = rom[a];
    end
endmodule

// ---------------------------------------------------------------------------
module odo_round #(
    parameter bit USE_BRAM = 1
) (
    input  logic        clk,
    input  logic [63:0] s_in  [0:9],
    output logic [63:0] s_out [0:9]
);
    `include "odo_tables.svh"

    localparam int PBOX_SUBROUNDS = 6;
    localparam int PBOX_M         = 3;
    localparam int ROTATION_COUNT = 6;

    function automatic logic [63:0] rot64(input logic [63:0] x, input int n);
        int m;
        begin
            m = n % 64;
            rot64 = (m == 0) ? x : ((x << m) | (x >> (64 - m)));
        end
    endfunction

    // ---- ApplyPbox: masked swaps, constant word shuffle, constant rotations
    function automatic void pbox(ref logic [63:0] st [0:9], input int which);
        logic [63:0] nx [0:9];
        logic [63:0] swp;
        begin
            for (int sr = 0; sr < PBOX_SUBROUNDS - 1; sr++) begin
                for (int i = 0; i < 5; i++) begin
                    swp       = PMASK[which][sr][i] & (st[2*i] ^ st[2*i+1]);
                    st[2*i]   = st[2*i]   ^ swp;
                    st[2*i+1] = st[2*i+1] ^ swp;
                end
                for (int i = 0; i < 10; i++) nx[(PBOX_M*i) % 10] = st[i];
                for (int i = 0; i < 10; i++) st[i] = nx[i];
                for (int i = 0; i < 5; i++) st[2*i] = rot64(st[2*i], PROT[which][sr][i]);
            end
            for (int i = 0; i < 5; i++) begin
                swp       = PMASK[which][PBOX_SUBROUNDS-1][i] & (st[2*i] ^ st[2*i+1]);
                st[2*i]   = st[2*i]   ^ swp;
                st[2*i+1] = st[2*i+1] ^ swp;
            end
        end
    endfunction

    // ---- ApplyPbox(Permutation[0]) ---------------------------------------
    logic [63:0] p0 [0:9];
    always_comb begin
        for (int i = 0; i < 10; i++) p0[i] = s_in[i];
        pbox(p0, 0);
    end

    // ---- ApplySboxes ------------------------------------------------------
    // Each 64-bit word is four groups of {6-bit sbox, 10-bit sbox}.
    logic [63:0] sb [0:9];
    for (genvar i = 0; i < 10; i++) begin : g_word
        logic [9:0] big_a [0:3];
        logic [9:0] big_q [0:3];
        for (genvar j = 0; j < 4; j++) begin : g_grp
            assign big_a[j] = p0[i][16*j+6 +: 10];
            odo_sbox2 #(.IDX(i), .USE_BRAM(USE_BRAM))
                u_s2 (.clk(clk), .a(big_a[j]), .q(big_q[j]));
            // 6-bit S-box: one LUT6 per output bit, the shape the algorithm
            // was designed around.
            assign sb[i][16*j +: 6] = SBOX1[4*i + j][ p0[i][16*j +: 6] ];
            assign sb[i][16*j+6 +: 10] = big_q[j];
        end
    end

    // The small S-boxes and the pbox output must meet the big S-boxes, which
    // are a cycle late when they are block ROMs.
    logic [63:0] sb_al [0:9];
    if (USE_BRAM) begin : g_align
        logic [63:0] sb_q [0:9];
        always_ff @(posedge clk)
            for (int i = 0; i < 10; i++)
                for (int j = 0; j < 4; j++)
                    sb_q[i][16*j +: 6] <= sb[i][16*j +: 6];
        for (genvar i = 0; i < 10; i++)
            for (genvar j = 0; j < 4; j++) begin
                assign sb_al[i][16*j   +: 6]  = sb_q[i][16*j +: 6];
                assign sb_al[i][16*j+6 +: 10] = sb[i][16*j+6 +: 10];
            end
    end else begin : g_noalign
        for (genvar i = 0; i < 10; i++) assign sb_al[i] = sb[i];
    end

    // ---- ApplyPbox(Permutation[1]), ApplyRotations, ApplyRoundKey ---------
    logic [63:0] p1 [0:9];
    logic [63:0] lm [0:9];
    always_comb begin
        for (int i = 0; i < 10; i++) p1[i] = sb_al[i];
        pbox(p1, 1);
        for (int i = 0; i < 10; i++) lm[i] = p1[(i + 1) % 10];
        for (int i = 0; i < 10; i++)
            for (int j = 0; j < ROTATION_COUNT; j++)
                lm[i] = lm[i] ^ rot64(p1[i], ROTS[j]);
    end

    always_ff @(posedge clk)
        for (int i = 0; i < 10; i++)
            s_out[i] <= lm[i] ^ {63'd0, ROUNDKEY[i]};
endmodule

// Large S-boxes forced into LUTs instead of block RAM.
module odo_round_lut (
    input  logic        clk,
    input  logic [63:0] s_in  [0:9],
    output logic [63:0] s_out [0:9]
);
    odo_round #(.USE_BRAM(1'b0)) u (.clk(clk), .s_in(s_in), .s_out(s_out));
endmodule
