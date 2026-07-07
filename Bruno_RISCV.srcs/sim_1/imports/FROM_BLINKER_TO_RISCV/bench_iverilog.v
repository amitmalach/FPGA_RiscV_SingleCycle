`timescale 1ns/1ps

module bench();

   // Differential 200 MHz clock:
   // period = 5 ns, half-period = 2.5 ns.
   reg sysclk_p = 1'b0;
   reg sysclk_n = 1'b1;

   // Active-low reset.
   // RESET = 0 means reset is pressed.
   // RESET = 1 means reset is released.
   reg RESET = 1'b0;

   wire [7:0] LEDS;

   // UART RX is unused for now.
   // Keep it at idle value 1.
   reg  uart_rx_out = 1'b1;

   // UART TX output from the FPGA.
   wire uart_tx_in;

   // Instantiate the SOC.
   SOC uut (
      .sysclk_p    (sysclk_p),
      .sysclk_n    (sysclk_n),
      .RESET       (RESET),
      .LEDS        (LEDS),
      .uart_rx_out (uart_rx_out),
      .uart_tx_in  (uart_tx_in)
   );

   // Generate 200 MHz differential clock.
   always begin
      #2.5;
      sysclk_p = ~sysclk_p;
      sysclk_n = ~sysclk_n;
   end

   // Apply reset at the beginning of simulation.
   initial begin
      RESET = 1'b0;   // press reset
      #100;
      RESET = 1'b1;   // release reset
   end

   // Print LED changes.
   reg [7:0] prev_LEDS;

   initial begin
      prev_LEDS = 8'h00;
      $display("NEW");

      forever begin
         @(LEDS);

         if (LEDS !== prev_LEDS) begin
            $display("time = %0.1f ns, LEDS = %02h (%b)", $realtime, LEDS, LEDS);
            prev_LEDS = LEDS;
         end
      end
   end

   // End simulation.
   initial begin
      #10000000;   // 1 ms
      $finish;
   end

endmodule