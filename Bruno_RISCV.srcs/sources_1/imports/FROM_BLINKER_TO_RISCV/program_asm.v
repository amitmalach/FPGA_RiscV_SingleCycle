`timescale 1ns/1ps
`default_nettype none

/*
 * This file generates program.hex from readable assembly-style code.
 * It is not part of the FPGA hardware.
 */
 
 /* To create the program.hex file need to do:
  * set SRC_DIR "/home/amit/vivado_projects/Bruno_RISCV/Bruno_RISCV.srcs/sources_1/imports/FROM_BLINKER_TO_RISCV"
  *      
  * # Go to the folder that contains program_asm.v and riscv_assembly.v
  * set BASE_DIR [pwd]
  * cd $SRC_DIR
  * 
  * # Generate program.hex from the Verilog assembler
  * # Using Debug mode:
  * exec iverilog -DBENCH -o program_asm.out program_asm.v
  * # Debug mode off:
  * exec iverilog -o program_asm.out program_asm.v
  * exec vvp program_asm.out
  *
  * # Return to original Vivado directory
  * cd $BASE_DIR
  *
  *
 */

module program_asm;

    reg [31:0] MEM [0:255];

    // Use the original tutorial assembler unchanged.
    `include "riscv_assembly.v"
    
    `ifdef BENCH
       localparam slow_bit=4;
    `else
       localparam slow_bit=20;
    `endif


    integer i;
    integer fd;
    integer num_words;
    integer L0_   = 12;
    integer L1_   = 40;
    integer wait_ = 64;
    integer L2_   = 72;
    
    initial begin
        memPC = 0;
    
        // Initialize LED register.
        LI(a0, 0);
    
        // ------------------------------------------------------------
        // Copy 16 bytes from address 400 to address 800
        // ------------------------------------------------------------
    
        // s1 = 16
        // This is the loop stopping value.
        LI(s1, 16);
    
        // s0 = 0
        // This is the byte index.
        LI(s0, 0);
    
        Label(L0_);
    
            // a1 = memory byte at address 400 + s0
            // Source address range: 400..415
            LB(a1, s0, 400);
    
            // memory byte at address 800 + s0 = a1[7:0]
            // Destination address range: 800..815
            SB(a1, s0, 800);
    
            // Wait so the copy phase is visible/slow enough.
            CALL(LabelRef(wait_));
    
            // s0 = s0 + 1
            ADDI(s0, s0, 1);
    
            // Continue until s0 == 16.
            BNE(s0, s1, LabelRef(L0_));
    
    
        // ------------------------------------------------------------
        // Read 16 bytes back from address 800 and show them on LEDs
        // ------------------------------------------------------------
    
        // s0 = 0
        LI(s0, 0);
    
        Label(L1_);
    
            // a0 = memory byte at address 800 + s0
            // Since LEDs display a0/x10, this shows copied data.
            LB(a0, s0, 800);
    
            // Wait so each LED value is visible.
            CALL(LabelRef(wait_));
    
            // s0 = s0 + 1
            ADDI(s0, s0, 1);
    
            // Continue until s0 == 16.
            BNE(s0, s1, LabelRef(L1_));
    
            // Stop after displaying all copied bytes.
            EBREAK();
    
    
        // ------------------------------------------------------------
        // wait() subroutine
        // ------------------------------------------------------------
    
        Label(wait_);
    
            // t0 = 1
            LI(t0, 1);
    
            // t0 = 1 << slow_bit
            // This creates the delay-loop count.
            SLLI(t0, t0, slow_bit);
    
        Label(L2_);
    
            // t0 = t0 - 1
            ADDI(t0, t0, -1);
    
            // Repeat until t0 == 0.
            BNEZ(t0, LabelRef(L2_));
    
            // Return to caller.
            RET();
   
        endASM();

        // memPC is a byte address, so divide by 4 to get number of words.
        num_words = memPC >> 2;

        fd = $fopen("program.hex", "w");
        for (i = 0; i < num_words; i = i + 1) begin
            $fdisplay(fd, "%08x", MEM[i]);
        end
        $fclose(fd);
        $display("Generated program.hex with %0d words.", num_words);
        $finish;
    end

endmodule

`default_nettype wire
