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

    // 1536 words = 1536 * 4 bytes = 6144 bytes = 6 KB RAM.
    reg [31:0] MEM [0:1535];

    initial begin
        // Load the assembled RISC-V program.
        // program.hex must contain one 32-bit instruction word per line.
        $readmemh("program.hex", MEM);
        
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
