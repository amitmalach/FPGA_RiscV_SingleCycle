/* ===========================================================================
 * spiflash.ld -- flash boot: code executes in place from SPI flash
 * ===========================================================================
 * Tutorial step 24 (FemtoRV's spiflash2.ld), with this board's memory map
 * (see memory.ld).
 *
 * The split:
 *   .text, .rodata  -> FLASH   (code and read-only constants; 3MB available)
 *   .bss,  .sbss    -> RAM     (uninitialised globals, zeroed by startup)
 *   .data, .sdata   -> RAM     but with their INITIAL VALUES stored in FLASH
 *   fastcode        -> RAM     selected hot functions, copied like .data
 *
 * .data is the interesting case. A global like `int x = 3;` needs its initial
 * value stored somewhere non-volatile (flash), but the program then writes to
 * x, so at run time it must live in writable RAM. The `AT` keyword expresses
 * exactly this: the section's VMA (the address the code uses to reach it) is
 * in RAM, while its LMA (Load Memory Address, where the initial bytes are
 * actually stored) is in flash. Nothing copies them across automatically --
 * start_spiflash.S does that by hand at boot, using the _sidata/_sdata/_edata
 * symbols defined below.
 *
 * FASTCODE. Flash is a *serial* memory. Every 32-bit read costs a full SPI
 * transaction -- 8 command bits + 24 address bits + 32 data bits = 64 SPI
 * clock periods at ~33.3MHz, roughly 1.9us. BRAM answers in a single 5ns
 * cycle. So executing from flash is on the order of a few hundred times
 * slower per instruction fetch. For most code that is fine; for the handful
 * of routines called in the innermost loops it is not. The trick is that the
 * .data copy loop already moves bytes from flash into RAM at boot, so putting
 * a function's *code* into that same section gets it copied to RAM for free.
 * The linker resolves calls to the RAM address, and the startup copy puts
 * real instructions there before main() runs.
 *
 * WHAT GOES IN:
 *   - integer multiply/divide from libgcc. This core is plain RV32I with no
 *     hardware MUL/DIV, so every C `*`, `/` and `%` becomes a call into
 *     these -- verified present in this toolchain's rv32i/ilp32 libgcc.a as
 *     muldi3.o (which supplies __mulsi3) and div.o (__divsi3/__udivsi3/
 *     __modsi3).
 *   - putchar.o / print.o: every character of UART output goes through them.
 *   - anything the programmer marks __attribute((section(".fastcode"))).
 *
 * BUDGET WARNING: everything listed here consumes the same 6KB BRAM that
 * also holds .data, .bss and the stack. Adding too much will silently push
 * the stack into your own code. firmware_words reports the occupancy --
 * watch it, and keep headroom for the stack (ST_NICCC.c alone peaks around
 * 576 bytes of stack).
 * =========================================================================== */

INCLUDE memory.ld

SECTIONS {

    /* Initialised data AND fastcode: both live in RAM, both have their
     * initial contents stored in FLASH at _sidata, both are copied across
     * by the single loop in start_spiflash.S. */
    .data_and_fastcode : AT ( _sidata ) {
        . = ALIGN(4);
        _sdata = .;        /* start of the copied region -- read by start_spiflash.S */

        /* Initialised data */
        *(.data*)
        *(.sdata*)

        /* Integer multiply and divide (no hardware MUL/DIV on RV32I) */
        */libgcc.a:muldi3.o(.text)
        */libgcc.a:div.o(.text)

        /* UART output path -- called once per character */
        */putchar.o(.text)
        */print.o(.text)

        /* User functions marked __attribute((section(".fastcode"))) */
        *(.fastcode*)

        . = ALIGN(4);
        _edata = .;        /* end of the copied region -- read by start_spiflash.S */
    } > RAM

    /* Everything else: stays in flash, executed in place. */
    .text : {
        . = ALIGN(4);
        */start_spiflash.o(.text)  /* MUST be first: the CPU's reset vector points here */

        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.init_array)
        *(.gcc_except_table*)

        *(.text*)
        . = ALIGN(4);
        *(.rodata*)
        *(.srodata*)

        /* This ALIGN(4) is an addition to the tutorial's version and is
         * required, because _sidata is copied from with word loads. */
        . = ALIGN(4);
        _etext = .;
        _sidata = _etext;
    } >FLASH

    /* Uninitialised globals: RAM only, zeroed at boot. */
    .bss : {
        . = ALIGN(4);
        _sbss = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } >RAM
}
