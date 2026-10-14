// SPDX-FileCopyrightText: 2023 Olof Kindgren <olof@award-winning.me>
// SPDX-License-Identifier: Apache-2.0
// Origin: emitter_uart.v from CoreScore (https://github.com/olofk/corescore), as
// redistributed by learn-fpga; comments and signal notes below are this project's.
// -----------------------------------------------------------------------------
// Simple UART transmitter
// -----------------------------------------------------------------------------
// This module sends one byte over a UART TX line.
//
// UART frame format:
//
//     idle  start  data bits                 stop
//       1     0    bit0 bit1 ... bit7          1
//
// So every byte is transmitted as 10 serial bits:
//
//     1 start bit
//     8 data bits, least-significant bit first
//     1 stop bit
//
// Interface:
//
//     i_data      byte to transmit
//     i_valid     pulse high when i_data should be sent
//     o_ready     high when UART can accept a new byte
//     o_uart_tx   serial UART output line
// -----------------------------------------------------------------------------

module corescore_emitter_uart #(
    // FPGA clock frequency in Hz.
    // Genesys2 system clock is 200 MHz.
    parameter clk_freq_hz = 200000000,

    // UART baud rate.
    // 115200 is the usual default for serial terminals.
    parameter baud_rate = 115200
) (
    input  wire       i_clk,       // main FPGA clock
    input  wire       i_rst,       // active-high reset -- the one exception in
                                    // this design; resetn elsewhere is active-low
    input  wire [7:0] i_data,      // byte to transmit
    input  wire       i_valid,     // high for one clock when i_data is valid

    output reg        o_ready,     // high when UART is ready for a new byte
    output reg        o_uart_tx    // UART TX output line -- leaves the FPGA here. On the
                                    // Genesys2, this pin goes to an onboard FTDI FT232RQ
                                    // (a USB-to-UART bridge chip), which is what actually
                                    // shows up as a virtual COM port on the host PC.
                                    //
                                    // "TX" here is from the FPGA's own point of view: this
                                    // module transmits on it. Careful when wiring it up in
                                    // step1.v -- the board's two UART signal names are built
                                    // from two different vantage points ("TX"/"RX" from the
                                    // PC's side, "_in"/"_out" from the FPGA's side), so this
                                    // output belongs on uart_rx_out (the PC's RX line, an
                                    // FPGA output), NOT on the similarly-spelled uart_tx_in,
                                    // which is an FPGA input driven by the FT232RQ. See the
                                    // extended note in step1.v's port list.
);

    // Number of FPGA clock cycles per UART bit.
    //
    // For 200 MHz and 115200 baud:
    //
    //     CLKS_PER_BIT = 200,000,000 / 115,200 ~= 1736
    //
    // So each UART bit stays stable for about 1736 clock cycles.
    localparam integer CLKS_PER_BIT = clk_freq_hz / baud_rate;

    // Width of the counter that counts clock cycles inside one UART bit.
    // $clog2(x) is a Verilog system function returning the number of bits
    // needed to count up to x-1 (ceiling of log2(x)) -- e.g. $clog2(1736)
    // is 11, since 11 bits can count as high as 2047. Computing the width
    // this way, instead of hardcoding it, keeps clk_cnt correctly sized
    // even if clk_freq_hz/baud_rate change.
    localparam integer CLK_CNT_WIDTH = $clog2(CLKS_PER_BIT);

    // UART transmitter states.
    localparam IDLE = 1'b0;
    localparam SEND = 1'b1;

    reg state; // current transmitter state: IDLE (waiting) or SEND (shifting a frame out)

    // Counts clock cycles inside the current UART bit.
    reg [CLK_CNT_WIDTH-1:0] clk_cnt;

    // Counts which bit of the UART frame we are sending.
    //
    // bit_index = 0 -> start bit
    // bit_index = 1 -> data bit 0
    // bit_index = 2 -> data bit 1
    // ...
    // bit_index = 8 -> data bit 7
    // bit_index = 9 -> stop bit
    reg [3:0] bit_index;

    // Full UART frame:
    //
    //     frame[0]   = start bit = 0
    //     frame[8:1] = data bits
    //     frame[9]   = stop bit = 1
    //
    // UART sends least-significant bit first, so frame[0] is sent first.
    reg [9:0] frame;

    always @(posedge i_clk) begin
        if (i_rst) begin
            // Reset UART to idle state.
            // UART line is idle-high.
            state     <= IDLE;
            o_ready   <= 1'b1;
            o_uart_tx <= 1'b1;
            clk_cnt   <= {CLK_CNT_WIDTH{1'b0}}; // {n{1'b0}}: replication operator, n copies of bit 0 -- i.e. just "0" at this width
            bit_index <= 4'd0;
            frame     <= 10'b1111111111;

        end else begin
            case (state)

                IDLE: begin
                    // While idle, TX line stays high.
                    o_uart_tx <= 1'b1;
                    o_ready   <= 1'b1;
                    clk_cnt   <= {CLK_CNT_WIDTH{1'b0}};
                    bit_index <= 4'd0;

                    // Start transmitting when a valid byte arrives.
                    if (i_valid) begin
                        // Build the UART frame:
                        //
                        //     start bit = 0
                        //     data byte = i_data
                        //     stop bit  = 1
                        //
                        // Since frame[0] is sent first, this sends:
                        // start, data bit 0, ..., data bit 7, stop.
                        frame <= {1'b1, i_data, 1'b0};

                        // Send the start bit immediately.
                        o_uart_tx <= 1'b0;

                        // UART is now busy.
                        o_ready <= 1'b0;
                        state   <= SEND;
                    end
                end

                SEND: begin
                    // During transmission, UART is not ready for a new byte.
                    o_ready <= 1'b0;

                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        // One UART bit time has passed.
                        clk_cnt <= {CLK_CNT_WIDTH{1'b0}};

                        if (bit_index == 4'd9) begin
                            // Finished sending:
                            // start bit + 8 data bits + stop bit.
                            state     <= IDLE;
                            o_ready   <= 1'b1;
                            o_uart_tx <= 1'b1;
                            bit_index <= 4'd0;

                        end else begin
                            // Move to the next bit of the frame.
                            bit_index <= bit_index + 4'd1;

                            // Shift the frame so the next bit becomes visible.
                            frame <= {1'b1, frame[9:1]};

                            // Output the next UART bit.
                            o_uart_tx <= frame[1];
                        end

                    end else begin
                        // Stay on the current UART bit until its time finishes.
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

            endcase
        end
    end

endmodule
