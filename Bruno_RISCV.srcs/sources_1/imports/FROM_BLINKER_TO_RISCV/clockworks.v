/*
 * Clockworks turns the board's raw clock/reset into what the rest of the
 * design actually uses:
 *   - clk_enable: a "gearbox" pulse, high once every 2^SLOW cycles of CLK.
 *     Every clocked block elsewhere in this project is gated by this
 *     signal, so setting SLOW>0 lets you slow the whole design down enough
 *     to watch it operate one logical step at a time (e.g. on LEDs).
 *   - resetn: this design's active-low reset, forwarded from RESET.
 *
 * Genesys 2 notes
 *   - This module assumes CLK is already a normal single-ended clock.
 *     On Genesys 2, the system clock is differential, so use IBUFDS
 *     in the top module before connecting to Clockworks.
 *   - The red CPU RESET button on Genesys 2 is already active-low:
 *       not pressed -> RESET = 1
 *       pressed     -> RESET = 0
 *     so, unlike boards where RESET needs inverting or synchronizing on
 *     startup, resetn here is just RESET forwarded straight through.
 *
 * Parameters
 *     SLOW: number of bits of the gearbox counter. clk_enable pulses
 *       approximately every (1 << SLOW) cycles of CLK; SLOW=0 disables the
 *       divider entirely (clk_enable stays high every cycle).
 */
`timescale 1ns/1ps


module Clockworks
(
   input  wire CLK,        // single-ended clock for the board/design
   input  wire RESET,      // red CPU RESET button, active-low on Genesys 2

   output wire clk_enable, // gearbox pulse for the design; see SLOW below.
                           // Always 1 when SLOW==0 (no division).

   output wire resetn      // active-low reset for the design
);

   parameter integer SLOW = 0; // 0 = no clock division (see module comment above)


   // Genesys 2 red CPU RESET is already active-low.
   // resetn is also active-low. (0 = RESET is on)
   assign resetn = RESET;

   generate
   // Inside `generate`, `if` is evaluated at elaboration time (based on the
   // SLOW parameter), not at run time: only ONE of the two branches below
   // is actually turned into hardware, there is no mux between them. The
   // `: slowdown` / `: no_slowdown` labels name each branch's instance in
   // the design hierarchy, so its internal signals (like `div`/`tick`
   // below) are identifiable in a waveform viewer or synthesis report.

      if(SLOW != 0) begin : slowdown
         // div is a free-running SLOW-bit counter; tick is registered high
         // for exactly one cycle out of every 2^SLOW, whenever div was at
         // its maximum value on the previous edge -- that pulse becomes
         // clk_enable below.

         // The {SLOW{1'b0}} is a replication operator,
         // it duplicates the bit 0 SLOW times
         reg [SLOW-1:0] div = {SLOW{1'b0}};
         reg tick = 1'b0;

         always @(posedge CLK) begin
             if (!RESET) begin
                 div  <= {SLOW{1'b0}};
                 tick <= 1'b0;
             end else begin
                 div  <= div + 1'b1;
                 tick <= (div == {SLOW{1'b1}});
             end
         end

         assign clk_enable = tick;

      end

      else begin : no_slowdown
         // SLOW==0: skip the divider, enable every single cycle.
         assign clk_enable = 1'b1;
      end

   endgenerate

endmodule



