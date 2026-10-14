`timescale 1ns/1ps
`default_nettype none

/*
 * This file generates program.hex from readable assembly-style code.
 * It is not part of the FPGA hardware.
 */

/*
 * To regenerate program.hex (a RAM image in the same format as rtl/firmware.hex):
 *   make -C sim/asm [DEFS=-DBENCH]
 */

/*
 * step18: Mandelbrot set in ASCII art over UART. Pure software -- no
 * hardware changes from step17; the same Processor/Memory/SOC/UART this
 * project already has hardware-verified is reused completely unchanged.
 *
 * There is no hardware multiplier (this core implements plain RV32I, and
 * MUL is part of the separate RV32M extension), so real-number math is
 * done two ways at once here:
 *   - Numbers are represented in Q22.10 fixed point: 10 fractional bits,
 *     so a real number x is stored as the integer x*2^10. Add/subtract
 *     need no adjustment (the 2^10 factor cancels); multiply produces a
 *     2^20-scaled result that has to be shifted right by 10 to rescale.
 *   - The actual multiply is done in software: mulsi3_ below is the same
 *     shift-and-add routine the tutorial ports from gcc's libgcc (the
 *     library routine gcc itself emits calls to when targeting an RV32I
 *     core with no MUL instruction).
 *
 * Renders an 80x80 character escape-time Mandelbrot over the viewport
 * [-2,2]x[-2,2]: each pixel iterates Z <- Z^2+C (up to 9 times, starting
 * from Z=C), and is colored by how many iterations it survived before
 * |Z| exceeded 2, via colormap_'s darkest-to-brightest 10-character ramp.
 * Loops forever, redrawing the same fixed view every pass -- see the
 * tutorial's own "try that, modify it to draw your own graphics"
 * suggestion if you want to animate/zoom/pan instead.
 */

