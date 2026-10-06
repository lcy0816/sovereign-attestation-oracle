`timescale 1ns / 1ps

module uart_tx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,
    input  wire       tx_start,
    output reg        tx_pin,
    output reg        tx_busy
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam STATE_IDLE  = 2'b00;
    localparam STATE_START = 2'b01;
    localparam STATE_DATA  = 2'b10;
    localparam STATE_STOP  = 2'b11;

    reg [1:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  tx_shifter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= STATE_IDLE;
            clk_count  <= 16'd0;
            bit_index  <= 3'd0;
            tx_shifter <= 8'd0;
            tx_pin     <= 1'b1;
            tx_busy    <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    tx_pin    <= 1'b1;
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;
                    if (tx_start) begin
                        tx_shifter <= tx_data;
                        tx_busy    <= 1'b1;
                        tx_pin     <= 1'b0; // Start bit
                        state      <= STATE_START;
                    end else begin
                        tx_busy    <= 1'b0;
                    end
                end

                STATE_START: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        clk_count <= 16'd0;
                        tx_pin    <= tx_shifter[0];
                        state     <= STATE_DATA;
                    end
                end

                STATE_DATA: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        clk_count <= 16'd0;
                        if (bit_index < 3'd7) begin
                            bit_index <= bit_index + 1'b1;
                            tx_pin    <= tx_shifter[bit_index + 1];
                        end else begin
                            bit_index <= 3'd0;
                            tx_pin    <= 1'b1; // Stop bit
                            state     <= STATE_STOP;
                        end
                    end
                end

                STATE_STOP: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        clk_count <= 16'd0;
                        tx_busy   <= 1'b0;
                        state     <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
