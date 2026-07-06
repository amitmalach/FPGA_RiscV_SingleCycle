`timescale 1ns/1ps

module bench();

   reg sysclk_p = 1'b0;
   reg sysclk_n = 1'b1;

   wire RESET = 1'b1;   // active-low reset not pressed
   wire [7:0] LEDS;

   reg  uart_rx_out = 1'b1;  // UART idle is 1
   wire uart_tx_in;

   SOC uut (
     .sysclk_p(sysclk_p),
     .sysclk_n(sysclk_n),
     .RESET(RESET),
     .LEDS(LEDS),
     .uart_rx_out(uart_rx_out),
     .uart_tx_in(uart_tx_in)
   );

   reg [7:0] prev_LEDS;

   initial begin
      prev_LEDS = 8'b0;
      $display("NEW");

      forever begin
         // 200 MHz differential clock: 5 ns period, 2.5 ns half-period.
         #2.5;
         sysclk_p = ~sysclk_p;
         sysclk_n = ~sysclk_n;

         // wait one delta cycle so LEDS has time to update
         #0;

         if (LEDS != prev_LEDS) begin
            $display("time = %0.1f ns, LEDS = %b", $realtime, LEDS);
         end

         prev_LEDS = LEDS;
      end
   end

   initial begin
      #100000;
      $finish;
   end

endmodule