module program_asm;

    reg [31:0] MEM [0:255];

    // Use the assembler
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

    // Q22.10 fixed-point constants for the Mandelbrot viewport
    // [-2,2]x[-2,2], mapped across an 80x80 character grid.
    `define mandel_shift 10
    `define mandel_mul (1 << `mandel_shift)
    `define xmin (-2*`mandel_mul)
    `define xmax ( 2*`mandel_mul)
    `define ymin (-2*`mandel_mul)
    `define ymax ( 2*`mandel_mul)
    `define dx ((`xmax-`xmin)/80)
    `define dy ((`ymax-`ymin)/80)
    `define norm_max (4 << `mandel_shift)

    // Labels left uninitialized on purpose: run once under -DBENCH first,
    // read the "Label:" values it prints (in the same order as the Label()
    // calls below), then fill them in here and re-run until ASMerror is 0.
    // See riscv_assembly.v's own header comment for this workflow.
    integer mandelstart_ = 12;
    integer blink_       = 16;
    integer loop_y_      = 76;
    integer loop_x_      = 84;
    integer loop_Z_      = 96;
    integer exit_Z_      = 188;
    integer wait_        = 276;
    integer wait_L0_     = 284;
    integer putc_        = 296;
    integer putc_L0_     = 304;
    integer mulsi3_      = 320;
    integer mulsi3_L0_   = 328;
    integer mulsi3_L1_   = 340;
    integer colormap_    = 356;

    // Register roles through the render loop:
    //   s0,s1    : pixel X,Y (column, row)
    //   s2,s3    : C (real, imaginary) -- current pixel's coordinate
    //   s4,s5    : Z (real, imaginary) -- the iterate, starts at C
    //   s6,s7,s8 : Zr*Zr, 2*Zr*Zi, Zi*Zi -- scratch for one Z<-Z^2+C step
    //   s10      : iterations remaining, counts down from 9. Its value
    //              when the loop exits selects colormap_'s character:
    //              escaping immediately leaves it high ("far outside",
    //              a bright character); never escaping runs it to 0
    //              ("probably inside", the blank character).
    //   s11      : 80, the loop bound (both X and Y)

    initial begin
        memPC = 0;

        LI(sp, 32'h1800);       // end of 6 KB RAM
        LI(gp, 32'h400000);     // I/O page base address

        Label(mandelstart_);

        // ---------------------------------------------------------------
        // Blink LEDS 5 times: a visible "starting a fresh render" cue --
        // useful here because one full 80x80 frame takes a while on this
        // non-pipelined, no-hardware-multiply core.
        // ---------------------------------------------------------------
        LI(s0, 5);

        Label(blink_);

            LI(a0, 8'h0F);
            SW(a0, gp, IO_BIT_TO_OFFSET(IO_LEDS_bit));
            CALL(LabelRef(wait_));
            LI(a0, 8'hF0);
            SW(a0, gp, IO_BIT_TO_OFFSET(IO_LEDS_bit));
            CALL(LabelRef(wait_));
            ADDI(s0, s0, -1);
            BNEZ(s0, LabelRef(blink_));

        LI(a0, 0);
        SW(a0, gp, IO_BIT_TO_OFFSET(IO_LEDS_bit));

        // ---------------------------------------------------------------
        // Outer loop: Y (row). s3 holds C's imaginary part for this row.
        // ---------------------------------------------------------------
        LI(s1, 0);
        LI(s3, `ymin);
        LI(s11, 80);

        Label(loop_y_);

            LI(s0, 0);
            LI(s2, `xmin);

        // -----------------------------------------------------------
        // Inner loop: X (column). s2 holds C's real part for this pixel.
        // -----------------------------------------------------------
        Label(loop_x_);

            MV(s4, s2);          // Z <- C
            MV(s5, s3);

            LI(s10, 9);          // iterations remaining

        Label(loop_Z_);

            // Zrr <- (Zr*Zr) >> mandel_shift
            MV(a0, s4);
            MV(a1, s4);
            CALL(LabelRef(mulsi3_));
            SRLI(s6, a0, `mandel_shift);

            // 2*Zri <- (Zr*Zi) >> (mandel_shift-1) -- the extra "-1" here
            // (instead of mandel_shift) folds in the factor of 2 that the
            // complex-square cross term Zr*Zi+Zi*Zr needs.
            MV(a0, s4);
            MV(a1, s5);
            CALL(LabelRef(mulsi3_));
            SRAI(s7, a0, `mandel_shift-1);

            // Zii <- (Zi*Zi) >> mandel_shift
            MV(a0, s5);
            MV(a1, s5);
            CALL(LabelRef(mulsi3_));
            SRLI(s8, a0, `mandel_shift);

            SUB(s4, s6, s8);     // Zr <- Zrr - Zii + Cr
            ADD(s4, s4, s2);
            ADD(s5, s7, s3);     // Zi <- 2*Zri + Ci

            ADD(s6, s6, s8);     // s6 <- Zrr+Zii, an approximation of |Z|^2
            LI(s7, `norm_max);
            BGT(s6, s7, LabelRef(exit_Z_)); // escaped -> exit, s10 unchanged

            ADDI(s10, s10, -1);
            BNEZ(s10, LabelRef(loop_Z_));

        Label(exit_Z_);

            LI(a0, colormap_);
            ADD(a0, a0, s10);
            LBU(a0, a0, 0);
            CALL(LabelRef(putc_));

            ADDI(s0, s0, 1);
            ADDI(s2, s2, `dx);
            BNE(s0, s11, LabelRef(loop_x_));

        // end of row
        LI(a0, " ");
        CALL(LabelRef(putc_));
        LI(a0, 13);          // CR: return to column 0 -- not every terminal
        CALL(LabelRef(putc_)); // treats a bare LF as an implicit CR too (see
                               // the note by this project's self-test's
                               // banner_ string for the same convention)
        LI(a0, "\n");        // LF: move to the next line
        CALL(LabelRef(putc_));

        ADDI(s1, s1, 1);
        ADDI(s3, s3, `dy);
        BNE(s1, s11, LabelRef(loop_y_));

        J(LabelRef(mandelstart_)); // redraw the same view again, forever

        EBREAK(); // never reached; kept before the subroutines in case the
                  // loop above is ever changed to exit instead of looping

        // ---------------------------------------------------------------
        // wait_: fixed delay, only used by the LED blink above (slow_bit=0
        // for fast BENCH simulation, 20 for a visible on-board blink rate,
        // same convention as this project's earlier self-test program).
        // ---------------------------------------------------------------
        Label(wait_);

            LI(t0, 1);
            SLLI(t0, t0, slow_bit);

        Label(wait_L0_);

            ADDI(t0, t0, -1);
            BNEZ(t0, LabelRef(wait_L0_));
            RET();

        // ---------------------------------------------------------------
        // putc_ / putc_L0_: unchanged from this project's earlier
        // self-test program (already proven working end-to-end on real
        // hardware). No subroutine in this file calls another subroutine
        // (mulsi3_/putc_/wait_ are all leaves), so unlike that earlier
        // program's putstring_, nothing here needs ra saved on the stack.
        //
        // NOTE on CALL() and code placement: CALL(offset) expands to
        // AUIPC(x6,offset); JALR(x1,x6,offset[11:0]), and AUIPC's task
        // takes the raw offset as its upper-immediate with no "round up
        // when the low 12 bits are negative" correction (unlike LI(),
        // which does apply that correction). That correction is exactly
        // what's needed whenever offset[11:0]'s own bit 11 is set -- which
        // happens for essentially any *backward* CALL(), even a very
        // short one. So every CALL() in this file is deliberately arranged
        // to target something defined AFTER it (the render loop calls
        // forward into mulsi3_/putc_, blink_ calls forward into wait_).
        // J() and the B-type branches (BEQ/BNE/BGT/BEQZ/BNEZ) encode their
        // target directly as one signed field and are not affected --
        // backward branches/jumps elsewhere in this file are fine.
        // ---------------------------------------------------------------
        Label(putc_);

            SW(a0, gp, IO_BIT_TO_OFFSET(IO_UART_DAT_bit));

            LI(t0, 1 << 9);

        Label(putc_L0_);

            LW(t1, gp, IO_BIT_TO_OFFSET(IO_UART_CNTL_bit));
            AND(t1, t1, t0);
            BNEZ(t1, LabelRef(putc_L0_));
            RET();

        // ---------------------------------------------------------------
        // mulsi3_: software 32x32 multiply (shift-and-add), ported from
        // gcc's libgcc the same way the tutorial does it -- this core has
        // no hardware MUL. Input in a0/a1, product in a0.
        // ---------------------------------------------------------------
        Label(mulsi3_);

            MV(a2, a0);
            LI(a0, 0);

        Label(mulsi3_L0_);

            ANDI(a3, a1, 1);
            BEQZ(a3, LabelRef(mulsi3_L1_));
            ADD(a0, a0, a2);

        Label(mulsi3_L1_);

            SRLI(a1, a1, 1);
            SLLI(a2, a2, 1);
            BNEZ(a1, LabelRef(mulsi3_L0_));
            RET();

        // ---------------------------------------------------------------
        // colormap_: darkest-to-brightest character ramp, indexed 0..9 by
        // the iteration count left in s10 when a pixel's loop exits. The
        // last two bytes are padding to fill out the final DATAB word --
        // never read, since s10 never exceeds 9.
        // ---------------------------------------------------------------
        Label(colormap_);
            DATAB(" ",".",",",":");
            DATAB(";","o","x","%");
            DATAB("#","@", 0 , 0 );

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
