`timescale 1ns / 1ps

module seven_seg_controller (
    input  wire        clk,       // 100 MHz oscillator
    input  wire        rst_n,
    input  wire [31:0] display_val,
    output reg  [7:0]  anode,     // Active-low digit selects
    output reg  [6:0]  seg        // Active-low segment cathodes: CA, CB, CC, CD, CE, CF, CG
);

    // Refresh divider: 100MHz / 2^16 ~= 1525 Hz multiplex clock
    reg [16:0] refresh_counter;
    wire [2:0] active_digit = refresh_counter[16:14];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            refresh_counter <= 17'd0;
        else
            refresh_counter <= refresh_counter + 1'b1;
    end

    reg [3:0] hex_digit;

    // Digit multiplexer
    always @(*) begin
        case (active_digit)
            3'd0: begin anode = 8'b11111110; hex_digit = display_val[3:0];   end
            3'd1: begin anode = 8'b11111101; hex_digit = display_val[7:4];   end
            3'd2: begin anode = 8'b11111011; hex_digit = display_val[11:8];  end
            3'd3: begin anode = 8'b11110111; hex_digit = display_val[15:12]; end
            3'd4: begin anode = 8'b11101111; hex_digit = display_val[19:16]; end
            3'd5: begin anode = 8'b11011111; hex_digit = display_val[23:20]; end
            3'd6: begin anode = 8'b10111111; hex_digit = display_val[27:24]; end
            3'd7: begin anode = 8'b01111111; hex_digit = display_val[31:28]; end
            default: begin anode = 8'b11111111; hex_digit = 4'h0; end
        endcase
    end

    // Hex to 7-segment decoder (Active-LOW: 0 turns LED segment ON)
    // Segments: {CA, CB, CC, CD, CE, CF, CG}
    always @(*) begin
        case (hex_digit)
            4'h0: seg = 7'b0000001;
            4'h1: seg = 7'b1001111;
            4'h2: seg = 7'b0010010;
            4'h3: seg = 7'b0000110;
            4'h4: seg = 7'b1001100;
            4'h5: seg = 7'b0100100;
            4'h6: seg = 7'b0100000;
            4'h7: seg = 7'b0001111;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0000100;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b1100000;
            4'hC: seg = 7'b0110001;
            4'hD: seg = 7'b1000010;
            4'hE: seg = 7'b0110000;
            4'hF: seg = 7'b0111000;
            default: seg = 7'b1111111;
        endcase
    end

endmodule
