`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// sha512_core — iterative SHA-512 (FIPS 180-4), synthesizable.
//
// Streaming interface: pulse start with total_len, then feed total_len
// bytes (first byte first) whenever data_ready is high. The empty message
// (total_len = 0) is handled with no special casing. Padding and the
// 128-bit length suffix are generated internally.
//
// digest[511:0] is big-endian: digest[511:504] = first output byte.
// done pulses for 1 cycle when digest is valid; digest is held until the
// next start. One compression round per cycle (80 cycles/block).
// ---------------------------------------------------------------------------
module sha512_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,        // pulse: latch total_len, begin new hash
    input  wire [63:0] total_len,    // message length in bytes
    input  wire [7:0]  data_in,      // message byte, first byte first
    input  wire        data_valid,
    output wire        data_ready,   // core accepts data_in this cycle
    output reg         done,         // 1-cycle pulse: digest valid
    output reg [511:0] digest        // big-endian: digest[511:504] = byte 0
);

`include "sha512_consts.vh"

localparam SIDLE = 3'd0, SABSRB = 3'd1, SCOMP = 3'd2, SPAD = 3'd3,
           SDONE = 3'd4;
// comp_ret: what to do after a compression finishes
localparam RET_ABSORB = 2'd0, RET_PADFRESH = 2'd1, RET_DONE = 2'd2,
           RET_LENONLY = 2'd3;

reg [2:0]  state;
reg [1:0]  comp_ret;
reg [63:0] h0, h1, h2, h3, h4, h5, h6, h7;
reg [63:0] a, b, c, d, e, f, g, hh;
reg [63:0] w0, w1, w2, w3, w4, w5, w6, w7,
           w8, w9, w10, w11, w12, w13, w14, w15;
reg [1023:0] blk;
reg [6:0]    bcnt;        // message bytes collected in current block
reg [63:0]   remaining;   // message bytes still to absorb
reg [63:0]   msg_len;     // total message length, latched at start
reg [6:0]    round;       // 0..79
reg          comp_run;    // compression round engine active

function [63:0] rotr(input [63:0] x, input [5:0] n);
    rotr = (x >> n) | (x << (64 - n));
endfunction

// message schedule (w0 holds W[t])
wire [63:0] ws0  = rotr(w1, 1)  ^ rotr(w1, 8)  ^ (w1 >> 7);
wire [63:0] ws1  = rotr(w14, 19) ^ rotr(w14, 61) ^ (w14 >> 6);
wire [63:0] wnew = ws1 + w9 + ws0 + w0;

// round function
wire [63:0] bigS1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41);
wire [63:0] ch    = (e & f) ^ (~e & g);
wire [63:0] T1    = hh + bigS1 + ch + sha512_K(round) + w0;
wire [63:0] bigS0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39);
wire [63:0] maj   = (a & b) ^ (a & c) ^ (b & c);
wire [63:0] T2    = bigS0 + maj;
wire [63:0] na    = T1 + T2;   // next a
wire [63:0] ne    = d + T1;    // next e

