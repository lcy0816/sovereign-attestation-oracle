`timescale 1ns / 1ps

module uart_rx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx_pin,
    output reg  [7:0] rx_data,
    output reg        rx_valid
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam STATE_IDLE  = 2'b00;
    localparam STATE_START = 2'b01;
    localparam STATE_DATA  = 2'b10;
    localparam STATE_STOP  = 2'b11;

    reg [1:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  rx_shifter;
    reg        rx_sync_1, rx_sync_2;

    // Double-flop synchronizer for asynchronous RX pin
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync_1 <= 1'b1;
            rx_sync_2 <= 1'b1;
        end else begin
            rx_sync_1 <= rx_pin;
            rx_sync_2 <= rx_sync_1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= STATE_IDLE;
            clk_count  <= 16'd0;
            bit_index  <= 3'd0;
            rx_data    <= 8'd0;
            rx_valid   <= 1'b0;
            rx_shifter <= 8'd0;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;
                    if (rx_sync_2 == 1'b0) begin // Start bit detected
                        state <= STATE_START;
                    end
                end

                STATE_START: begin
                    // Sample at the middle of the start bit
                    if (clk_count == (CLKS_PER_BIT / 2)) begin
                        if (rx_sync_2 == 1'b0) begin
                            clk_count <= 16'd0;
                            state     <= STATE_DATA;
                        end else begin
                            state <= STATE_IDLE;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_DATA: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        clk_count               <= 16'd0;
                        rx_shifter[bit_index]   <= rx_sync_2;
                        if (bit_index < 3'd7) begin
                            bit_index <= bit_index + 1'b1;
                        end else begin
                            bit_index <= 3'd0;
                            state     <= STATE_STOP;
                        end
                    end
                end

                STATE_STOP: begin
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        clk_count <= 16'd0;
                        if (rx_sync_2 == 1'b1) begin // Valid stop bit
                            rx_data  <= rx_shifter;
                            rx_valid <= 1'b1;
                        end
                        state <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
