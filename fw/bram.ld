/* bram.ld -- BRAM boot: the whole program lives in the 6 KB on-chip RAM.
 * start.o is pinned first because the reset vector is address 0. */

INCLUDE memory.ld

SECTIONS
{
    /DISCARD/ : { *(.riscv.attributes) *(.comment) }
    everything :
    {
        . = ALIGN(4);
        */start.o (.text)
        *(.*)
    } >RAM
}