assign data_ready = (state == SABSRB);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= SIDLE;
        done      <= 1'b0;
        digest    <= 512'd0;
        comp_run  <= 1'b0;
        comp_ret  <= RET_ABSORB;
        bcnt      <= 7'd0;
        remaining <= 64'd0;
        blk       <= 1024'd0;
    end else begin
        done <= 1'b0;
        case (state)
        SIDLE: begin
            if (start) begin
                h0 <= SHA512_IV0; h1 <= SHA512_IV1; h2 <= SHA512_IV2; h3 <= SHA512_IV3;
                h4 <= SHA512_IV4; h5 <= SHA512_IV5; h6 <= SHA512_IV6; h7 <= SHA512_IV7;
                remaining <= total_len;
                msg_len   <= total_len;
                bcnt <= 7'd0;
                blk  <= 1024'd0;
                state <= (total_len == 64'd0) ? SPAD : SABSRB;
            end
        end
        SABSRB: begin
            if (data_valid) begin
                blk[1023 - 8*bcnt -: 8] <= data_in;
                remaining <= remaining - 64'd1;
                if (remaining == 64'd1) begin
                    // last message byte
                    if (bcnt == 7'd127) begin
                        comp_ret <= RET_PADFRESH;  // full block; pad a fresh one
                        state    <= SCOMP;
                    end else begin
                        bcnt  <= bcnt + 7'd1;
                        state <= SPAD;
                    end
                end else begin
                    if (bcnt == 7'd127) begin
                        comp_ret <= RET_ABSORB;    // full block, more coming
                        // (blk is NOT cleared here; SCOMP zeroes it after load)
                        state <= SCOMP;
                    end else begin
                        bcnt <= bcnt + 7'd1;
                    end
                end
            end
        end
        SPAD: begin
            // bcnt = message bytes in blk (0..127); rest of blk is zero.
            // append 0x80, then 128-bit big-endian bit length at bytes 112..127.
            // if bcnt > 111 there is no room for the length: pad this block
            // and compress, then emit the length in a fresh block.
            blk[1023 - 8*bcnt -: 8] <= 8'h80;
            if (bcnt > 7'd111) begin
                // 0x80 placed, but no room for length: compress, then a
                // length-only fresh block (no second 0x80)
                comp_ret <= RET_LENONLY;
                state    <= SCOMP;
            end else begin
                blk[127:64] <= 64'd0;
                blk[63:0]   <= msg_len << 3;   // 128-bit length, high 64 = 0
                comp_ret <= RET_DONE;
                state    <= SCOMP;
            end
        end
        SCOMP: begin
            if (!comp_run) begin
                // load schedule and working variables
                w0<=blk[1023:960];  w1<=blk[959:896];  w2<=blk[895:832];  w3<=blk[831:768];
                w4<=blk[767:704];   w5<=blk[703:640];  w6<=blk[639:576];  w7<=blk[575:512];
                w8<=blk[511:448];   w9<=blk[447:384];  w10<=blk[383:320]; w11<=blk[319:256];
                w12<=blk[255:192];  w13<=blk[191:128]; w14<=blk[127:64];  w15<=blk[63:0];
                a<=h0; b<=h1; c<=h2; d<=h3; e<=h4; f<=h5; g<=h6; hh<=h7;
                round <= 7'd0;
                comp_run <= 1'b1;
            end else begin
                // one round
                hh<=g; g<=f; f<=e; e<=ne;
                d<=c;  c<=b; b<=a; a<=na;
                w0<=w1; w1<=w2; w2<=w3; w3<=w4; w4<=w5; w5<=w6; w6<=w7; w7<=w8;
                w8<=w9; w9<=w10; w10<=w11; w11<=w12; w12<=w13; w13<=w14; w14<=w15;
                w15 <= wnew;
                if (round == 7'd79) begin
                    comp_run <= 1'b0;
                    // feed: h[i] += new working var (na/ne are this round's)
                    h0 <= h0 + na; h1 <= h1 + a; h2 <= h2 + b; h3 <= h3 + c;
                    h4 <= h4 + ne; h5 <= h5 + e; h6 <= h6 + f; h7 <= h7 + g;
                    case (comp_ret)
                    RET_ABSORB:   begin blk <= 1024'd0; bcnt <= 7'd0; state <= SABSRB; end
                    RET_PADFRESH: begin blk <= 1024'd0; bcnt <= 7'd0; state <= SPAD; end
                    RET_LENONLY:  begin
                        // fresh block: zeros + 128-bit length (0x80 already emitted)
                        blk <= {896'd0, 64'd0, msg_len << 3};
                        comp_ret <= RET_DONE;
                        // state stays SCOMP: next cycle reloads blk, compresses
                    end
                    default:      state <= SDONE;   // RET_DONE
                    endcase
                end else begin
                    round <= round + 7'd1;
                end
            end
        end
        SDONE: begin
            done   <= 1'b1;
            digest <= {h0, h1, h2, h3, h4, h5, h6, h7};
            state  <= SIDLE;
        end
        default: state <= SIDLE;
        endcase
    end
end

endmodule
