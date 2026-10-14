`timescale 1ns/1ps
// =============================================================================
// SPIFlash -- SPI NOR flash read controller (plain 03h Read command)
// =============================================================================
// Lets the CPU read words out of the Genesys2 board's onboard QSPI
// configuration flash (a Cypress/Infineon S25FL256S, 32MB) as if it were
// ordinary memory -- see step1.v's "isSPIFlash" address decode, which is
// what actually routes a Load instruction to this module instead of to RAM.
//
// Adapted from Bruno Levy's spi_flash.v (SPI_FLASH_READ variant, the
// simplest of the four variants that file offers), but with a genuinely
// different clock-generation scheme -- see the "Divide 200MHz..." comment
// below for exactly why that couldn't just be reused as-is.
//
// -----------------------------------------------------------------------------
// SPI protocol crash course, as used here (this is "SPI Mode 0")
// -----------------------------------------------------------------------------
// SPI is a 4-wire bus: CLK (clock, driven by us, the "master"), CS_N (chip
// select, active-low, driven by us), MOSI ("Master Out Slave In" -- we drive
// it, the flash reads it), and MISO ("Master In Slave Out" -- the flash
// drives it, we read it). Nothing happens on the bus unless CS_N is low;
// that is what tells the flash chip "pay attention, the next bits are for
// you." Mode 0 specifically means: CLK idles low, the flash samples MOSI on
// CLK's RISING edge, and drives MISO to its next value shortly after CLK's
// FALLING edge (so it is stable well before the next rising edge). We do
// the mirror image: we present a new MOSI bit near a falling edge, and we
// sample MISO near a rising edge.
//
// A "Read" transaction on this flash chip is: hold CS_N low, clock out one
// command byte (0x03 = "Read Data") immediately followed by a 3-byte (24
// bit) address -- 32 bits sent altogether -- then, without releasing CS_N,
// keep clocking and the flash starts shifting the requested data out on
// MISO, byte after byte, for as long as CS_N stays low. This module always
// asks for exactly one 32-bit word (4 bytes) then releases CS_N.
// =============================================================================
module SPIFlash(
    input  wire        clk,          // system clock (200MHz on this board -- see
                                      // the clock divider below for why that matters)
    input  wire        rstrb,        // pulse high for exactly 1 cycle to start a
                                      // read (this is step1.v's spiflash_rstrb,
                                      // itself derived from the Processor's own
                                      // mem_rstrb -- see step1.v for that wiring)
    input  wire [21:0] word_address, // which 32-bit word to read, as a WORD index
                                      // (not a byte address) -- step1.v passes
                                      // mem_wordaddr[21:0], i.e. mem_addr>>2.
                                      // 22 bits here = a 24-bit (16MB) byte
                                      // range once *4 -- see the bit-packing
                                      // note below for why it's exactly 22,
                                      // not some other width.
    output wire [31:0] rdata,        // the word read back. Only meaningful once
                                      // rbusy has dropped back to 0 -- while a
                                      // transaction is in flight this is mid-shift
                                      // garbage, same as mem_rdata generally is
                                      // before a load completes elsewhere in this
                                      // design
    output wire        rbusy,        // high for the ENTIRE transaction -- from the
                                      // cycle rstrb is seen until the 4th received
                                      // byte lands. This is what step1.v wires to
                                      // the Processor's mem_rbusy input, which is
                                      // what actually makes the CPU sit still in
                                      // WAIT_INSTR/WAIT_DATA for as long as this
                                      // stays high, instead of reading rdata before
                                      // it is ready (see Processor.v)

    // ---- the four physical SPI wires (see the protocol crash course above) ----
    output wire        CLK,          // clock we generate for the flash. This does
                                      // NOT go straight to a chip pin -- on this
                                      // 7-series FPGA, the physical CCLK pin can
                                      // only be driven post-configuration through
                                      // Xilinx's STARTUPE2 primitive. See the
                                      // "SPI flash CCLK access" section in step1.v
                                      // for the full explanation of why, and for
                                      // where this signal actually goes.
    output reg         CS_N,         // chip-select, active-low: 0 = flash is
                                      // listening, 1 = flash ignores everything
                                      // (idle). A plain reg (not assign'd from
                                      // combinational logic) because it needs to
                                      // hold its value across many cycles of one
                                      // transaction -- see the two always blocks
                                      // below, both of which drive it.
    output wire        MOSI,         // our command+address bits, one at a time
    input  wire        MISO          // the flash's data bits, one at a time
);
    // -------------------------------------------------------------------------
    // Clock divider: 200MHz system clock -> ~33.3MHz SPI clock
    // -------------------------------------------------------------------------
    // Why this exists at all: Divide 200MHz down to ~33.3MHz (one SPI clock
    // period = 6 system clock cycles) for the flash's SPI bus. Verified
    // directly against Infineon's S25FL256S datasheet (the actual chip on
    // this board -- downloaded and read the real PDF rather than trusting
    // secondhand claims): Table 6.5 states "FSCK,R -- SCK Clock Frequency
    // for READ, 4READ instructions -- 50 MHz" as the maximum for this exact
    // command (0x03, the plain, no-dummy-cycles read this module uses).
    // This design's system clock is 200MHz, un-divided -- 4x over that
    // limit -- so simply feeding clk straight through as the SPI clock (as
    // the tutorial's own IceStick-era version of this module does, since
    // IceStick-class boards run far slower) would drive the flash chip out
    // of its documented spec. Dividing by 6 lands at ~33.3MHz, about 33%
    // of margin below the documented 50MHz ceiling.
    //
    // How the division actually works: div is a free counter that repeats
    // 0,1,2,0,1,2,... (three system-clock cycles per count); every time it
    // wraps back to 0 (i.e. every 3rd cycle), sclk flips. Flipping every 3
    // cycles means sclk's own full period (one low phase + one high phase)
    // is 6 system-clock cycles long -- 6 x 5ns = 30ns = 33.3MHz. sclk itself
    // is NOT the final SPI clock output (see the "assign CLK" line below) --
    // it is just the raw, always-ticking waveform this module's timing is
    // built around.
    reg [1:0] div = 2'd0;   // note the explicit "= 2'd0" initial value: without
    reg       sclk = 1'b0;  // it, both regs start as Verilog's default 'X' in
                             // simulation, and X+1 is still X forever, so the
                             // divider would never start counting at all. This
                             // is invisible on real silicon (which always powers
                             // up to some concrete 0/1, never a true "unknown"),
                             // but caught this exact bug via simulation -- the
                             // whole testbench simply hung -- before shipping it,
                             // and it is bad practice to rely on unstated
                             // power-on behavior regardless.

    // sclk_rise/sclk_fall each pulse for exactly the one system-clock cycle
    // where sclk is ABOUT to flip -- i.e. "this cycle is the moment of a
    // rising/falling edge", not "sclk is currently high/low". These are what
    // the shift-register logic further down actually synchronizes to,
    // instead of watching sclk's level directly.
    wire      sclk_rise = (div == 2'd2) && !sclk; // about to flip 0->1
    wire      sclk_fall = (div == 2'd2) &&  sclk; // about to flip 1->0

    always @(posedge clk) begin
        if (CS_N) begin
            // Idle: hold the divider at reset so the very first pulse of
            // the next transaction is always a full, clean period.
            //
            // Why this matters: without it, the divider would be free-
            // running all the time, including while idle -- so at the
            // exact moment CS_N drops (a transaction starting), div/sclk
            // could be caught mid-count, at some arbitrary phase. That
            // would hand the flash chip a FIRST clock pulse shorter than
            // the other 63 -- possibly violating the flash's own minimum
            // pulse-width timing. Caught this exact bug during simulation
            // (a stray ~20ns pulse instead of the expected steady 30ns)
            // before fixing it with this idle-reset. Resetting here, keyed
            // off CS_N rather than off rstrb specifically, is what
            // guarantees this: the moment CS_N is next asserted (in the
            // second always block below), this block sees CS_N already
            // high on THIS cycle (both blocks read the pre-update value of
            // CS_N on the cycle it changes), so div/sclk are still held at
            // 0 through that transition, and only start counting cleanly
            // from the following cycle onward.
            div  <= 2'd0;
            sclk <= 1'b0;
        end else if (div == 2'd2) begin
            // Every 3rd cycle: wrap the counter and flip the clock.
            div  <= 2'd0;
            sclk <= !sclk;
        end else begin
            // The other 2 out of every 3 cycles: just keep counting.
            div <= div + 2'd1;
        end
    end

    // The actual signal that (eventually, via STARTUPE2) reaches the real
    // CCLK pin: sclk while a transaction is active, forced low while idle.
    // Forcing it low here (rather than relying on sclk already being 0 at
    // that point) is what makes "idle-low" true even for the handful of
    // cycles between CS_N first dropping and the divider producing its
    // first real edge -- SPI Mode 0 requires the clock to be low before the
    // first rising edge, not merely eventually.
    assign CLK = CS_N ? 1'b0 : sclk;

    // -------------------------------------------------------------------------
    // The shift registers: what actually gets sent and received
    // -------------------------------------------------------------------------
    // cmd_addr packs the outgoing command exactly the way the flash chip's
    // Read instruction expects it, MSB (bit 31) first:
    //
    //     bits [31:24]  8'h03           the "Read Data" opcode
    //     bits [23: 2]  word_address    the word we want, all 22 bits of it
    //     bits [ 1: 0]  2'b00           these 2 bits convert a WORD address
    //                                   into a BYTE address -- the flash
    //                                   addresses individual bytes, and a
    //                                   word is 4 bytes, so its byte address
    //                                   is always word_address*4, i.e.
    //                                   word_address followed by two zero
    //                                   bits (see the "cmd_addr <=" line in
    //                                   the always block below)
    //
    // That is exactly 8+22+2 = 32 bits -- one full cmd_addr's worth, and
    // uses the FULL 24-bit address field the flash chip's 03h command
    // supports (2^24 = 16MB reachable) rather than artificially padding the
    // top 2 bits to 0. That padding existed in an earlier version of this
    // file (word_address was only 20 bits then, reaching just 4MB) --
    // ported directly from Bruno Levy's own IceStick-era module, whose
    // target flash chip never needed more than that. It had to be widened
    // here: our own 32MB S25FL256S holds this design's own bitstream at
    // the start of the chip, and that bitstream is 11,443,728 bytes
    // (~10.9MB) -- a fixed size for the xc7k325t part, since uncompressed
    // 7-series bitstreams contain every configuration frame regardless of
    // how much logic the design actually uses, so it does NOT grow as this
    // project adds modules. 4MB of reach isn't enough room to place
    // anything past an ~11MB bitstream. Verified this was a real, live
    // bug (not a theoretical one) by
    // computing the actual byte address a real intended offset resolved to
    // under the old 20-bit version: it silently wrapped around to address
    // 0 -- the very start of the chip, i.e. it would have read this
    // project's OWN bitstream bytes back as if they were user data.
    reg [5:0]  snd_bitcount; // how many more bits of cmd_addr still need sending
    reg [31:0] cmd_addr;     // the 32-bit command+address shift register
    reg [5:0]  rcv_bitcount; // how many more bits of the response are still expected
    reg [31:0] rcv_data;     // the 32-bit data shift register, filled in from MISO

    // sending/receiving/busy are pure bookkeeping derived from the two
    // countdown counters above -- neither is ever written directly, they
    // just reflect "is there still work left in this phase".
    wire       sending   = (snd_bitcount != 0);
    wire       receiving = (rcv_bitcount != 0);
    wire       busy      = sending | receiving;

    // rbusy is just !CS_N -- CS_N is only ever low while a transaction (of
    // either phase) is actually in progress, so this is a cheap, always-
    // correct proxy without needing its own separate bookkeeping.
    assign     rbusy     = !CS_N;

    // MOSI is always simply "whatever the top bit of cmd_addr currently
    // is" -- there is no separate "current output bit" register, because
    // cmd_addr IS being shifted (see "cmd_addr <= {cmd_addr[30:0], 1'b1}"
    // below) one bit closer to fully-sent every time a bit goes out, so its
    // own top bit is always exactly the next bit that needs to appear on
    // the wire.
    assign     MOSI      = cmd_addr[31];

    initial CS_N = 1'b1; // idle (deselected) at power-on/reset

    // The flash sends the 4 response bytes MSB-first, in increasing-address
    // order: the very first bit received is bit 7 of the byte at the
    // requested address, and the very last bit received is bit 0 of the
    // byte at (requested address + 3). After all 32 bits land in rcv_data
    // via left-shifting (see "rcv_data <= {rcv_data[30:0], MISO}" below),
    // rcv_data therefore holds, from its own MSB to LSB: byte0, byte1,
    // byte2, byte3 (the bytes at increasing flash addresses, in that
    // order) -- i.e. rcv_data[31:24]=byte0, rcv_data[7:0]=byte3.
    //
    // RISC-V is little-endian: for a 32-bit value spread across 4
    // consecutive addresses, software expects the LOWEST address's byte to
    // be the LEAST significant byte of the resulting word (word[7:0] =
    // byte at address+0). rcv_data has it backwards from that (its MOST
    // significant byte is byte0), so this reverses the byte order --
    // NOTHING inside each byte is reversed, only which byte lands in which
    // byte-lane of the final word:
    //     rdata[ 7: 0] = rcv_data[31:24]  (byte0, the lowest address -> LSB)
    //     rdata[15: 8] = rcv_data[23:16]  (byte1)
    //     rdata[23:16] = rcv_data[15: 8]  (byte2)
    //     rdata[31:24] = rcv_data[ 7: 0]  (byte3, the highest address -> MSB)
    // Concrete example: bytes 0xAA,0xBB,0xCC,0xDD sitting at consecutive
    // flash addresses +0,+1,+2,+3 arrive in rcv_data as 32'hAABBCCDD, and
    // this line turns that into rdata = 32'hDDCCBBAA -- confirmed against
    // exactly this scenario in simulation before trusting it.
    assign rdata = {rcv_data[7:0], rcv_data[15:8], rcv_data[23:16], rcv_data[31:24]};

    // -------------------------------------------------------------------------
    // The transaction state machine
    // -------------------------------------------------------------------------
    // Unlike Processor.v's FSM, this isn't a named-state case statement --
    // it is driven entirely by the sending/receiving/busy wires above, plus
    // whether this is the cycle a real SPI edge is happening (sclk_fall for
    // things we should do BEFORE the flash next samples MOSI on a rising
    // edge; sclk_rise for things we should do to capture what the flash put
    // on MISO around its own falling edge) -- i.e. it directly follows the
    // SPI Mode 0 timing described at the top of this file, just spread
    // across a divided clock instead of the system clock directly.
    always @(posedge clk) begin
        if (rstrb) begin
            // Kick off a brand new transaction. This branch is NOT gated by
            // sclk_fall/sclk_rise -- it can happen on any system-clock
            // cycle, so that it never misses a 1-cycle rstrb pulse from the
            // Processor regardless of which phase the free-running divider
            // happens to be in. (Nothing else can be mid-transaction at
            // this point anyway: the Processor only ever issues rstrb after
            // the PREVIOUS transaction's rbusy has already dropped, so
            // there's no risk of interrupting one read with another.)
            CS_N         <= 1'b0;                                // select the flash
            cmd_addr     <= {8'h03, word_address[21:0], 2'b00};  // load the command (see the bit-packing note above)
            snd_bitcount  <= 6'd32;                               // 32 bits still need sending
        end else begin
            // ---- sending phase: shift one command/address bit out per SPI period ----
            if (sending && sclk_fall) begin
                // Right before the flash's next sampling edge (its next
                // rising edge, which follows this falling edge): if this is
                // the LAST bit of the command about to go out, arm the
                // receive counter now, so that the very next SPI period
                // seamlessly becomes the first bit of the response -- no
                // gap cycle needed between "done sending" and "start
                // receiving".
                if (snd_bitcount == 1) rcv_bitcount <= 6'd32;
                snd_bitcount <= snd_bitcount - 6'd1;
                // Shift cmd_addr one bit to the left, discarding the bit
                // that was just placed on MOSI (cmd_addr[31]) and dropping
                // in a 1 at the bottom -- that trailing 1 never actually
                // gets sent (snd_bitcount reaches 0 before it would be
                // MOSI's turn), its value genuinely does not matter.
                cmd_addr     <= {cmd_addr[30:0], 1'b1};
            end

            // ---- receiving phase: capture one response bit per SPI period ----
            if (receiving && sclk_rise) begin
                // Right at the flash's own sampling-equivalent moment (this
                // module's rising edge, matching when the flash's MISO bit
                // -- driven around ITS preceding falling edge -- is stable
                // and ready to read): shift MISO into the bottom of
                // rcv_data, sliding everything already captured one bit to
                // the left.
                rcv_bitcount <= rcv_bitcount - 6'd1;
                rcv_data     <= {rcv_data[30:0], MISO};
            end

            // ---- end of transaction ----
            // The moment neither phase has any bits left (busy drops to 0),
            // release CS_N. This check runs every cycle regardless of
            // sclk_fall/sclk_rise -- there's no reason to wait for a
            // particular SPI edge just to deselect the chip, so it reacts
            // as soon as possible instead of adding an extra period of
            // latency.
            if (!busy) CS_N <= 1'b1;
        end
    end
endmodule
