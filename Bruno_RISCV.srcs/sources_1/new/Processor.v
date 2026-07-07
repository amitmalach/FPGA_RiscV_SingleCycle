// -----------------------------------------------------------------------------
// CPU
// -----------------------------------------------------------------------------
module Processor (
    input  wire        clk,
    input  wire        clk_enable, // one-cycle enable pulse from Clockworks
    input  wire        resetn,     // active-low reset

    output wire [31:0] mem_addr,
    input  wire [31:0] mem_rdata,
    output wire        mem_rstrb,
    
    output wire [31:0] mem_wdata,  // data written to memory by STORE
    output wire [3:0]  mem_wmask   // byte mask for STORE

);

    // add x0, x0, x0
    localparam [31:0] NOP_CODEOP = 32'b0000000_00000_00000_000_00000_0110011;
    reg [31:0] PC    = 32'd0;                  // byte-addressed program counter
    reg [31:0] instr = NOP_CODEOP;                  // current instruction
    
    
    // ------------------------------------------------------------------------- 
    // Instruction decoder
    // -------------------------------------------------------------------------
    wire isALUreg  =  (instr[6:0] == 7'b0110011); // rd <- rs1 OP rs2   
    wire isALUimm  =  (instr[6:0] == 7'b0010011); // rd <- rs1 OP Iimm
    wire isBranch  =  (instr[6:0] == 7'b1100011); // if(rs1 OP rs2) PC<-PC+Bimm
    wire isJALR    =  (instr[6:0] == 7'b1100111); // rd <- PC+4; PC<-rs1+Iimm
    wire isJAL     =  (instr[6:0] == 7'b1101111); // rd <- PC+4; PC<-PC+Jimm
    wire isAUIPC   =  (instr[6:0] == 7'b0010111); // rd <- PC + Uimm
    wire isLUI     =  (instr[6:0] == 7'b0110111); // rd <- Uimm   
    wire isLoad    =  (instr[6:0] == 7'b0000011); // rd <- mem[rs1+Iimm]
    wire isStore   =  (instr[6:0] == 7'b0100011); // mem[rs1+Simm] <- rs2
    wire isSYSTEM  =  (instr[6:0] == 7'b1110011); // special
    // The 5 immediate formats
    wire [31:0] Uimm={    instr[31],   instr[30:12], {12{1'b0}}};
    wire [31:0] Iimm={{21{instr[31]}}, instr[30:20]};
    wire [31:0] Simm={{21{instr[31]}}, instr[30:25],instr[11:7]};
    wire [31:0] Bimm={{20{instr[31]}}, instr[7],instr[30:25],instr[11:8],1'b0};
    wire [31:0] Jimm={{12{instr[31]}}, instr[19:12],instr[20],instr[30:21],1'b0};
    // Source and destination registers
    wire [4:0] rs1Id = instr[19:15];
    wire [4:0] rs2Id = instr[24:20];
    wire [4:0] rdId  = instr[11:7];
    // Function codes
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];
    
    
    // -------------------------------------------------------------------------
    // Register bank
    // -------------------------------------------------------------------------
    reg [31:0] RegisterBank [0:31]; // 32 general-purpose RISC-V registers, x0..x31.
    reg [31:0] rs1;
    reg [31:0] rs2;
    wire [31:0] writeBackData;
    wire        writeBackEn;

    `ifdef BENCH
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
     wire [31:0] aluIn1 = rs1;                                
     wire [31:0] aluIn2 = (isALUreg | isBranch) ? rs2 : Iimm;
     
     wire [4:0] shamt = isALUreg ? rs2[4:0] : instr[24:20]; // shift amount
     
     // The adder is used by both arithmetic instructions and JALR.
     wire [31:0] aluPlus = aluIn1 + aluIn2;
     
     // Use a single 33 bits subtract to do subtraction and all comparisons
     wire [32:0] aluMinus = {1'b1, ~aluIn2} + {1'b0,aluIn1} + 33'b1;
     wire        LT  = (aluIn1[31] ^ aluIn2[31]) ? aluIn1[31] : aluMinus[32];
     wire        LTU = aluMinus[32];     
     wire        EQ  = (aluMinus[31:0] == 0);
     
     // Flip a 32-bit word. Used to implement left shifts using the same physical shifter as right shifts.
     function [31:0] flip32;
         input [31:0] x;
         begin
             flip32 = {
                 x[ 0], x[ 1], x[ 2], x[ 3], x[ 4], x[ 5], x[ 6], x[ 7],
                 x[ 8], x[ 9], x[10], x[11], x[12], x[13], x[14], x[15],
                 x[16], x[17], x[18], x[19], x[20], x[21], x[22], x[23],
                 x[24], x[25], x[26], x[27], x[28], x[29], x[30], x[31]
             };
         end
     endfunction
     
     wire [31:0] shifter_in = (funct3 == 3'b001) ? flip32(aluIn1) : aluIn1;
     // A single right shifter implements SRL/SRA and, using bit reversal, SLL.
     wire [31:0] shifter = $signed({instr[30] & aluIn1[31], shifter_in}) >>> shamt;
     wire [31:0] leftshift = flip32(shifter);
         
     reg [31:0] aluOut;
     always @(*) begin
        case(funct3)
	       3'b000: aluOut = (funct7[5] & instr[5]) ? aluMinus[31:0] : aluPlus;
           3'b001: aluOut = leftshift;
           3'b010: aluOut = {31'b0, LT};
           3'b011: aluOut = {31'b0, LTU};
           3'b100: aluOut = (aluIn1 ^ aluIn2);
           3'b101: aluOut = shifter;
           3'b110: aluOut = (aluIn1 | aluIn2);
           3'b111: aluOut = (aluIn1 & aluIn2);    
        endcase
     end
     
     
     // -------------------------------------------------------------------------
     // Branch comparison logic
     // -------------------------------------------------------------------------
     reg takeBranch;
     always @(*) begin
         case (funct3)
            3'b000: takeBranch = EQ;
            3'b001: takeBranch = !EQ;
            3'b100: takeBranch = LT;
            3'b101: takeBranch = !LT;
            3'b110: takeBranch = LTU;
            3'b111: takeBranch = !LTU;
            default: takeBranch = 1'b0;
         endcase
     end
     
     
     // -------------------------------------------------------------------------
     // Processor state machine
     // -------------------------------------------------------------------------
     // FETCH_INSTR : ask memory for instruction at PC
     // WAIT_INSTR  : wait one cycle for instruction memory
     // FETCH_REGS  : read rs1 and rs2 from register bank
     // EXECUTE     : execute normal instruction or compute load address
     // LOAD        : ask memory for data at load address
     // WAIT_DATA   : wait one cycle, then write loaded data to rd
     localparam FETCH_INSTR = 3'd0;
     localparam WAIT_INSTR  = 3'd1;
     localparam FETCH_REGS  = 3'd2;
     localparam EXECUTE     = 3'd3;
     localparam LOAD        = 3'd4;
     localparam WAIT_DATA   = 3'd5;
     localparam STORE       = 3'd6;
     
     reg [2:0] state = FETCH_INSTR;
     // Address computation
     // An adder used to compute branch address, JAL address and AUIPC.
     // branch->PC+Bimm    AUIPC->PC+Uimm    JAL->PC+Jimm
     // Equivalent to PCplusImm = PC + (isJAL ? Jimm : isAUIPC ? Uimm : Bimm)
     wire [31:0] PCplusImm = PC + (instr[3] ? Jimm :
                                   instr[4] ? Uimm :
                                              Bimm);
     wire [31:0] PCplus4 = PC + 32'd4;
     
     wire [31:0] nextPC = ((isBranch && takeBranch) || isJAL) ? PCplusImm  :	       
                                           isJALR                              ? {aluPlus[31:1],1'b0}:
                                           PCplus4;
                                           
     // LOAD:  address = rs1 + Iimm
     // STORE: address = rs1 + Simm
     wire [31:0] loadstore_addr = rs1 + (isStore ? Simm : Iimm);  
     // All memory accesses are aligned on 32 bits boundary. For this
     // reason, we need some circuitry that does unaligned halfword
     // and byte load/store, based on:
     // - funct3[1:0]:  00->byte 01->halfword 10->word
     // - mem_addr[1:0]: indicates which byte/halfword is accessed
  
     wire mem_byteAccess     = funct3[1:0] == 2'b00;
     wire mem_halfwordAccess = funct3[1:0] == 2'b01;
  
     wire [15:0] LOAD_halfword =
             loadstore_addr[1] ? mem_rdata[31:16] : mem_rdata[15:0];
     wire  [7:0] LOAD_byte =
             loadstore_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];     
             
     // LOAD, in addition to funct3[1:0], LOAD depends on:
     // - funct3[2] (instr[14]): 0->do sign expansion   1->no sign expansion
     wire LOAD_sign =
      !funct3[2] & (mem_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);
  
     wire [31:0] LOAD_data =
           mem_byteAccess ? {{24{LOAD_sign}},     LOAD_byte} :
       mem_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} :
                            mem_rdata ; 
                            
     assign mem_wdata[ 7: 0] = rs2[7:0];
     assign mem_wdata[15: 8] = loadstore_addr[0] ? rs2[7:0]  : rs2[15: 8];
     assign mem_wdata[23:16] = loadstore_addr[1] ? rs2[7:0]  : rs2[23:16];
     assign mem_wdata[31:24] = loadstore_addr[0] ? rs2[7:0]  :
                   loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

     // The memory write mask:
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
                        
     // Write ALU result back to rd during EXECUTE.
     assign writeBackData =
         (isJAL || isJALR) ? PCplus4   :
         isLUI             ? Uimm      :
         isAUIPC           ? PCplusImm :
         isLoad            ? LOAD_data :
                             aluOut;
     assign writeBackEn = 
     (state == EXECUTE && !isBranch && !isStore && !isLoad) ||
     (state == WAIT_DATA);                             
                                                 
     always @(posedge clk) begin
         if(!resetn) begin
	        PC    <= 32'd0;
	        state <= FETCH_INSTR;
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
                    state <= WAIT_INSTR;
                end
                WAIT_INSTR: begin
                    // Memory has had time to place the requested instruction on mem_rdata.
                    instr <= mem_rdata;
                    state <= FETCH_REGS;
                end

                FETCH_REGS: begin
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
                    state <= FETCH_INSTR;
                end
                
                WAIT_DATA: begin
                    // Now mem_rdata contains the loaded word.
                    // writeBackEn is high in this state, so LOAD_data is written to rd.
                    state <= FETCH_INSTR;
                end

                EXECUTE: begin
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
                       if(isSYSTEM) $finish();
                   `endif      
                end
           endcase
         end 
     end 
     
     // During instruction fetch, memory address is PC.
     // During data load, memory address is rs1 + Iimm.
     assign mem_addr =
         (state == FETCH_INSTR || state == WAIT_INSTR) ? PC : loadstore_addr;
     
     // Read memory either when fetching an instruction or when loading data.
     assign mem_rstrb =
         (state == FETCH_INSTR || state == LOAD);
         
     assign mem_wmask = {4{(state == STORE)}} & STORE_wmask;


    
`ifdef BENCH
    // Print a readable decode trace during simulation.
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