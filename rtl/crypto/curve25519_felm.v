`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// curve25519_felm — GF(2^255-19) field arithmetic for Curve25519.
//
// Big-endian 256-bit vectors throughout (bit 255 = MSB). All inputs must be
// < 2^256; every output is fully reduced mod p = 2^255-19 (< 2^255).
//
// Complete GF(2^255-19) field arithmetic layer for Curve25519 and Ed25519.
//
// Modules:
//   curve25519_fadd : s = (a+b) mod p   (combinational)
//   curve25519_fsub : d = (a-b) mod p   (combinational)
//   curve25519_fmul : p = (a*b) mod p   (sequential)
//
// fmul micro-architecture: 8-bit digit-serial schoolbook multiply into a
// 512-bit accumulator (32 cycles), then a two-fold reduction using
// 2^255 == 19 (mod p):
//     P = lo + 2^255*hi  ->  lo + 19*hi            (= t1 < 2^263)
//     t1 = lo2 + 2^255*hi2 -> lo2 + 19*hi2         (= t2 < 2^256)
//     if t2 >= p: t2 -= p                          (result < 2^255)
// Total latency: 34 cycles (1 setup + 32 accumulate + 1 reduce).
// ---------------------------------------------------------------------------

`define P25519 256'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed

// ---- (a+b) mod p, combinational ----
module curve25519_fadd (
    input  wire [255:0] a,
    input  wire [255:0] b,
    output wire [255:0] s
);
    wire [256:0] t = a + b; // < 2^256
    assign s = (t >= {1'b0, `P25519}) ? (t[255:0] - `P25519) : t[255:0];
endmodule

// ---- (a-b) mod p, combinational ----
module curve25519_fsub (
    input  wire [255:0] a,
    input  wire [255:0] b,
    output wire [255:0] d
);
    // Caller must provide a,b < 2^256; output is fully reduced if a,b < p.
    assign d = (a >= b) ? (a - b) : (a + `P25519 - b);
endmodule

// ---- (a*b) mod p, sequential ----
module curve25519_fmul (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,      // 1-cycle pulse; latches a,b
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg          done,       // 1-cycle pulse when p is valid
    output reg  [255:0] p
);
    localparam S_IDLE = 3'd0,
               S_MUL  = 3'd1,
               S_MUL2 = 3'd2,  // accumulate: low 256 bits + carry
               S_MUL3 = 3'd3,  // accumulate: mid 128 bits + carry
               S_MUL4 = 3'd4,  // accumulate: high 128 bits
               S_RED1 = 3'd5,
               S_RED2 = 3'd6,
               S_RED3 = 3'd7;

    reg [2:0]   st;
    reg [511:0] acc;
    reg [255:0] aa;    // latched multiplicand digit source
    reg [255:0] bb;    // latched multiplier
    reg [5:0]   i;
    // Pipeline registers for the two-fold reduction (S_RED1..3).
    // The all-combinational reduction was 135 CARRY4s / 30 ns.
    reg [262:0] t1r;
    reg [255:0] t2r;
    // Pipeline register for the digit multiply (S_MUL -> S_MUL2).
    // The mux+multiply+add in one cycle missed timing by 16 ns.
    reg [263:0] prodr;
    // Pipeline for the 512-bit accumulate (S_MUL2 -> S_MUL3 -> S_MUL4).
    // The full 512-bit add missed by 3.6 ns; split into 256+128+128.
    reg [255:0] acc_lo_r;
    reg         acc_carry_r;
    reg [127:0] acc_mid_r;
    reg         acc_carry2_r;

    // NOTE: bb * aa[8*i+:8] must be computed at full 264-bit precision.
    // In {248'd0, bb*digit} the product is self-determined and iverilog
    // truncates it to 256 bits; the explicit 264-bit register forces the
    // correct width. (Pipelined: computed in S_MUL, consumed in S_MUL2.)

    // Two-fold reduction of acc (acc < 2^512), pipelined over S_RED1..3.
    // Stage 1: t1 = lo1 + 19*hi1  (< 2^263).
    wire [254:0] r1_lo = acc[254:0];
    wire [256:0] r1_hi = acc[511:255];
    wire [262:0] r1_t1 = r1_lo + (r1_hi << 4) + (r1_hi << 1) + r1_hi;
    // Stage 2: t2 = lo2 + 19*hi2  (< 2^256).
    wire [254:0] r2_lo = t1r[254:0];
    wire [7:0]   r2_hi = t1r[262:255];
    wire [255:0] r2_t2 = r2_lo + (r2_hi << 4) + (r2_hi << 1) + r2_hi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            acc  <= 512'd0;
            aa   <= 256'd0;
            bb   <= 256'd0;
            i    <= 6'd0;
            done <= 1'b0;
            p    <= 256'd0;
            t1r  <= 263'd0;
            t2r  <= 256'd0;
            prodr <= 264'd0;
            acc_lo_r <= 256'd0;
            acc_carry_r <= 1'b0;
            acc_mid_r <= 128'd0;
            acc_carry2_r <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (start) begin
                        acc <= 512'd0;
                        aa  <= a;
                        bb  <= b;
                        i   <= 6'd31;  // MSB-first: eliminates barrel shifter
                        st  <= S_MUL;
                    end
                end
                S_MUL: begin
                    // Stage 1: digit select + 256x8 multiply.
                    // (Pipelined: the mux+multiply+accumulate in one cycle
                    // missed 100 MHz by 16 ns.)
                    prodr <= bb * aa[8*i +: 8];
                    st    <= S_MUL2;
                end
                S_MUL2: begin
                    // Stage 2a: low 256 bits of (acc<<8) + prodr.
                    // (acc<<8)[255:0] = {acc[247:0], 8'd0}.
                    {acc_carry_r, acc_lo_r} <= {1'b0, acc[247:0], 8'd0}
                                             + {1'b0, prodr[255:0]};
                    st <= S_MUL3;
                end
                S_MUL3: begin
                    // Stage 2b: bits [383:256] of (acc<<8) + prodr.
                    // (acc<<8)[383:256] = acc[375:248].
                    {acc_carry2_r, acc_mid_r} <= acc[375:248]
                        + {120'd0, prodr[263:256]} + acc_carry_r;
                    st <= S_MUL4;
                end
                S_MUL4: begin
                    // Stage 2c: bits [511:384] (carry-in only; mod 2^512).
                    acc <= {acc[503:376] + acc_carry2_r, acc_mid_r, acc_lo_r};
                    if (i == 6'd0) st <= S_RED1;
                    else begin
                        i  <= i - 6'd1;
                        st <= S_MUL;
                    end
                end
                S_RED1: begin
                    t1r <= r1_t1;
                    st  <= S_RED2;
                end
                S_RED2: begin
                    t2r <= r2_t2;
                    st  <= S_RED3;
                end
                S_RED3: begin
                    p    <= (t2r >= `P25519) ? (t2r - `P25519) : t2r;
                    done <= 1'b1;
                    st   <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
