/*
 * Clockworks includes
 *   - gearbox to divide clock frequency, used
 *     to let you observe how the design behaves
 *     one cycle at a time.
 *   - reset mechanism that resets the design
 *     during the first startup cycles.
 *
 * Genesys 2 notes
 *   - This module assumes CLK is already a normal single-ended clock.
 *     On Genesys 2, the system clock is differential, so use IBUFDS
 *     in the top module before connecting to Clockworks.
 *   - The red CPU RESET button on Genesys 2 is active-low:
 *       not pressed -> RESET = 1
 *       pressed     -> RESET = 0
 *
 * Parameters
 *     SLOW number of bits of gearbox. Clock divider
 *       is approximately (1 << SLOW)
 */
`timescale 1ns/1ps
`default_nettype none

module Clockworks
(
   input  wire CLK,        // single-ended clock for the board/design
   input  wire RESET,      // red CPU RESET button, active-low on Genesys 2

   output wire clk_enable, // optionally divided clock enable for the design.
                           // divided if SLOW is different from zero.

   output wire resetn      // active-low reset for the design
);

   parameter integer SLOW = 0;
   
   
   // Genesys 2 red CPU RESET is already active-low.
   // resetn is also active-low. (0 = RESET is on)
   assign resetn = RESET;

   generate

/****************************************************

 Slow speed mode.
 - Create a clock divider to let observe what happens.
 - Nothing special to do for reset.
 - Since Genesys 2 CPU RESET is active-low, RESET can be
   connected directly to resetn.

 ****************************************************/

      if(SLOW != 0) begin : slowdown

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
         // Update every clock cycle.
         assign clk_enable = 1'b1;
      end

   endgenerate

endmodule

`default_nettype wire



