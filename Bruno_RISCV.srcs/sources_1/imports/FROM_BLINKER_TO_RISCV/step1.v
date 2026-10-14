`timescale 1ns/1ps
/*
 * SOC (System On Chip) for the Genesys2 board.
 *
 * Wires together:
 *   - Clockworks: turns the board's raw clock/reset into CLK/clk_enable/resetn
 *   - Memory:     6KB of program+data RAM (see Memory.v)
 *   - Processor:  the RV32I core (see Processor.v)
 *   - a memory-mapped LEDS register and a UART transmitter, both addressed
 *     as if they were memory -- see "Memory-mapped IO" below
 *
 * The program is produced externally (program_asm.v, run through iverilog)
 * and loaded into Memory via $readmemh("program.hex"); this file never
 * embeds the program itself.
 *
 * Genesys2-specific: sysclk_p/sysclk_n is a differential clock pair (needs
 * IBUFDS+BUFG, see "Genesys2 clock handling" below), and the board's RESET
 * button is already active-low.
 */


// -----------------------------------------------------------------------------
// SOC
// -----------------------------------------------------------------------------
module SOC #(
    // Reset vector handed to the core. Default = SPIFLASH_BASE + SPIFLASH_CODE_OFFSET
    // (flash boot, see the localparams below). The testbench overrides it to 0
    // (BRAM boot) because no SPI-flash model exists in simulation.
    parameter [31:0] BOOT_ADDR = 32'h01D00000
) (
    input  wire       sysclk_p,                // differential system clock, positive leg
    input  wire       sysclk_n,                // differential system clock, negative leg
    input  wire       RESET,                   // reset button, active-low on this board
    output reg [7:0]  LEDS,                    // system LEDs (a real register -- see below)
    input  wire       uart_tx_in,              // "TX" = PC's TX; "_in" = input to FPGA. So: PC -> FPGA (unused, see below)
    output wire       uart_rx_out,             // "RX" = PC's RX; "_out" = output of FPGA. So: FPGA -> PC (what we transmit on)
    // ---- READ THIS BEFORE TOUCHING THE TWO UART PORTS ABOVE -------------
    //
    // These two names (fixed by the board schematic / XDC: Sch=uart_tx_in,
    // Sch=uart_rx_out) are confusing because each one mixes TWO DIFFERENT
    // POINTS OF VIEW in a single identifier:
    //
    //     TX / RX     <- named from the *PC's* point of view
    //     _in / _out  <- named from the *FPGA's* point of view
    //
    // The Genesys 2 reference manual states the first half: "Signal names
    // that imply direction are from the point-of-view of the DTE (Data
    // Terminal Equipment), in this case the PC." So "TX" means the PC
    // transmits, and "RX" means the PC receives. The trailing "_in"/"_out"
    // then describes the same wire as seen from this module -- which is why
    // they line up directly with the port directions declared above.
    //
    // Read each name one half at a time and both come out consistent:
    //
    //   uart_tx_in   "the PC's TX line, which is an INPUT to the FPGA"
    //                  -> data flows PC -> FPGA
    //   uart_rx_out  "the PC's RX line, which is an OUTPUT of the FPGA"
    //                  -> data flows FPGA -> PC
    //
    // The trap is applying the PC's point of view to BOTH halves (reading
    // "_in" as "into the PC"), which flips both wires and is a completely
    // natural misreading of the names.
    //
    // What settles it, with no naming convention needed at all: on every
    // UART device, TXD is an output and RXD is an input. Following the
    // schematic nets:
    //
    //   FT232RQ pin 30, labeled TXD (that chip DRIVES it)
    //        -> net UART_TX_IN  -> FPGA pin Y20  => must be an FPGA INPUT
    //   FT232RQ pin  2, labeled RXD (that chip LISTENS on it)
    //        -> net UART_RX_OUT -> FPGA pin Y23  => must be an FPGA OUTPUT
    //
    // Getting this backwards is silent and very hard to diagnose: the
    // transmitter ends up driving Y20, a pin the FT232RQ is itself driving,
    // so the two chips fight over the net, the FT232RQ's activity LED (LD12)
    // never blinks, and not one byte reaches the PC -- while everything
    // inside the FPGA looks perfectly healthy. Simulation does not catch it
    // either; see the serial decoder note in bench_iverilog.v.
    //
    // The FT232RQ is a USB-to-UART bridge; it converts uart_rx_out's serial
    // stream into USB, which appears on the host as a virtual COM port
    // (/dev/ttyUSBx on Linux) -- what GTKTerm/picocom actually reads.
    //
    // uart_tx_in carries whatever the PC sends back, but nothing here reads
    // it: this design has only the transmitter in emitter_uart.v, no
    // receiver. Adding RX support would mean writing a receiver module (the
    // mirror image of emitter_uart.v) plus a memory-mapped "byte received"
    // register for Processor to poll.
    
    
    
    output wire       spiflash_csn,            // SPI flash chip-select, active-low (see SPIFlash.v)
    output wire       spiflash_mosi,           // SPI flash data OUT of the FPGA (master-out-slave-in)
    input  wire       spiflash_miso            // SPI flash data INTO the FPGA (master-in-slave-out)
);

    // -------------------------------------------------------------------------
    // Clock and reset, as seen by the rest of this design
    // -------------------------------------------------------------------------
    wire CLK_ibuf;    // single-ended clock straight out of IBUFDS, before global routing
    wire CLK;         // CLK_ibuf after BUFG -- what every flip-flop in this design is clocked by
    wire clk_enable;  // one-cycle enable pulse from Clockworks (see clockworks.v)
    wire resetn;      // active-low reset from Clockworks, derived from RESET

    // -------------------------------------------------------------------------
    // Processor <-> memory bus. Processor.v only ever drives/reads these five
    // signals -- it has no notion of "RAM" vs "device register"; that split
    // is entirely decided below by how this file routes them.
    // -------------------------------------------------------------------------
    wire [31:0] mem_addr;   // address the Processor wants to read or write
    wire [31:0] mem_rdata;  // data returned to the Processor (from RAM, IO, or flash -- see mux below)
    wire        mem_rstrb;  // Processor's read strobe
    wire [31:0] mem_wdata;  // Processor's write data
    wire [3:0]  mem_wmask;  // Processor's per-byte write mask
    wire        mem_rbusy;  // tells the Processor to keep waiting -- see SPIFlash instantiation below


    // -------------------------------------------------------------------------
    // Memory-mapped IO -- address decoding
    // -------------------------------------------------------------------------
    // Bit 22 and bit 24 of the address now split the map three ways:
    //   bit 24 set              -> SPI flash space
    //   bit 24 clear, bit 22 set -> IO space (unchanged from before)
    //   both clear               -> RAM
    // Within IO space, each device still claims one bit of the word address
    // (1-hot), rather than a device number decoded by a multi-bit
    // comparator -- e.g. LEDS is selected purely by mem_wordaddr[0]==1,
    // regardless of every other bit. In byte-address terms (what software
    // uses), IO_xxx_bit N therefore sits at byte offset (1 << (N+2)) from
    // the IO base 32'h400000. SPI flash space starts at byte address
    // 32'h1000000 (bit 24 set, everything else clear).
    //
    // Why bit 24, not bit 23: the flash selector bit is what determines how
    // MANY low-order address bits are left over to actually address WITHIN
    // flash space (everything below the selector bit, since the selector
    // itself and everything above it can't be part of the in-flash offset
    // without colliding with something else). Bit 23 only leaves 23 bits
    // (8MB) of addressable flash offset -- and this board's own bitstream,
    // sitting at the start of the same 32MB chip, runs past 11MB. An 8MB
    // window can never reach past an 11MB bitstream, so nothing placed in
    // flash could ever have been reachable without overlapping it. Bit 24
    // leaves 24 bits (16MB) of offset, matching the SPI flash's own 03h
    // Read command's natural 3-byte/24-bit address field (see SPIFlash.v)
    // with no room to spare -- exactly enough to place data safely past
    // this design's bitstream while staying within what a single 03h
    // command can address at all.
    wire [31:0] RAM_rdata;                       // RAM's answer to a read, muxed into mem_rdata below
    wire [29:0] mem_wordaddr = mem_addr[31:2];    // mem_addr with the 2 byte-within-word bits dropped
    wire isSPIFlash = mem_addr[24];
    wire isIO       = mem_addr[22] & !isSPIFlash;
    wire isRAM      = !isIO & !isSPIFlash;
    // '|mem_wmask' is a reduction-OR: unlike 'a|b' (bitwise OR of two
    // values), a single '|' in front of one vector ORs all of that vector's
    // bits together into one bit. So mem_wstrb is 1 whenever ANY byte of
    // mem_wmask is set, i.e. whenever the Processor is writing at all.
    wire mem_wstrb = |mem_wmask;

    // -------------------------------------------------------------------------
    // Flash memory map and boot address (steps 23/24)
    // -------------------------------------------------------------------------
    // SPIFLASH_BASE is where flash space begins in the CPU's address map --
    // it is just "bit 24 set", i.e. the isSPIFlash decode above expressed as
    // an address. Adding an offset to it gives the CPU address of a given
    // byte inside the physical flash chip.
    //
    // The physical 32MB flash chip is shared, and the layout below is not
    // free to choose -- every region was derived from what is already
    // committed to the chip:
    //
    //   0x000000 .. 0xAE9E10   this design's own FPGA bitstream (~10.91MB).
    //                          Fixed size for the xc7k325t: uncompressed
    //                          7-series bitstreams contain every config
    //                          frame regardless of design size, so this does
    //                          not grow as the project grows.
    //   0xC00000 .. 0xC9C3E7   scene1.dat, the ST_NICCC polygon stream
    //                          (640KB), written in step 22.
    //   0xD00000 .. 0xFFFFFF   PROGRAM CODE (3MB) -- this is what steps
    //                          23/24 add, and what BOOT_ADDR points at.
    //   0xFFFFFF               hard ceiling: the 22-bit word_address into
    //                          SPIFlash.v can only reach 16MB (see the
    //                          bit-packing note there).
    //
    // 0xD00000 is 64KB-aligned (required: the flash erases in 64KB sectors,
    // so anything written must start on a sector boundary), sits 2136KB
    // clear of the bitstream and 399KB clear of scene1.dat, and leaves 3MB
    // for code -- against a 6KB BRAM, that is the whole point of step 23.
    //
    // NOTE: the tutorial uses flash base 1<<23 with a 128KB offset. Neither
    // number transfers here. 1<<23 would leave only an 8MB flash window,
    // smaller than this board's own ~11MB bitstream; and a 128KB offset is
    // sized for an IceStick bitstream of a few tens of KB, so it would land
    // squarely inside ours.
    localparam [31:0] SPIFLASH_BASE        = 32'h01000000; // bit 24 -- matches isSPIFlash above
    localparam [31:0] SPIFLASH_CODE_OFFSET = 32'h00D00000; // 13MB into the chip
    // BOOT_ADDR (module parameter above) defaults to SPIFLASH_BASE + SPIFLASH_CODE_OFFSET = 0x01D00000.

    // TO SWITCH BACK TO BOOTING FROM BRAM (everything up to step 22: program
    // held in Memory.v via $readmemh, 6KB limit), change the Processor
    // instantiation further down from .RESET_PC(BOOT_ADDR) to
    // .RESET_PC(32'h00000000). Nothing else needs to change.

    localparam IO_LEDS_bit      = 0;  // SW here -> latches LEDS (byte offset 4)
    localparam IO_UART_DAT_bit  = 1;  // SW here -> sends one byte over UART (byte offset 8)
    localparam IO_UART_CNTL_bit = 2;  // LW here -> reads UART status (byte offset 16)


    // High for exactly one cycle when the Processor stores to the UART data
    // address -- this is the "send this byte now" pulse the UART transmitter
    // below is waiting for.
    wire uart_valid = clk_enable && isIO & mem_wstrb & mem_wordaddr[IO_UART_DAT_bit];
    wire uart_ready; // driven by the UART transmitter: high when idle, low while sending a byte

    // IO_rdata is the read side of memory-mapped IO. It is not a stored
    // value -- there is no RAM cell behind it -- it is ordinary
    // combinational logic, recomputed live from mem_wordaddr and
    // uart_ready, exactly like aluOut or takeBranch in Processor.v. Its
    // purpose is to let a plain LW answer a question that has nothing to do
    // with memory: RISC-V has no "ask a peripheral its status" instruction,
    // only loads and stores, so this is what makes uart_ready -- otherwise
    // just a wire buried inside this module, invisible to software --
    // reachable by the processor at all. Reading a specific address is
    // repurposed into asking a question.
    //
    // Only the UART status address is wired up to answer anything real.
    // When mem_wordaddr[IO_UART_CNTL_bit] is set, the concatenation
    // {22'b0, !uart_ready, 9'b0} places one live bit -- !uart_ready, i.e.
    // "transmitter busy" -- at bit 9 of the returned word (9 zero bits
    // below it, 22 above it, 9+1+22 = 32). Software (see putc_ in
    // program_asm.v) masks with the matching 1<<9 and loops while that bit
    // is set. Agreeing on "bit 9" is a convention between this line and
    // that software, not something the hardware enforces on its own.
    //
    // Every other IO address -- including LEDS and the UART data register,
    // neither of which has read-back logic here -- falls through to the
    // ':' branch and simply reads as 0.
    wire [31:0] IO_rdata =
        mem_wordaddr[IO_UART_CNTL_bit] ? {22'b0, !uart_ready, 9'b0} :
                                         32'b0;

    // High for exactly one cycle when the Processor requests a read from
    // flash space -- this is the "start a transaction now" pulse
    // SPIFlash.v's rstrb input is waiting for, exactly parallel to
    // uart_valid above. Gated by eos (see the STARTUPE2 instantiation
    // further down) as a belt-and-suspenders check: in practice eos is
    // already long high by the time software could ever reach a flash
    // address (it goes high once at boot, well before resetn even
    // releases), but there's no reason not to make that explicit in the
    // hardware rather than merely assumed.
    wire eos;                   // end-of-startup from STARTUPE2 (declared here: used before the instantiation below)
    wire spiflash_rstrb = clk_enable && isSPIFlash && mem_rstrb && eos;
    wire [31:0] SPIFlash_rdata; // this module's answer to a read, muxed into mem_rdata below
    wire        spiflash_rbusy; // high for the whole SPI transaction; drives mem_rbusy below
    wire        spiflash_clk;   // this module's own SPI CLK output; only reaches the real pin
                                 // via STARTUPE2's USRCCLKO (see "SPI flash CCLK access" below)

    // SPI flash read controller (see SPIFlash.v). word_address takes the
    // low 22 bits of mem_wordaddr -- 22 bits of word address = 16MB of
    // byte-addressable flash space, matching both this controller's
    // cmd_addr packing (8-bit opcode + 22-bit word address + 2 conversion
    // bits = 32 bits per transaction, see SPIFlash.v) and bit 24 being the
    // flash-space selector above (see the "Why bit 24, not bit 23" note).
    SPIFlash spiflash (
        .clk          (CLK),
        .rstrb        (spiflash_rstrb),
        .word_address (mem_wordaddr[21:0]),
        .rdata        (SPIFlash_rdata),
        .rbusy        (spiflash_rbusy),
        .CLK          (spiflash_clk),
        .CS_N         (spiflash_csn),
        .MOSI         (spiflash_mosi),
        .MISO         (spiflash_miso)
    );

    // The Processor only ever stalls for flash reads -- RAM and IO both
    // already answer within their own fixed one-cycle timing, so this is
    // simply spiflash_rbusy renamed for what it means at the Processor's
    // own port.
    assign mem_rbusy = spiflash_rbusy;

    // The single value the Processor actually sees on mem_rdata: RAM's
    // answer in RAM space, the (currently placeholder) flash answer in
    // flash space, the IO status word otherwise.
    assign mem_rdata = isRAM      ? RAM_rdata :
                        isSPIFlash ? SPIFlash_rdata :
                                     IO_rdata;
    


    // -------------------------------------------------------------------------
    // LEDS register
    // -------------------------------------------------------------------------
    // LEDS is real state (a reg), latched on demand -- not just wires tied
    // to some Processor-internal signal. Reset (not gated by clk_enable, so
    // it always takes effect on the very next edge) clears it; otherwise it
    // only changes when the Processor stores to the LEDS address.
    always @(posedge CLK) begin
        if (!resetn) begin
            LEDS <= 8'd0;
        end else if (clk_enable & isIO & mem_wstrb & mem_wordaddr[IO_LEDS_bit]) begin
            LEDS <= mem_wdata[7:0];
        end
    end

    // Program + data RAM (see Memory.v). mem_rstrb and mem_wmask are both
    // gated by isRAM, so this module only ever reacts to RAM-space accesses
    // -- an IO-space read or write must never also disturb RAM. The
    // replication {4{isRAM}} turns the single isRAM bit into a 4-bit mask,
    // forcing every byte off when the access isn't RAM's.
    Memory RAM (
        .clk        (CLK),
        .clk_enable (clk_enable),
        .mem_addr   (mem_addr),
        .mem_rdata  (RAM_rdata),
        .mem_rstrb  (isRAM && mem_rstrb),
        .mem_wdata  (mem_wdata),
        .mem_wmask({4{isRAM}}&mem_wmask)
    );

    // The RV32I core (see Processor.v). It only ever talks to the shared
    // mem_addr/mem_rdata/mem_rstrb/mem_wdata/mem_wmask bus above -- every
    // bit of RAM-vs-IO routing happens around it, in this file, not inside it.
    // .RESET_PC selects the boot mode -- see the "Flash memory map and boot
    // address" note above. BOOT_ADDR = boot from SPI flash (steps 23/24);
    // 32'h00000000 = boot from BRAM (up to step 22).
    Processor #(
        .RESET_PC   (BOOT_ADDR)
    ) CPU (
        .clk        (CLK),
        .clk_enable (clk_enable),
        .resetn     (resetn),
        .mem_addr   (mem_addr),
        .mem_rdata  (mem_rdata),
        .mem_rstrb  (mem_rstrb),
        .mem_wdata  (mem_wdata),
        .mem_wmask  (mem_wmask),
        .mem_rbusy  (mem_rbusy)
    );

    // UART transmitter (see emitter_uart.v). clk_freq_hz must match CLK's
    // actual frequency so it can derive the right bit period for its baud
    // rate. i_rst wants active-HIGH, hence the '!' on resetn -- every other
    // reset signal in this design is active-low, this is the one exception.
    corescore_emitter_uart #(
        .clk_freq_hz(200000000)
    ) UART (
        .i_clk      (CLK),
        .i_rst      (!resetn),
        .i_data     (mem_wdata[7:0]),
        .i_valid    (uart_valid),
        .o_ready    (uart_ready),
        // o_uart_tx is named from THIS FPGA's point of view (the FPGA
        // transmits on it), so it connects to uart_rx_out -- whose "RX" is
        // named from the PC's point of view (the PC receives on it). Same
        // wire, two different vantage points; see the extended note in the
        // port list at the top of this file. It must NOT go to uart_tx_in,
        // which is an input here (the PC's TX line, driven by the FT232RQ).
        .o_uart_tx  (uart_rx_out)
    );

    // Simulation-only trace (this whole block is compiled out for real
    // synthesis): prints every IO-space write, and separately decodes UART
    // bytes as characters, so you can watch what the program is doing in
    // iverilog without a real serial terminal attached.
    `ifdef BENCH
    always @(posedge CLK) begin
        if (clk_enable && isIO && mem_wstrb) begin
            $display(
                "IO write: time=%0t mem_addr=%h mem_wordaddr=%h mem_wdata=%h mem_wmask=%b LED_write=%b UART_write=%b",
                $time,
                mem_addr,
                mem_wordaddr,
                mem_wdata,
                mem_wmask,
                mem_wordaddr[IO_LEDS_bit],
                mem_wordaddr[IO_UART_DAT_bit]
            );
        end

        if (uart_valid) begin
            $display("UART TX char: %c  hex=%02h", mem_wdata[7:0], mem_wdata[7:0]);
        end
    end
    `endif



    // -------------------------------------------------------------------------
    // Genesys2 clock handling
    // -------------------------------------------------------------------------
    // Genesys2's system clock only exists as a differential pair, never as
    // a single wire, so it has to go through Xilinx's differential input
    // buffer before anything else can use it.
    IBUFDS sysclk_buffer (
        .I(sysclk_p),
        .IB(sysclk_n),
        .O(CLK_ibuf)
    );
    // BUFG (global clock buffer) routes a clock onto one of the FPGA's
    // dedicated low-skew clock networks, so every flip-flop in the design
    // sees the same edge at (nearly) the same time. Any clock feeding a
    // design this size should go through one of these.
    BUFG sysclk_bufg (
        .I(CLK_ibuf),
        .O(CLK)
    );
    // change either value to feed a different divider
    // into Clockworks' clock-enable generator (see clockworks.v) for BENCH
    // vs. real hardware.
    `ifdef BENCH
    localparam integer SLOW_BITS = 0;
    `else
    localparam integer SLOW_BITS = 0;
    `endif
    // Clockworks (see clockworks.v) generates:
    //   clk_enable = a pulse, high once every 2^SLOW_BITS cycles of CLK
    //   resetn     = active-low reset for the whole design, derived from RESET
    Clockworks #(
        .SLOW(SLOW_BITS)
    ) clockworks (
        .CLK(CLK),
        .RESET(RESET),
        .clk_enable(clk_enable),
        .resetn(resetn)
    );


    // -------------------------------------------------------------------------
    // SPI flash CCLK access (7-series-specific)
    // -------------------------------------------------------------------------
    // Genesys2's onboard configuration flash is what boots this very bitstream
    // at power-on. Reading it again LATER, from user logic, needs a way to
    // drive its CLK line -- but on 7-series Xilinx parts that physical pin
    // (CCLK) is not a normal I/O pin like LEDS or UART. Xilinx's own
    // documentation (UG470, the 7 Series Configuration User Guide) classifies
    // CCLK as "Dedicated" -- reserved for the configuration process itself --
    // in explicit contrast to the flash's other pins (CS_N, D0-D3), which are
    // "Multi-function": reserved only DURING configuration, then "released
    // for general use" once it completes. That's why spiflash_csn/mosi/miso
    // (declared in the port list above, wired to ordinary XDC pin constraints)
    // work like any other port on this design, while CLK needs a completely
    // different mechanism: a Xilinx-provided primitive called STARTUPE2,
    // instantiated below, that hands user logic a way to drive CCLK
    // post-configuration.
    //
    // STARTUPE2 is a real, built-in Xilinx primitive -- part of the 7-series
    // hardware itself, the same category of thing as IBUFDS/BUFG just above.
    // "spiflash_cclk_access" (the name right before the port list below) is
    // NOT that built-in thing -- it is only this particular INSTANCE's name,
    // chosen the exact same way "sysclk_buffer" above is only the name of
    // this design's one IBUFDS instance, not a name Xilinx defines. Every
    // port name used below (USRCCLKO, EOS, ...) is fixed by Xilinx; only the
    // instance name and the wires connected to it are this project's own.
    //
    // Port-by-port:
    //   USRCCLKO   the actual clock waveform to drive onto the real CCLK pin.
    //              Driven by spiflash_clk -- SPIFlash.v's own CLK output
    //              (see the "spiflash" instantiation up in the
    //              "Memory-mapped IO" section above). That module already
    //              holds this idle-low whenever it isn't mid-transaction
    //              (CS_N high), so there's nothing extra to gate here.
    //   USRCCLKTS  active-high tri-state control for CCLK. Held at 0 (never
    //              tri-stated) so USRCCLKO's value is always actually driven
    //              onto the pin -- CCLK defaults to high-Z after
    //              configuration finishes, so this has to be told explicitly
    //              to stay driven.
    //   EOS        "End of Startup" -- goes high once the FPGA has fully
    //              finished configuring itself from flash and is ready for
    //              normal operation. Captured here as the wire "eos" for a
    //              later phase to use: the SPI flash controller must not
    //              start clocking the flash before this goes high. (It
    //              wouldn't have any effect even if it tried -- before EOS,
    //              the configuration engine itself still owns CCLK and
    //              ignores USRCCLKO entirely, so there is no way to glitch
    //              the boot sequence by getting this timing wrong.)
    //   CLK/GSR/GTS/KEYCLEARB/PACK/USRDONEO/USRDONETS/CFGCLK/CFGMCLK/PREQ
    //              not relevant to this design; left at their standard safe
    //              defaults (mostly tied off or left unconnected).
    STARTUPE2 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(0.0)
    ) spiflash_cclk_access (
        .CLK(1'b0),
        .GSR(1'b0),
        .GTS(1'b0),
        .KEYCLEARB(1'b1),
        .PACK(1'b0),
        .USRCCLKO(spiflash_clk), // SPIFlash.v's own CLK output -- see "spiflash" instantiation above
        .USRCCLKTS(1'b0),        // keep CCLK actively driven, never tri-stated
        .USRDONEO(1'b1),
        .USRDONETS(1'b1),
        .CFGCLK(),
        .CFGMCLK(),
        .EOS(eos),
        .PREQ()
    );


endmodule
