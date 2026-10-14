/* ===========================================================================
 * spiflash1.ld -- linker script for programs that EXECUTE FROM SPI FLASH
 * ===========================================================================
 * Tutorial step 24. Adapted from FemtoRV's spiflash1.ld, with the memory
 * map changed to match this project (see below -- the tutorial's addresses
 * do not transfer).
 *
 * The split:
 *   .text, .rodata  -> FLASH   (code and read-only constants; 3MB available)
 *   .bss,  .sbss    -> RAM     (uninitialised globals, zeroed by startup)
 *   .data, .sdata   -> RAM     but with their INITIAL VALUES stored in FLASH
 *
 * That last one is the interesting case. A global like `int x = 3;` needs
 * its initial value 3 stored somewhere non-volatile (flash), but the program
 * then writes to x, so at run time it must live in writable RAM. The `AT`
 * keyword expresses exactly this: the section's VMA (the address the code
 * uses to reach it) is in RAM, while its LMA (Load Memory Address, where the
 * initial bytes are actually stored) is in flash. Nothing copies them across
 * automatically -- start_spiflash1.S does that by hand at boot, using the
 * _sidata/_sdata/_edata symbols defined below.
 *
 * ---------------------------------------------------------------------------
 * MEMORY MAP -- derived for THIS board, not copied from the tutorial
 * ---------------------------------------------------------------------------
 * FLASH ORIGIN 0x01D00000 = SPIFLASH_BASE (0x01000000, i.e. address bit 24,
 * the isSPIFlash decode in step1.v) + 0x00D00000 (13MB into the physical
 * chip). That offset is forced by what already occupies the chip:
 *   0x000000..0xAE9E10  this design's FPGA bitstream (~10.91MB)
 *   0xC00000..0xC9C3E7  scene1.dat, the ST_NICCC polygon stream (640KB)
 *   0xD00000..0xFFFFFF  <- us: 3MB, 64KB-sector-aligned, clear of both
 * 0xFFFFFF is a hard ceiling: SPIFlash.v's 22-bit word_address reaches 16MB.
 *
 * The tutorial's ORIGIN (0x00820000 = base 1<<23 + 128KB) is wrong here twice
 * over: 1<<23 would give an 8MB flash window, smaller than our own bitstream,
 * and 128KB is sized for an IceStick bitstream of a few tens of KB.
 * =========================================================================== */

MEMORY {
    FLASH (rx)  : ORIGIN = 0x01D00000, LENGTH = 0x300000    /* 3 MB in flash */
    RAM   (rwx) : ORIGIN = 0x00000000, LENGTH = 0x1800      /* 6 kB in BRAM  */
}

SECTIONS {

    /* Initialised data: lives in RAM, initial values loaded from FLASH.
     * AT(_sidata) sets the LMA -- _sidata is defined at the end of .text
     * below, so the initial values sit immediately after the code in flash. */
    .data : AT ( _sidata ) {
        . = ALIGN(4);
        _sdata = .;        /* start of .data in RAM  -- read by start_spiflash1.S */

        *(.data*)
        *(.sdata*)

        . = ALIGN(4);
        _edata = .;        /* end of .data in RAM    -- read by start_spiflash1.S */
    } > RAM

    /* Code and read-only data: stays in flash, executed in place. */
    .text : {
        . = ALIGN(4);
        */start_spiflash1.o(.text)  /* MUST be first: the CPU's reset vector points
                                   * at the very start of this region, so the
                                   * startup code has to be the first thing there */

        /* Present in the tutorial's spiflash2.ld to avoid "overlapping
         * sections" errors with some programs; harmless and cheap to keep
         * here too. */
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.init_array)
        *(.gcc_except_table*)

        *(.text*)
        . = ALIGN(4);
        *(.rodata*)
        *(.srodata*)

        /* ALIGN(4) before _etext is NOT in the tutorial's version, and it
         * matters: _sidata is derived from _etext, and start_spiflash1.S
         * copies from _sidata with `lw`, a word load that requires a
         * 4-byte-aligned address. Without this, a .rodata section ending on
         * an odd byte would leave _sidata misaligned and the copy loop would
         * read the wrong words. */
        . = ALIGN(4);
        _etext = .;
        _sidata = _etext;  /* where .data's initial values are stored in flash */
    } >FLASH

    /* Uninitialised globals: RAM only, no stored bytes, zeroed at boot. */
    .bss : {
        . = ALIGN(4);
        _sbss = .;         /* start of .bss -- read by start_spiflash1.S */
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;         /* end of .bss   -- read by start_spiflash1.S */
    } >RAM
}
