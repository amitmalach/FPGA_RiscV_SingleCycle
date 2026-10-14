# Wrap a flat flash-boot binary into a Vivado .mcs image for the Genesys 2's
# 32 MB SPI flash (s25fl256s), placed at the code offset the SoC boots from.
#
# Usage (from the firmware Makefile):
#   vivado -mode batch -source write_mcs.tcl -tclargs <in.bin> <out.mcs> <offset>
#
# Program it with Hardware Manager -> Program Configuration Memory Device,
# address range "Configuration File Only", so the bitstream at 0x0 and the
# ST-NICCC scene data at 0xC00000 are left untouched.
lassign $argv bin mcs offset
write_cfgmem -force -format mcs -size 32 -interface SPIx1 \
    -loaddata "up $offset $bin" -file $mcs
