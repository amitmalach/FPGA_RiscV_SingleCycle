MEMORY
{
   BRAM (RWX) : ORIGIN = 0x0000, LENGTH = 0x1800  /* 6kB RAM */
}
SECTIONS
{
    /DISCARD/ : { *(.riscv.attributes) *(.comment) }
    everything :
    {
	. = ALIGN(4);
	*/start.o (.text)
        *(.*)
    } >BRAM
}
