// -----------------------------------------------------------------------------
// Processor
// -----------------------------------------------------------------------------
// Multi-cycle RV32I core: one instruction takes several clock cycles, moving
// through the states of the FSM further down. It talks to a separate Memory
// module (see Memory.v) over a simple synchronous request/response bus: a
// read requested (mem_addr/mem_rstrb) on one clock edge is answered on
// mem_rdata only on the *next* edge -- hence the WAIT_* states below.
// -----------------------------------------------------------------------------
module Processor #(
    // -------------------------------------------------------------------------
    // RESET_PC -- where the CPU starts executing after reset
    // -------------------------------------------------------------------------
    // Default 0 = boot from BRAM (the classic behaviour up to step 22: the
    // program lives in Memory.v, loaded there by $readmemh at configuration
    // time). step1.v overrides this with an address in SPI-flash space to
    // boot from flash instead (step 23/24), which is what allows programs
    // much larger than the 6KB of BRAM.
    //
    // WHY THIS IS A PARAMETER RATHER THAN A HARDCODED CONSTANT: it is the
    // single switch between the two boot modes. Flip it in step1.v (see
    // BOOT_ADDR there) and nothing else in this file has to change.
    //
    // WHY IT IS NOT ENOUGH TO JUST PUT A JUMP AT RAM ADDRESS 0 (which is
    // what tutorial step 23 does, and step 24 then fixes): that jump only
    // exists because it was part of BRAM's *initial* contents. BRAM is also
    // where the stack lives, growing down from 0x1800 towards 0. Once a
    // program has been running a while, whatever is at address 0 is very
    // likely to be stack leftovers, not the jump any more -- so pressing the
    // physical reset button would set PC=0 and execute garbage. Making the
    // reset vector a property of this hardware instead makes reset always
    // land somewhere real, no matter what RAM currently holds.
    parameter [31:0] RESET_PC = 32'h00000000
) (
    input  wire        clk,
    input  wire        clk_enable, // High for one "real" clock tick; lets Clockworks
                                    // slow the design down for observation. Everything
                                    // below simply holds still while this is low.
    input  wire        resetn,     // Synchronous reset, active-low (0 = reset asserted).

    output wire [31:0] mem_addr,   // Address to read from, or write to during STORE.
    input  wire [31:0] mem_rdata,  // Data read back, one cycle after mem_rstrb was high.
    output wire        mem_rstrb,  // High for one cycle: request a read at mem_addr.

    output wire [31:0] mem_wdata,  // Word to write during STORE (mem_wmask below
                                    // picks which of its bytes actually get written).
    output wire [3:0]  mem_wmask,  // Per-byte write enable for mem_wdata (bit i enables
                                    // byte i); all zero outside the STORE state.

    input  wire        mem_rbusy   // High while a read is still in flight and mem_rdata
                                    // is not valid yet. RAM and memory-mapped IO both
                                    // answer in exactly one cycle, so this is always low
                                    // for them; only SPI flash reads (see SPIFlash.v /
                                    // step1.v) hold it high, for as many cycles as their
                                    // multi-bit SPI shift takes. See WAIT_INSTR/WAIT_DATA
                                    // below for where this actually stalls the FSM.
);

    // Placeholder instruction used before the first real fetch completes, and
    // on reset: "ADD x0, x0, x0" -- a no-op, since x0 discards whatever is
    // written to it.
    localparam [31:0] NOP_CODEOP = 32'b0000000_00000_00000_000_00000_0110011;
    reg [31:0] PC    = RESET_PC;   // byte-addressed program counter (advanced by nextPC, see below)
    reg [31:0] instr = NOP_CODEOP; // instruction word currently being decoded/executed


    // -------------------------------------------------------------------------
    // Instruction decoder
    // -------------------------------------------------------------------------
    // instr[6:0] is the opcode: a 7-bit field that, on its own, already tells
    // us which RV32I instruction format/group we're looking at.
    wire isALUreg  =  (instr[6:0] == 7'b0110011); // R-type: rd <- rs1 OP rs2
    wire isALUimm  =  (instr[6:0] == 7'b0010011); // I-type: rd <- rs1 OP Iimm
    wire isBranch  =  (instr[6:0] == 7'b1100011); // B-type: if(rs1 OP rs2) PC<-PC+Bimm
    wire isJALR    =  (instr[6:0] == 7'b1100111); // I-type: rd <- PC+4; PC<-rs1+Iimm (e.g. RET)
    wire isJAL     =  (instr[6:0] == 7'b1101111); // J-type: rd <- PC+4; PC<-PC+Jimm (e.g. CALL)
    wire isAUIPC   =  (instr[6:0] == 7'b0010111); // U-type: rd <- PC+Uimm
    wire isLUI     =  (instr[6:0] == 7'b0110111); // U-type: rd <- Uimm
    wire isLoad    =  (instr[6:0] == 7'b0000011); // I-type: rd <- mem[rs1+Iimm]
    wire isStore   =  (instr[6:0] == 7'b0100011); // S-type: mem[rs1+Simm] <- rs2
    wire isSYSTEM  =  (instr[6:0] == 7'b1110011); // ECALL/EBREAK; only EBREAK is handled (see EXECUTE)
    // The 5 immediate-value encodings (R-type has no immediate). Every format
    // sign-extends from instr[31] using the replication operator {n{bit}},
    // which repeats a single bit n times. 
    // The source bits look scrambled because rs1/rs2/rd always sit at the same instr
    // positions in every format (see below), so each immediate is built out
    // of whatever bits are left around them:
    //   Uimm : instr[31:12] kept in place, 12 low bits zero      (LUI, AUIPC)
    //   Iimm : instr[31:20], sign-extended                       (ALUimm, Load, JALR)
    //   Simm : instr[31:25] : instr[11:7], sign-extended         (Store)
    //   Bimm : like Simm, but bit 0 is forced to 0 -- branch targets are
    //          always 2-byte aligned, so that bit is never stored, only implied
    //   Jimm : instr[31] + instr[19:12] + instr[20] + instr[30:21], bit 0
    //          forced to 0 for the same reason as Bimm
    wire [31:0] Uimm={    instr[31],   instr[30:12], {12{1'b0}}};
    wire [31:0] Iimm={{21{instr[31]}}, instr[30:20]};
    wire [31:0] Simm={{21{instr[31]}}, instr[30:25],instr[11:7]};
    wire [31:0] Bimm={{20{instr[31]}}, instr[7],instr[30:25],instr[11:8],1'b0};
    wire [31:0] Jimm={{12{instr[31]}}, instr[19:12],instr[20],instr[30:21],1'b0};
    // rs1/rs2/rd are 5-bit register indices (0..31), at the same bit positions
    // in every instruction format
    wire [4:0] rs1Id = instr[19:15]; // first source register
    wire [4:0] rs2Id = instr[24:20]; // second source register (S/R-type only)
    wire [4:0] rdId  = instr[11:7];  // destination register (not S/B-type)
    // funct3/funct7 select the specific operation within an opcode group
    // (which ALU op, which branch test, which load/store width, ...).
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];


    // -------------------------------------------------------------------------
    // Register bank
    // -------------------------------------------------------------------------
    // 32 general-purpose registers. x0 is architecturally hard-wired to zero:
    // nothing here ever writes RegisterBank[0] (guarded below), and reads of
    // x0 are separately forced to 0 in FETCH_REGS rather than relying on that.
    reg [31:0] RegisterBank [0:31];
    reg [31:0] rs1; // rs1Id's value, latched in FETCH_REGS, consumed in EXECUTE
    reg [31:0] rs2; // rs2Id's value, latched in FETCH_REGS, consumed in EXECUTE
    wire [31:0] writeBackData; // value that will be written to rd (driven further down)
    wire        writeBackEn;   // high => writeBackData is written to rd this cycle

    `ifdef BENCH
         // clear the register file at time 0 so the decode
         // trace below never prints an uninitialized ('x) value
         integer i;
         initial begin
             for (i = 0; i < 32; i = i + 1) begin
                 RegisterBank[i] = 32'd0;
             end
         end
     `endif


     // -------------------------------------------------------------------------
     // ALU
     // -------------------------------------------------------------------------
     wire [31:0] aluIn1 = rs1; // first operand (always rs1)
     // Second operand: register-register ops (ALUreg) read it from rs2,
     // register-immediate ops (ALUimm) read it from Iimm. Branch comparisons
     // don't go through the ALU at all -- see the next section.
     wire [31:0] aluIn2 = isALUreg ? rs2 : Iimm;

     // Shift amount: rs2's low 5 bits for ALUreg (SLL/SRL/SRA), or the
     // instruction's own immediate bits for ALUimm (SLLI/SRLI/SRAI).
     wire [4:0] shamt = isALUreg ? rs2[4:0] : instr[24:20]; // shift amount

     reg [31:0] aluOut;
     always @(*) begin
        case(funct3)
           // ADD and SUB share funct3=000; funct7[5] tells them apart, but
           // only for ALUreg -- there is no SUBI, so instr[5] (1 for ALUreg,
           // 0 for ALUimm) has to be ANDed in as well, otherwise an ADDI
           // whose funct7-shaped bits happen to be set would be misread as SUB.
           3'b000: aluOut = (funct7[5] & instr[5]) ? (aluIn1 - aluIn2) : (aluIn1 + aluIn2);
           3'b001: aluOut = aluIn1 << shamt;                              // SLL
           3'b010: aluOut = {31'b0, ($signed(aluIn1) < $signed(aluIn2))}; // SLT  (signed <)
           3'b011: aluOut = {31'b0, (aluIn1 < aluIn2)};                   // SLTU (unsigned <)
           3'b100: aluOut = (aluIn1 ^ aluIn2);                            // XOR
           // SRL and SRA also share one funct3 (101), split by funct7[5].
           // $signed(aluIn1) makes Verilog's >>> perform an arithmetic
           // (sign-extending) shift instead of a plain logical one -- that
           // sign-extension is exactly what SRA needs and SRL must not have.
           3'b101: aluOut = funct7[5] ? ($signed(aluIn1) >>> shamt) : (aluIn1 >> shamt);
           3'b110: aluOut = (aluIn1 | aluIn2);                            // OR
           3'b111: aluOut = (aluIn1 & aluIn2);                            // AND
        endcase
     end


     // -------------------------------------------------------------------------
     // Branch comparison logic
     // -------------------------------------------------------------------------
     // Computed directly from rs1/rs2
     reg takeBranch;
     always @(*) begin
         case (funct3)
            3'b000: takeBranch = (rs1 == rs2);                   // BEQ
            3'b001: takeBranch = (rs1 != rs2);                   // BNE
            3'b100: takeBranch = ($signed(rs1) <  $signed(rs2)); // BLT  (signed <)
            3'b101: takeBranch = ($signed(rs1) >= $signed(rs2)); // BGE  (signed >=)
            3'b110: takeBranch = (rs1  <  rs2);                  // BLTU (unsigned <)
            3'b111: takeBranch = (rs1  >= rs2);                  // BGEU (unsigned >=)
            // funct3 has 8 possible values but only 6 are valid branches; the
            // other 2 never occur for isBranch, but a combinational always
            // block still needs every case covered, or the synthesizer has to
            // infer a latch (extra state to "remember" the last value) instead
            // of plain logic for the missing cases. default keeps this
            // purely combinational.
            default: takeBranch = 1'b0;
         endcase
     end


     // -------------------------------------------------------------------------
     // Processor state machine
     // -------------------------------------------------------------------------
     // One instruction takes several clock cycles because Memory answers a
     // read one cycle after it is requested, and because latching two
     // registers out of the (synchronous) register file needs its own cycle
     // too:
     //   FETCH_INSTR : drive mem_addr = PC, request a read
     //   WAIT_INSTR  : latch the instruction word Memory now returns
     //   FETCH_REGS  : latch rs1/rs2 from the register file
     //   EXECUTE     : run the ALU/branch/jump logic and update PC; for
     //                 every instruction except Load/Store, this is also the
     //                 last cycle (writeBackEn fires here)
     //   LOAD        : drive mem_addr = loadstore_addr, request a read
     //   WAIT_DATA   : latch the loaded, aligned/sign-extended value into rd
     //   STORE       : drive mem_addr/mem_wdata/mem_wmask; Memory performs
     //                 the write on this same clock edge
     localparam FETCH_INSTR = 3'd0;
     localparam WAIT_INSTR  = 3'd1;
     localparam FETCH_REGS  = 3'd2;
     localparam EXECUTE     = 3'd3;
     localparam LOAD        = 3'd4;
     localparam WAIT_DATA   = 3'd5;
     localparam STORE       = 3'd6;

     // Power-on value matches the reset value below (WAIT_DATA, not
     // FETCH_INSTR) so that mem_rstrb is low from the very first clock edge --
     // see the reset block for the full reasoning.
     reg [2:0] state = WAIT_DATA;
     // Next-PC / jump-target computation: each destination gets its own
     // adder 
     // jalr_target is given its own name, rather than inlining rs1+Iimm
     // below, because Verilog does not allow bit-selecting a parenthesized
     // expression directly -- {(rs1+Iimm)[31:1], 1'b0} is not legal syntax,
     // but slicing a named wire like this is.
     wire [31:0] jalr_target = rs1 + Iimm; // named so we can slice off bit 0 below
     wire [31:0] nextPC = (isBranch && takeBranch) ? PC + Bimm :
                          isJAL                    ? PC + Jimm :
                          isJALR                    ? {jalr_target[31:1], 1'b0} :
                                                       PC + 32'd4;

     // LOAD:  address = rs1 + Iimm
     // STORE: address = rs1 + Simm (Store uses a different immediate format)
     wire [31:0] loadstore_addr = rs1 + (isStore ? Simm : Iimm);
     // Memory (see Memory.v) is word-addressed and always returns/accepts a
     // full 32-bit word, so byte/halfword loads and stores have to be
     // assembled or picked apart here, in terms of:
     // - funct3[1:0]:  00->byte 01->halfword 10->word
     // - loadstore_addr[1:0]: which byte/halfword within that word is meant

     wire mem_byteAccess     = funct3[1:0] == 2'b00;
     wire mem_halfwordAccess = funct3[1:0] == 2'b01;

     // Narrow mem_rdata (a full word) down to the halfword, then the byte,
     // that loadstore_addr actually points at.
     wire [15:0] LOAD_halfword =
             loadstore_addr[1] ? mem_rdata[31:16] : mem_rdata[15:0];
     wire  [7:0] LOAD_byte =
             loadstore_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];

     // LB/LH sign-extend the loaded value to 32 bits; LBU/LHU/LW don't.
     // funct3[2] (instr[14]) is 0 for the sign-extending variants (and for
     // LW, which needs no extension either way) and 1 for LBU/LHU.
     wire LOAD_sign =
      !funct3[2] & (mem_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);

     // Final value that a Load writes back to rd (see writeBackData below).
     wire [31:0] LOAD_data =
           mem_byteAccess ? {{24{LOAD_sign}},     LOAD_byte} :
       mem_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} :
                            mem_rdata ;

     // rs2's value, replicated into every byte lane it could possibly need
     // to land in. STORE_wmask (below) is what actually decides which
     // lane(s) Memory writes, so it is fine to broadcast rs2 everywhere here
     // and let the mask sort it out -- simpler than muxing mem_wdata itself
     // by access width.
     assign mem_wdata[ 7: 0] = rs2[7:0];
     assign mem_wdata[15: 8] = loadstore_addr[0] ? rs2[7:0]  : rs2[15: 8];
     assign mem_wdata[23:16] = loadstore_addr[1] ? rs2[7:0]  : rs2[23:16];
     assign mem_wdata[31:24] = loadstore_addr[0] ? rs2[7:0]  :
                   loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

     // Which byte lane(s) of mem_wdata Memory should actually write:
     //    1111                     if writing a word
     //    0011 or 1100             if writing a halfword
     //                                (depending on loadstore_addr[1])
     //    0001, 0010, 0100 or 1000 if writing a byte
     //                                (depending on loadstore_addr[1:0])

     wire [3:0] STORE_wmask =
            mem_byteAccess      ?
                  (loadstore_addr[1] ?
                    (loadstore_addr[0] ? 4'b1000 : 4'b0100) :
                    (loadstore_addr[0] ? 4'b0010 : 4'b0001)
                      ) :
            mem_halfwordAccess ?
                  (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
                4'b1111;

     // Value written back to rd. Exactly one of isJAL/isJALR/isLUI/isAUIPC/
     // isLoad/(neither, i.e. ALUreg or ALUimm) is ever true for a given
     // instruction -- they come from disjoint opcodes -- so this is a plain
     // priority mux over mutually-exclusive cases, not a real priority
     // encoder.
     assign writeBackData =
         (isJAL || isJALR) ? (PC + 32'd4) :  // the return address for a call
         isLUI             ? Uimm         :
         isAUIPC           ? (PC + Uimm)  :
         isLoad            ? LOAD_data    :
                             aluOut;          // ALUreg / ALUimm
     // rd is written during EXECUTE for every instruction that produces a
     // result immediately (everything except Branch/Store, which write
     // nothing, and Load, whose data is not ready until WAIT_DATA).
     // WAIT_DATA's own clause is additionally gated by !mem_rbusy: without
     // it, a multi-cycle SPI flash load would fire writeBackEn -- and latch
     // whatever garbage mem_rdata currently holds -- on every single stalled
     // cycle in WAIT_DATA, not just the final one. Harmless in the end
     // result (the last, valid write always overwrites the earlier bogus
     // ones before anything reads rd), but sloppy and misleading in the
     // BENCH trace below. RAM/IO loads are unaffected: mem_rbusy is already
     // low the very first cycle they reach WAIT_DATA.
     assign writeBackEn =
     (state == EXECUTE && !isBranch && !isStore && !isLoad) ||
     (state == WAIT_DATA && !mem_rbusy);

     // Reset is synchronous: on the clock edge where resetn is low, PC/state/
     // instr go back to their power-on values (nothing else needs clearing --
     // FETCH_INSTR with PC=0 guarantees the first real instruction is fetched
     // before anything ever reads a register). While running, clk_enable
     // gates this whole block: with clk_enable low, the processor simply
     // holds whatever state it was already in for another cycle.
     //
     // Register write-back is checked here on every cycle regardless of
     // state, but writeBackEn only actually goes high during the one state
     // -- EXECUTE or WAIT_DATA -- where a given instruction is ready to
     // produce its result, so in practice a register is written at most
     // once per instruction.
     always @(posedge clk) begin
         if(!resetn) begin
	        // PC goes to RESET_PC (see the parameter at the top of this file):
	        // 0 for BRAM boot, an SPI-flash address for flash boot.
	        PC    <= RESET_PC;

	        // state goes to WAIT_DATA rather than FETCH_INSTR, and that choice
	        // is load-bearing, not cosmetic. mem_rstrb (bottom of this file) is
	        // high for the WHOLE time state == FETCH_INSTR. Since reset is held
	        // for many cycles, resetting into FETCH_INSTR would hold mem_rstrb
	        // high for all of them -- and with PC in flash space, step1.v turns
	        // that into a spiflash_rstrb pulse EVERY cycle. SPIFlash.v restarts
	        // its transaction on each pulse (reloading cmd_addr, re-arming the
	        // bit counter) while never releasing CS_N, so the flash chip would
	        // see chip-select held low with a clock running and MOSI stuck --
	        // i.e. a garbage command it never gets to finish, with no
	        // deselect in between to resynchronise its command parser.
	        //
	        // WAIT_DATA asserts no strobe at all, so the flash stays idle and
	        // deselected throughout reset. The instant reset releases,
	        // WAIT_DATA sees mem_rbusy low and falls through to FETCH_INSTR,
	        // which issues exactly one clean rstrb pulse. Costs one extra
	        // cycle at boot; buys a correctly-framed first flash transaction.
	        //
	        // Note WAIT_DATA also asserts writeBackEn. That is harmless here:
	        // instr is reset to NOP_CODEOP, whose rd field is x0, and the
	        // write-back below is guarded by `rdId != 5'd0`.
	        //
	        // This is equally correct for BRAM boot (RAM never asserts
	        // mem_rbusy, so WAIT_DATA falls straight through) -- which is why
	        // it is unconditional rather than tied to the boot mode.
	        state <= WAIT_DATA;
	        instr <= NOP_CODEOP;
         end else if (clk_enable) begin
	        if(writeBackEn && rdId != 5'd0) begin
	            RegisterBank[rdId] <= writeBackData;
                `ifdef BENCH
                    $display("x%0d <= %b",rdId,writeBackData);
                `endif
	        end


            case(state)
                FETCH_INSTR: begin
                    state <= WAIT_INSTR; // mem_addr/mem_rstrb (bottom of file) already target PC
                end
                WAIT_INSTR: begin
                    // Memory/IO have had time to place the requested word on
                    // mem_rdata by now -- but SPI flash hasn't necessarily
                    // finished yet (see mem_rbusy above). Hold this state,
                    // leaving instr untouched, for as long as mem_rbusy stays
                    // high; only latch mem_rdata and advance once it drops.
                    // For RAM/IO, mem_rbusy is already low the very first
                    // time we get here, so this behaves exactly as before.
                    if (!mem_rbusy) begin
                        instr <= mem_rdata;
                        state <= FETCH_REGS;
                    end
                end

                FETCH_REGS: begin
                    // x0 always reads as 0 here, rather than relying on it
                    // simply never having been written -- makes the
                    // guarantee explicit instead of assumed.
                    rs1 <= (rs1Id == 5'd0) ? 32'd0 : RegisterBank[rs1Id];
                    rs2 <= (rs2Id == 5'd0) ? 32'd0 : RegisterBank[rs2Id];
                    state <= EXECUTE;
                end

                LOAD: begin
                    // In this state, mem_addr is loadstore_addr
                    // and mem_rstrb is high.
                    // Memory will return the data on the next clock.
                    state <= WAIT_DATA;
                end
                STORE: begin
                    // In this state:
                    //   mem_addr  = loadstore_addr
                    //   mem_wdata = aligned rs2 data
                    //   mem_wmask = STORE_wmask
                    //
                    // Memory writes the selected bytes on this clock edge.
                    // Unlike LOAD, there's no round trip to wait for here:
                    // a write has no answer for the processor to consume, so
                    // as soon as this edge passes the write has already
                    // happened -- state can go straight to FETCH_INSTR
                    // instead of through a WAIT_DATA-style extra state.
                    state <= FETCH_INSTR;
                end

                WAIT_DATA: begin
                    // Same mem_rbusy stall as WAIT_INSTR above -- a LW from
                    // SPI flash space needs many cycles here; RAM/IO loads
                    // still resolve in exactly one, same as before this was
                    // added. Once mem_rbusy drops, mem_rdata holds the
                    // loaded word, and writeBackEn (below) fires on this
                    // same cycle to write LOAD_data to rd.
                    if (!mem_rbusy) begin
                        state <= FETCH_INSTR;
                    end
                end

                EXECUTE: begin
                    // Branch/jump targets are already resolved in nextPC
                    // above; SYSTEM (EBREAK) leaves PC untouched, since this
                    // simple core has nowhere meaningful to continue to.
                    if (!isSYSTEM) begin
                        PC <= nextPC;
                    end
                    // LOAD needs an extra memory-read state.
                    // STORE needs an extra memory-write state.
                    // Other instructions continue directly to FETCH_INSTR.
                    state <= isLoad  ? LOAD  :
                             isStore ? STORE :
                                       FETCH_INSTR;

                   `ifdef BENCH
                       // EBREAK just stops the simulator; real hardware has
                       // no equivalent here and would sit at this PC forever.
                       if(isSYSTEM) $finish();
                   `endif
                end
           endcase
         end
     end

     // Outside instruction fetch (i.e. during LOAD/STORE), mem_addr targets
     // the load/store address instead of PC.
     assign mem_addr =
         (state == FETCH_INSTR || state == WAIT_INSTR) ? PC : loadstore_addr;

     // Request a read while fetching an instruction, and again while loading data.
     assign mem_rstrb =
         (state == FETCH_INSTR || state == LOAD);

     // {4{(state==STORE)}} replicates that 1-bit condition into a 4-bit mask,
     // so mem_wmask is forced to all-zero everywhere except during STORE,
     // where it becomes STORE_wmask.
     assign mem_wmask = {4{(state == STORE)}} & STORE_wmask;



`ifdef BENCH
    // Simulation-only instruction trace, compiled out for real synthesis.
    // case(1'b1) with boolean expressions as the case items is a common
    // Verilog idiom for a priority if-else chain: whichever item is the
    // first to evaluate to 1'b1 (i.e. the first true condition) is the one
    // that runs -- here, exactly one isXXX signal is ever true at a time.
    always @(posedge clk) begin
        if (clk_enable && state == FETCH_REGS) begin
            case (1'b1)
                isALUreg: $display("ALUreg rd=%0d rs1=%0d rs2=%0d funct3=%b funct7=%b",rdId, rs1Id, rs2Id, funct3, funct7);
                isALUimm: $display("ALUimm rd=%0d rs1=%0d imm=%0d funct3=%b",rdId, rs1Id, Iimm, funct3);
                isBranch: $display("BRANCH rs1=%0d rs2=%0d funct3=%b Bimm=%0d",rs1Id, rs2Id, funct3, $signed(Bimm));
                isJAL:    $display("JAL rd=%0d Jimm=%0d nextPC=%0d", rdId, Jimm, nextPC);
                isJALR:   $display("JALR rd=%0d rs1=%0d Iimm=%0d nextPC=%0d", rdId, rs1Id, Iimm, nextPC);
                isAUIPC:  $display("AUIPC rd=%0d Uimm=%08x PC=%0d write=%08x",rdId, Uimm, PC, PC + Uimm);
                isLUI:    $display("LUI rd=%0d Uimm=%08x",rdId, Uimm);
                isLoad:   $display("LOAD");
                isStore:  $display("STORE");
                isSYSTEM: $display("SYSTEM");
            endcase
        end
    end
`endif
endmodule
