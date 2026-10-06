`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// modL_red — 512-bit mod-L reduction via binary shift-subtract (long division).
//
// L = 2^252 + 27742317777372353535851937790883648493 (Ed25519 group order).
// 512 iterations, 1 cycle each. done is a 1-cycle pulse; r held until next start.
// ---------------------------------------------------------------------------
module modL_red (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,      // pulse: latch v
    input  wire [511:0] v,
    output reg          done,       // 1-cycle pulse
    output reg  [255:0] r           // v mod L
);

localparam [255:0] L =
    256'h1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed;

localparam S_IDLE = 1'd0, S_RUN = 1'd1;

reg        state;
reg [255:0] rem;   // invariant: rem < L
reg [511:0] vv;
reg [9:0]   cnt;

wire [255:0] shifted  = {rem[254:0], vv[511]};
wire [255:0] next_rem = (shifted >= L) ? (shifted - L) : shifted;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        done  <= 1'b0;
        r     <= 256'd0;
        rem   <= 256'd0;
        cnt   <= 10'd0;
    end else begin
        done <= 1'b0;
        case (state)
        S_IDLE: begin
            if (start) begin
                rem   <= 256'd0;
                vv    <= v;
                cnt   <= 10'd512;
                state <= S_RUN;
            end
        end
        S_RUN: begin
            vv  <= vv << 1;
            rem <= next_rem;
            if (cnt == 10'd1) begin
                done  <= 1'b1;
                r     <= next_rem;
                state <= S_IDLE;
            end else begin
                cnt <= cnt - 10'd1;
            end
        end
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
