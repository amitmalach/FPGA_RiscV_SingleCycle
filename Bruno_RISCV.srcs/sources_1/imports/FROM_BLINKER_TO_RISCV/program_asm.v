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
       localparam slow_bit=0;
    `else
       localparam slow_bit=20;
    `endif

    // Memory-mapped IO in IO page, using one-hot word addressing.
    localparam IO_LEDS_bit      = 0;
    localparam IO_UART_DAT_bit  = 1;
    localparam IO_UART_CNTL_bit = 2;
    
    // Convert IO bit number into byte offset.
    //
    // bit 0 -> 1 << 2 = 4
    // bit 1 -> 1 << 3 = 8
    // bit 2 -> 1 << 4 = 16
    function [31:0] IO_BIT_TO_OFFSET;
        input [31:0] bitid;
        begin
            IO_BIT_TO_OFFSET = 1 << (bitid + 2);
        end
    endfunction
    
    integer i;
    integer fd;
    integer num_words;
    integer L0_      = 12;
    integer L1_      = 20;
    integer L2_      = 52;
    integer wait_    = 104;
    integer wait_L0_ = 112;
    integer putc_    = 124;
    integer putc_L0_ = 132;
    
    initial begin
        memPC = 0;
    
        LI(sp, 32'h1800);       // end of 6 KB RAM
        LI(gp, 32'h400000);     // I/O page base address
    
        Label(L0_);
    
            // Count from 0 to 15 on LEDs.
            LI(s0, 16);
            LI(a0, 0);
    
        Label(L1_);
    
            SW(a0, gp, IO_BIT_TO_OFFSET(IO_LEDS_bit));
            CALL(LabelRef(wait_));
            ADDI(a0, a0, 1);
            BNE(a0, s0, LabelRef(L1_));
    
            // Send abcdef...xyz to UART.
            LI(s0, 26);
            LI(a0, "a");
            LI(s1, 0);
    
        Label(L2_);
    
            CALL(LabelRef(putc_));
            ADDI(a0, a0, 1);
            ADDI(s1, s1, 1);
            BNE(s1, s0, LabelRef(L2_));
    
            // CR LF.
            LI(a0, 13);
            CALL(LabelRef(putc_));
    
            LI(a0, 10);
            CALL(LabelRef(putc_));
    
            J(LabelRef(L0_));
    
            EBREAK();
    
        Label(wait_);
    
            LI(t0, 1);
            SLLI(t0, t0, slow_bit);
    
        Label(wait_L0_);
    
            ADDI(t0, t0, -1);
            BNEZ(t0, LabelRef(wait_L0_));
            RET();
    
        Label(putc_);
    
            SW(a0, gp, IO_BIT_TO_OFFSET(IO_UART_DAT_bit));
    
            LI(t0, 1 << 9);
    
        Label(putc_L0_);
    
            LW(t1, gp, IO_BIT_TO_OFFSET(IO_UART_CNTL_bit));
            AND(t1, t1, t0);
            BNEZ(t1, LabelRef(putc_L0_));
            RET();
    
        endASM();
    
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
