`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// Instruction memory
// -----------------------------------------------------------------------------
module Memory (
    input  wire        clk,
    input  wire        clk_enable,
    
    input  wire [31:0] mem_addr,               // byte address requested by the processor
    output reg  [31:0] mem_rdata,              // instruction word returned to the processor
    input  wire        mem_rstrb,               // Memory Read Strobe (high when processor requests a read)
    
    input  wire [31:0] mem_wdata,  // 32-bit write data from processor
    input  wire [3:0]  mem_wmask   // byte write mask: one bit per byte
);

    // 256 instruction words = 1024 bytes.
    reg [31:0] MEM [0:255];

    initial begin
        // Load the assembled RISC-V program.
        // program.hex must contain one 32-bit instruction word per line.
        $readmemh("program.hex", MEM);
        
        MEM[100] = {8'h04, 8'h03, 8'h02, 8'h01};
        MEM[101] = {8'h08, 8'h07, 8'h06, 8'h05};
        MEM[102] = {8'h0c, 8'h0b, 8'h0a, 8'h09};
        MEM[103] = {8'hff, 8'h0f, 8'h0e, 8'h0d};
    end

    // Synchronous read.
    // The processor raises mem_rstrb in FETCH_INSTR and consumes mem_rdata later in WAIT_INSTR.
    always @(posedge clk) begin
        if(clk_enable) begin
            if (mem_rstrb) begin
                mem_rdata <= MEM[mem_addr[31:2]];
            end
            // Write selected bytes.
            if (mem_wmask[0]) MEM[mem_addr[31:2]][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wmask[1]) MEM[mem_addr[31:2]][15: 8] <= mem_wdata[15: 8];
            if (mem_wmask[2]) MEM[mem_addr[31:2]][23:16] <= mem_wdata[23:16];
            if (mem_wmask[3]) MEM[mem_addr[31:2]][31:24] <= mem_wdata[31:24];
            
        end
    end

endmodule
