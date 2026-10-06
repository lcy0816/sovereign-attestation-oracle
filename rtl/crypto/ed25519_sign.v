`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// ed25519_sign — deterministic Ed25519 signer (RFC 8032), synthesizable.
//
//   h    = SHA512(sk); s = clamp(h[0:32]); prefix = h[32:64]
//   A    = s*B
//   r    = SHA512(prefix || M) mod L
//   R    = r*B
//   k    = SHA512(R_enc || A_enc || M) mod L
//   S    = (r + k*s) mod L
//   sig  = R_enc || S_enc
//
// Byte orders: sk/R/S ports are little-endian (bit [7:0] = first byte).
// Field elements inside edwards25519 are big-endian; conversions are done
// here. Message is buffered (2048 bytes max) to allow the three hashes.
// ---------------------------------------------------------------------------
module ed25519_sign (
    input  wire         clk,
    input  wire         rst_n,       // active-low, synchronous release ok
    input  wire         start,       // pulse: latch sk, begin (with msg_empty for empty msg)
    input  wire [255:0] sk,         // 32-byte secret key, sk[7:0] = first byte
    input  wire [7:0]   msg_byte,
    input  wire         msg_valid,   // qualifies msg_byte
    input  wire         msg_last,    // asserted with msg_valid on the last byte
    input  wire         msg_empty,   // pulsed with start when the message is empty
    output wire         msg_ready,   // accept msg_byte when high
    output wire         done,        // signature ready (stays high until next start)
    output wire [255:0] R,           // 32-byte signature R, R[7:0] = first byte
    output wire [255:0] S,           // 32-byte signature S
    output wire         error        // e.g. low-order point; stays high until next start
);

// base point B (big-endian field elements)
localparam [255:0] BX = 256'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a;
localparam [255:0] BY = 256'h6666666666666666666666666666666666666666666666666666666666666658;

// main states
localparam M_IDLE=5'd0, M_RECV=5'd1, M_HASH_SK_SETUP=5'd2, M_SHA_FEED=5'd3,
           M_SHA_WAIT=5'd4, M_S_CLAMP=5'd5, M_MUL_A_SETUP=5'd6, M_MUL_A_WAIT=5'd7,
           M_HASH_R_SETUP=5'd8, M_REDUCE_R_SETUP=5'd9, M_REDUCE_R_WAIT=5'd10,
           M_MUL_R_SETUP=5'd11, M_MUL_R_WAIT=5'd12, M_HASH_K_SETUP=5'd13,
           M_REDUCE_K_SETUP=5'd14, M_REDUCE_K_WAIT=5'd15, M_MUL_KS_SETUP=5'd16,
           M_MUL_KS_WAIT=5'd17, M_REDUCE_S_SETUP=5'd18, M_REDUCE_S_WAIT=5'd19;

localparam FEED_SK=2'd0, FEED_R=2'd1, FEED_K=2'd2;
localparam PHASE_SK=2'd0, PHASE_R=2'd1, PHASE_K=2'd2;

reg [4:0] state;
reg [1:0] feed_mode, sha_phase;

// latched inputs / message buffer
reg [255:0] sk_r;
reg [7:0]  msgbuf [0:2047];
reg [10:0] buf_idx;
reg [11:0] msg_len;

// sha512 interface
reg         sha_start;
reg [63:0]  sha_len;
wire [7:0]  sha_din;
wire        sha_dv;
wire        sha_ready, sha_done;
wire [511:0] sha_digest;

// sha feeder
reg [11:0] feed_idx, feed_total;
reg [7:0]  feed_byte_w;

// scalar mult interface
reg         em_start;
reg [255:0] em_Px, em_Py, em_k;
wire        em_done;
wire [255:0] em_Rx, em_Ry;

// mul512 interface
reg         mul_start;
reg [255:0] mul_a, mul_b;
wire        mul_done;
wire [511:0] mul_p;

// modL interface
reg         modl_start;
reg [511:0] modl_v;
wire        modl_done;
wire [255:0] modl_r;

// working registers
reg [255:0] h_hi, h_lo;
reg [255:0] s_int;
reg [511:0] r_int, kh_int;
reg [255:0] r_mod, k_h;
reg [511:0] prod;
reg [255:0] A_enc, R_enc;
reg [255:0] R_r, S_r;
reg         done_r, error_r;

assign msg_ready = (state == M_RECV);
assign done  = done_r;
assign error = error_r;
assign R = R_r;
assign S = S_r;

// byte-reverse 32 bytes
function [255:0] rev32(input [255:0] x);
    integer i;
    begin
        for (i = 0; i < 32; i = i + 1)
            rev32[8*i +: 8] = x[255 - 8*i -: 8];
    end
endfunction

// byte-reverse 64 bytes
function [511:0] rev64(input [511:0] x);
    integer i;
    begin
        for (i = 0; i < 64; i = i + 1)
            rev64[8*i +: 8] = x[511 - 8*i -: 8];
    end
endfunction

// sha feeder: combinational valid/ready handshake (no 1-cycle stale decision)
assign sha_dv  = (state == M_SHA_FEED) && sha_ready && (feed_idx < feed_total);
assign sha_din = feed_byte_w;

// feed byte selector (combinational)
always @* begin
    case (feed_mode)
    FEED_SK: feed_byte_w = sk_r[feed_idx*8 +: 8];
    FEED_R:  feed_byte_w = (feed_idx < 12'd32) ? h_lo[255 - feed_idx*8 -: 8]
                                              : msgbuf[feed_idx - 12'd32];
    FEED_K:  feed_byte_w = (feed_idx < 12'd32) ? R_enc[feed_idx*8 +: 8]
                           : (feed_idx < 12'd64) ? A_enc[(feed_idx-12'd32)*8 +: 8]
                                                 : msgbuf[feed_idx - 12'd64];
    default: feed_byte_w = 8'd0;
    endcase
end

sha512_core u_sha (
    .clk(clk), .rst_n(rst_n),
    .start(sha_start), .total_len(sha_len),
    .data_in(sha_din), .data_valid(sha_dv),
    .data_ready(sha_ready), .done(sha_done), .digest(sha_digest)
);

edwards25519 u_em (
    .clk(clk), .rst_n(rst_n),
    .start(em_start), .Px(em_Px), .Py(em_Py), .k(em_k),
    .done(em_done), .Rx(em_Rx), .Ry(em_Ry)
);

mul512_seq u_mul (
    .clk(clk), .rst_n(rst_n),
    .start(mul_start), .a(mul_a), .b(mul_b),
    .done(mul_done), .p(mul_p)
);

modL_red u_modl (
    .clk(clk), .rst_n(rst_n),
    .start(modl_start), .v(modl_v),
    .done(modl_done), .r(modl_r)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state   <= M_IDLE;
        done_r  <= 1'b0;
        error_r <= 1'b0;
        R_r <= 256'd0; S_r <= 256'd0;
        sha_start <= 1'b0;
        em_start <= 1'b0; mul_start <= 1'b0; modl_start <= 1'b0;
        buf_idx <= 11'd0; msg_len <= 12'd0;
    end else begin
        case (state)
        M_IDLE: begin
            if (start) begin
                done_r  <= 1'b0;
                error_r <= 1'b0;
                sk_r    <= sk;
                buf_idx <= 11'd0;
                msg_len <= 12'd0;
                state   <= msg_empty ? M_HASH_SK_SETUP : M_RECV;
            end
        end
        M_RECV: begin
            if (msg_valid) begin
                msgbuf[buf_idx] <= msg_byte;
                if (msg_last) begin
                    msg_len <= buf_idx + 12'd1;
                    state   <= M_HASH_SK_SETUP;
                end else begin
                    buf_idx <= buf_idx + 11'd1;
                end
            end
        end
        M_HASH_SK_SETUP: begin
            sha_start  <= 1'b1;
            sha_len    <= 64'd32;
            feed_mode  <= FEED_SK;
            feed_idx   <= 12'd0;
            feed_total <= 12'd32;
            sha_phase  <= PHASE_SK;
            state      <= M_SHA_FEED;
        end
        M_SHA_FEED: begin
            sha_start <= 1'b0;
            // sha_dv/sha_din are combinational; advance on handshake
            if (sha_dv) begin
                if (feed_idx + 12'd1 == feed_total)
                    state <= M_SHA_WAIT;
                else
                    feed_idx <= feed_idx + 12'd1;
            end
        end
        M_SHA_WAIT: begin
            if (sha_done) begin
                case (sha_phase)
                PHASE_SK: begin
                    h_hi  <= sha_digest[511:256];
                    h_lo  <= sha_digest[255:0];
                    state <= M_S_CLAMP;
                end
                PHASE_R: begin
                    r_int <= rev64(sha_digest);
                    state <= M_REDUCE_R_SETUP;
                end
                PHASE_K: begin
                    kh_int <= rev64(sha_digest);
                    state <= M_REDUCE_K_SETUP;
                end
                default: state <= M_IDLE;
                endcase
            end
        end
        M_S_CLAMP: begin
            // clamp h_hi (BE bytes): clear low 3 bits of byte 0,
            // clear bit 7 / set bit 6 of byte 31; then LE integer
            s_int <= rev32({h_hi[255:251], 3'b0, h_hi[247:8], 1'b0, 1'b1, h_hi[5:0]});
            state <= M_MUL_A_SETUP;
        end
        M_MUL_A_SETUP: begin
            em_start <= 1'b1;
            em_Px <= BX; em_Py <= BY; em_k <= s_int;
            state <= M_MUL_A_WAIT;
        end
        M_MUL_A_WAIT: begin
            em_start <= 1'b0;
            if (em_done) begin
                A_enc <= {em_Rx[0], em_Ry[254:0]};
                if (em_Rx == 256'd0 && em_Ry == 256'd1)
                    error_r <= 1'b1;   // identity (shouldn't happen)
                state <= M_HASH_R_SETUP;
            end
        end
        M_HASH_R_SETUP: begin
            sha_start  <= 1'b1;
            sha_len    <= 64'd32 + msg_len;
            feed_mode  <= FEED_R;
            feed_idx   <= 12'd0;
            feed_total <= 12'd32 + msg_len;
            sha_phase  <= PHASE_R;
            state      <= M_SHA_FEED;
        end
        M_REDUCE_R_SETUP: begin
            modl_start <= 1'b1;
            modl_v     <= r_int;
            state      <= M_REDUCE_R_WAIT;
        end
        M_REDUCE_R_WAIT: begin
            modl_start <= 1'b0;
            if (modl_done) begin
                r_mod <= modl_r;
                state <= M_MUL_R_SETUP;
            end
        end
        M_MUL_R_SETUP: begin
            em_start <= 1'b1;
            em_Px <= BX; em_Py <= BY; em_k <= r_mod;
            state <= M_MUL_R_WAIT;
        end
        M_MUL_R_WAIT: begin
            em_start <= 1'b0;
            if (em_done) begin
                R_enc <= {em_Rx[0], em_Ry[254:0]};
                if (em_Rx == 256'd0 && em_Ry == 256'd1)
                    error_r <= 1'b1;
                state <= M_HASH_K_SETUP;
            end
        end
        M_HASH_K_SETUP: begin
            sha_start  <= 1'b1;
            sha_len    <= 64'd64 + msg_len;
            feed_mode  <= FEED_K;
            feed_idx   <= 12'd0;
            feed_total <= 12'd64 + msg_len;
            sha_phase  <= PHASE_K;
            state      <= M_SHA_FEED;
        end
        M_REDUCE_K_SETUP: begin
            modl_start <= 1'b1;
            modl_v     <= kh_int;
            state      <= M_REDUCE_K_WAIT;
        end
        M_REDUCE_K_WAIT: begin
            modl_start <= 1'b0;
            if (modl_done) begin
                k_h   <= modl_r;
                state <= M_MUL_KS_SETUP;
            end
        end
        M_MUL_KS_SETUP: begin
            mul_start <= 1'b1;
            mul_a <= k_h; mul_b <= s_int;
            state <= M_MUL_KS_WAIT;
        end
        M_MUL_KS_WAIT: begin
            mul_start <= 1'b0;
            if (mul_done) begin
                prod  <= mul_p;
                state <= M_REDUCE_S_SETUP;
            end
        end
        M_REDUCE_S_SETUP: begin
            modl_start <= 1'b1;
            modl_v     <= prod + {256'd0, r_mod};
            state      <= M_REDUCE_S_WAIT;
        end
        M_REDUCE_S_WAIT: begin
            modl_start <= 1'b0;
            if (modl_done) begin
                R_r    <= R_enc;
                S_r    <= modl_r;
                done_r <= 1'b1;
                state  <= M_IDLE;
            end
        end
        default: state <= M_IDLE;
        endcase
    end
end

endmodule
