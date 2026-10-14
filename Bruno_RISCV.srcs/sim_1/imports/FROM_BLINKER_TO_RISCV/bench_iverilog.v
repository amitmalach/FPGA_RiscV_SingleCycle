`timescale 1ns/1ps

// =============================================================================
// bench -- SoC-level regression testbench
// =============================================================================
// Observes the SoC from the outside only, exactly as a terminal and the board's
// LEDs would, and writes what it sees to a text file:
//
//     LEDS <time_ns> <hex>     every change of the LED register, timestamped
//     UART <hex>               every byte received on the FPGA -> PC UART line
//     END  <reason> cycles=<n> uart_bytes=<n> leds=<hex>
//
// It never looks at internal signals, so the RTL can be refactored freely as
// long as this file's output stays byte-identical to sim/golden/*.txt.
//
// Boot mode: BOOT_ADDR is forced to 0 (BRAM boot). There is no SPI-flash
// model in simulation, so the firmware image the RAM loads with $readmemh is
// the program that runs. The run script (sim/run_regression.sh) makes the
// canonical firmware.hex visible in xsim's working directory.
//
// Stop conditions (whichever comes first):
//   * LEDS becomes STOP_LEDS. The mandelbrot demo writes its frame counter to
//     the LEDs at the top of every frame, so LEDS==1 means the first frame
//     has been drawn completely.
//   * MAX_CYCLES clock cycles (200 MHz input clock) have elapsed.
//
// Overrides, as plusargs (xsim: -testplusarg "out=trace.txt"):
//   +out=<file>  +max_cycles=<n>  +stop_leds=<n>
// =============================================================================

module bench();

   parameter         OUT_FILE   = "sim_out.txt";
   parameter integer MAX_CYCLES = 400_000_000;  // 2 s of simulated time at 200 MHz
   parameter integer STOP_LEDS  = 1;

   // Differential 200 MHz clock: period 5 ns.
   reg sysclk_p = 1'b0;
   reg sysclk_n = 1'b1;

   // Active-low reset button: 0 = pressed.
   reg RESET = 1'b0;

   wire [7:0] LEDS;

   // uart_tx_in  : the PC's TX line, an input to the FPGA (unused: no receiver).
   // uart_rx_out : the PC's RX line, an output of the FPGA -- the line we decode.
   reg  uart_tx_in = 1'b1;
   wire uart_rx_out;

   // SPI flash pins: unused in BRAM boot. MISO is tied low.
   wire spiflash_csn;
   wire spiflash_mosi;

   SOC #(
      .BOOT_ADDR     (32'h00000000)     // BRAM boot; see header
   ) uut (
      .sysclk_p      (sysclk_p),
      .sysclk_n      (sysclk_n),
      .RESET         (RESET),
      .LEDS          (LEDS),
      .uart_tx_in    (uart_tx_in),
      .uart_rx_out   (uart_rx_out),
      .spiflash_csn  (spiflash_csn),
      .spiflash_mosi (spiflash_mosi),
      .spiflash_miso (1'b0)
   );

   always begin
      #2.5;
      sysclk_p = ~sysclk_p;
      sysclk_n = ~sysclk_n;
   end

   initial begin
      RESET = 1'b0;
      #100;
      RESET = 1'b1;
   end

   // --- run control and trace file --------------------------------------------
   reg [1023:0] out_file   = OUT_FILE;
   integer      max_cycles = MAX_CYCLES;
   integer      stop_leds  = STOP_LEDS;
   integer      fd;
   integer      cycles     = 0;
   integer      uart_bytes = 0;

   initial begin
      if ($value$plusargs("out=%s", out_file))         ;
      if ($value$plusargs("max_cycles=%d", max_cycles)) ;
      if ($value$plusargs("stop_leds=%d", stop_leds))   ;
      fd = $fopen(out_file, "w");
      if (fd == 0) begin
         $display("bench: cannot open output file %0s", out_file);
         $finish;
      end
      $display("bench: writing trace to %0s (max_cycles=%0d stop_leds=%0d)",
               out_file, max_cycles, stop_leds);
   end

   task stop;
      input [8*16-1:0] reason;
      begin
         $fdisplay(fd, "END %0s cycles=%0d uart_bytes=%0d leds=%02h",
                   reason, cycles, uart_bytes, LEDS);
         $display("bench: %0s after %0d cycles, %0d UART bytes, LEDS=%02h",
                  reason, cycles, uart_bytes, LEDS);
         $fclose(fd);
         $finish;
      end
   endtask

   always @(posedge sysclk_p) begin
      cycles = cycles + 1;
      if (cycles >= max_cycles) stop("max_cycles");
   end

   // --- LED trace ---------------------------------------------------------------
   reg [7:0] prev_LEDS = 8'h00;

   always @(LEDS) begin
      if (LEDS !== prev_LEDS) begin
         $fdisplay(fd, "LEDS %0d %02h", $time, LEDS);
         prev_LEDS = LEDS;
         if (LEDS === stop_leds[7:0]) stop("stop_leds");
      end
   end

   // --- UART receiver: 115200 baud, 8N1, LSB first ----------------------------
   localparam real BIT_PERIOD_NS = 1000000000.0 / 115200.0;

   reg [7:0] rx_byte;
   integer   rx_i;

   initial begin
      forever begin
         @(negedge uart_rx_out);          // start bit
         #(BIT_PERIOD_NS * 1.5);          // middle of data bit 0
         for (rx_i = 0; rx_i < 8; rx_i = rx_i + 1) begin
            rx_byte[rx_i] = uart_rx_out;
            #(BIT_PERIOD_NS);
         end
         $fdisplay(fd, "UART %02h", rx_byte);
         uart_bytes = uart_bytes + 1;
      end
   end

endmodule
