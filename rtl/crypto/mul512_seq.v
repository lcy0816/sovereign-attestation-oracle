`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// mul512_seq — 256x256 -> 512-bit sequential multiplier (shift-and-add).
// 256 cycles. done is a 1-cycle pulse; p is held until next start.
// ---------------------------------------------------------------------------
module mul512_seq (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,      // pulse: latch a,b
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg          done,       // 1-cycle pulse
    output reg  [511:0] p
);

localparam S_IDLE = 1'd0, S_RUN = 1'd1;

reg        state;
reg [511:0] acc;
reg [511:0] aa;
reg [255:0] bb;
reg [7:0]   cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        done  <= 1'b0;
        p     <= 512'd0;
        acc   <= 512'd0;
        cnt   <= 8'd0;
    end else begin
        done <= 1'b0;
        case (state)
        S_IDLE: begin
            if (start) begin
                acc   <= 512'd0;
                aa    <= {256'd0, a};
                bb    <= b;
                cnt   <= 8'd0;
                state <= S_RUN;
            end
        end
        S_RUN: begin
            if (cnt == 8'd255) begin
                done  <= 1'b1;
                p     <= bb[0] ? (acc + aa) : acc;
                state <= S_IDLE;
            end else begin
                if (bb[0]) acc <= acc + aa;
                aa  <= aa << 1;
                bb  <= bb >> 1;
                cnt <= cnt + 8'd1;
            end
        end
        default: state <= S_IDLE;
        endcase
    end
end

endmodule
