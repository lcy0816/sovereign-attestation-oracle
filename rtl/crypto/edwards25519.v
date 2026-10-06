`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// edwards25519 — variable-base scalar multiplication k*P on Edwards25519.
//
// Uses the unified extended-coordinate addition formula (Hisil et al.):
//   A=(Y1-X1)(Y2-X2), B=(Y1+X1)(Y2+X2), C=T1*2d*T2, D=Z1*2*Z2,
//   E=B-A, F=D-C, G=D+C, H=B+A,
//   X3=E*F, Y3=G*H, Z3=F*G, T3=E*H.
// Doubling is performed as P+P via the same formula.
//
// Px, Py are big-endian field elements (< p). k is an integer, k[0] = LSB.
// Rx, Ry are big-endian. done is a 1-cycle pulse.
//
// Cycle budget: ~9 muls (34 cyc) per point add; 256 double-and-add steps;
// inversion ~255 sq + ~128 mul. Total ~200k cycles worst case.
// ---------------------------------------------------------------------------
module edwards25519 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,       // pulse: latch Px,Py,k; begin
    input  wire [255:0] Px,          // base point x, big-endian
    input  wire [255:0] Py,          // base point y, big-endian
    input  wire [255:0] k,           // scalar, k[0] = LSB
    output reg          done,        // 1-cycle pulse: Rx,Ry valid
    output reg  [255:0] Rx,          // result x, big-endian
    output reg  [255:0] Ry           // result y, big-endian
);

// 2*d mod p (d = -121665 * inv(121666)), big-endian
localparam [255:0] D2 = 256'h2406d9dc56dffce7198e80f2eef3d13000e0149a8283b156ebd69b9426b2f159;
// p-2 for Fermat inversion
localparam [255:0] PMINUS2 = 256'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeb;

// ---- state encoding ----
localparam S_IDLE=5'd0,  S_INIT=5'd1,   S_INIT2=5'd2,  S_DBL_COPY=5'd3,
           S_BASE_COPY=5'd4, A_TA=5'd5,  A_TB=5'd6,     A_TT=5'd7,
           A_TC=5'd8,   A_TZ=5'd9,   A_X=5'd10,    A_Y=5'd11,
           A_Z=5'd12,   A_T=5'd13,   S_BIT_TEST=5'd14, S_NEXT_BIT=5'd15,
           S_INV_START=5'd16, S_INV_SQ=5'd17, S_INV_CHK=5'd18,
           S_INV_SHIFT=5'd19, S_INV_X=5'd20, S_INV_Y=5'd21,
           S_MULW=5'd22, S_DONE=5'd23;

localparam DST_TA=4'd0, DST_TB=4'd1, DST_TC=4'd2, DST_TT=4'd3,
           DST_X=4'd4,  DST_Y=4'd5,  DST_Z=4'd6,  DST_T=4'd7,
           DST_BT=4'd8, DST_ZI=4'd9, DST_RX=4'd10, DST_RY=4'd11;

reg [4:0] state, mul_ret, add_ret;
reg [3:0] mul_dst;
reg [7:0] bit_idx;
reg [7:0] inv_cnt;

// accumulator (extended coords), base point, second operand
reg [255:0] X, Y, Z, T;
reg [255:0] BX, BY, BZ, BT;
reg [255:0] CX, CY, CZ, CT;
// formula temps
reg [255:0] ta, tb, tc, tt;
// inversion
reg [255:0] zi, exp;
// latched scalar
reg [255:0] kk;

// field multiplier interface
reg  [255:0] fm_a, fm_b;
reg           fm_start;
wire          fm_done;
wire [255:0]  fm_p;

curve25519_fmul u_fmul (
    .clk(clk), .rst_n(rst_n),
    .start(fm_start), .a(fm_a), .b(fm_b),
    .done(fm_done), .p(fm_p)
);

// combinational sums/differences
wire [255:0] ymx, ypx, cymx, cypx, w_td, w_te, w_tf, w_tg, w_th;
curve25519_fsub fs_ymx (.a(Y),  .b(X),  .d(ymx));
curve25519_fadd fa_ypx (.a(Y),  .b(X),  .s(ypx));
curve25519_fsub fs_cymx(.a(CY), .b(CX), .d(cymx));
curve25519_fadd fa_cypx(.a(CY), .b(CX), .s(cypx));
curve25519_fadd fa_td  (.a(tt),   .b(tt),   .s(w_td));
curve25519_fsub fs_te  (.a(tb),   .b(ta),   .d(w_te));
curve25519_fsub fs_tf  (.a(w_td),  .b(tc),   .d(w_tf));
curve25519_fadd fa_tg  (.a(w_td),  .b(tc),   .s(w_tg));
curve25519_fadd fa_th  (.a(tb),   .b(ta),   .s(w_th));

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        done  <= 1'b0;
        fm_start <= 1'b0;
        Rx <= 256'd0; Ry <= 256'd0;
    end else begin
        done <= 1'b0;
        case (state)
        S_IDLE: begin
            if (start) begin
                BX <= Px; BY <= Py; BZ <= 256'd1;
                X <= 256'd0; Y <= 256'd1; Z <= 256'd1; T <= 256'd0; // identity
                kk <= k;
                bit_idx <= 8'd255;
                // BT = BX*BY
                fm_a <= Px; fm_b <= Py; fm_start <= 1'b1;
                mul_dst <= DST_BT; mul_ret <= S_INIT2;
                state <= S_MULW;
            end
        end
        S_INIT2: begin
            state <= S_DBL_COPY;
        end
        // ---- doubling: C <= accum, then ADD ----
        S_DBL_COPY: begin
            CX <= X; CY <= Y; CZ <= Z; CT <= T;
            add_ret <= S_BIT_TEST;
            state <= A_TA;
        end
        // ---- add base: C <= base, then ADD ----
        S_BASE_COPY: begin
            CX <= BX; CY <= BY; CZ <= BZ; CT <= BT;
            add_ret <= S_NEXT_BIT;
            state <= A_TA;
        end
        // ---- unified ADD: (X,Y,Z,T) <= (X,Y,Z,T)+(CX,CY,CZ,CT) ----
        A_TA: begin // ta = (Y-X)*(CY-CX)
            fm_a <= ymx; fm_b <= cymx; fm_start <= 1'b1;
            mul_dst <= DST_TA; mul_ret <= A_TB; state <= S_MULW;
        end
        A_TB: begin // tb = (Y+X)*(CY+CX)
            fm_a <= ypx; fm_b <= cypx; fm_start <= 1'b1;
            mul_dst <= DST_TB; mul_ret <= A_TT; state <= S_MULW;
        end
        A_TT: begin // tt = T*CT
            fm_a <= T; fm_b <= CT; fm_start <= 1'b1;
            mul_dst <= DST_TT; mul_ret <= A_TC; state <= S_MULW;
        end
        A_TC: begin // tc = tt*2d
            fm_a <= tt; fm_b <= D2; fm_start <= 1'b1;
            mul_dst <= DST_TC; mul_ret <= A_TZ; state <= S_MULW;
        end
        A_TZ: begin // tt = Z*CZ
            fm_a <= Z; fm_b <= CZ; fm_start <= 1'b1;
            mul_dst <= DST_TT; mul_ret <= A_X; state <= S_MULW;
        end
        A_X: begin // X = te*tf  (te,tf,... are wires from ta,tb,tc,tt)
            fm_a <= w_te; fm_b <= w_tf; fm_start <= 1'b1;
            mul_dst <= DST_X; mul_ret <= A_Y; state <= S_MULW;
        end
        A_Y: begin // Y = tg*th
            fm_a <= w_tg; fm_b <= w_th; fm_start <= 1'b1;
            mul_dst <= DST_Y; mul_ret <= A_Z; state <= S_MULW;
        end
        A_Z: begin // Z = tf*tg
            fm_a <= w_tf; fm_b <= w_tg; fm_start <= 1'b1;
            mul_dst <= DST_Z; mul_ret <= A_T; state <= S_MULW;
        end
        A_T: begin // T = te*th
            fm_a <= w_te; fm_b <= w_th; fm_start <= 1'b1;
            mul_dst <= DST_T; mul_ret <= add_ret; state <= S_MULW;
        end
        S_BIT_TEST: begin
            if (kk[bit_idx]) state <= S_BASE_COPY;
            else             state <= S_NEXT_BIT;
        end
        S_NEXT_BIT: begin
            if (bit_idx == 8'd0) state <= S_INV_START;
            else begin bit_idx <= bit_idx - 8'd1; state <= S_DBL_COPY; end
        end
        // ---- Fermat inversion: zi = Z^(p-2) ----
        S_INV_START: begin
            zi <= 256'd1;
            exp <= PMINUS2 << 1;   // align so exp[255] = bit 254 of p-2
            inv_cnt <= 8'd255;
            state <= S_INV_SQ;
        end
        S_INV_SQ: begin // zi = zi^2
            fm_a <= zi; fm_b <= zi; fm_start <= 1'b1;
            mul_dst <= DST_ZI; mul_ret <= S_INV_CHK; state <= S_MULW;
        end
        S_INV_CHK: begin
            if (exp[255]) begin // zi = zi * Z
                fm_a <= zi; fm_b <= Z; fm_start <= 1'b1;
                mul_dst <= DST_ZI; mul_ret <= S_INV_SHIFT; state <= S_MULW;
            end else begin
                state <= S_INV_SHIFT;
            end
        end
        S_INV_SHIFT: begin
            exp <= exp << 1;
            if (inv_cnt == 8'd1) state <= S_INV_X;
            else begin inv_cnt <= inv_cnt - 8'd1; state <= S_INV_SQ; end
        end
        S_INV_X: begin // Rx = X * zi
            fm_a <= X; fm_b <= zi; fm_start <= 1'b1;
            mul_dst <= DST_RX; mul_ret <= S_INV_Y; state <= S_MULW;
        end
        S_INV_Y: begin // Ry = Y * zi
            fm_a <= Y; fm_b <= zi; fm_start <= 1'b1;
            mul_dst <= DST_RY; mul_ret <= S_DONE; state <= S_MULW;
        end
        // ---- shared multiplier wait ----
        S_MULW: begin
            fm_start <= 1'b0;
            if (fm_done) begin
                case (mul_dst)
                DST_TA: ta <= fm_p;
                DST_TB: tb <= fm_p;
                DST_TC: tc <= fm_p;
                DST_TT: tt <= fm_p;
                DST_X:  X  <= fm_p;
                DST_Y:  Y  <= fm_p;
                DST_Z:  Z  <= fm_p;
                DST_T:  T  <= fm_p;
                DST_BT: BT <= fm_p;
                DST_ZI: zi <= fm_p;
                DST_RX: Rx <= fm_p;
                DST_RY: Ry <= fm_p;
                default: ;
                endcase
                state <= mul_ret;
            end
        end
        S_DONE: begin
            done  <= 1'b1;
            state <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
