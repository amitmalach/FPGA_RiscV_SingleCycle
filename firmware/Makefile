# Firmware build for the multi-cycle RV32I SoC.
#
#   make                              mandelbrot demo, BRAM boot -> canonical firmware.hex
#   make PROG=sieve                   another demo, BRAM boot
#   make PROG=ST_NICCC TARGET=flash   flash boot: build/<prog>.spiflash.{elf,bin,mcs}
#   make check                        rebuild from clean and compare against the committed image
#   make clean
#
# Demos: blinker sieve mandelbrot riscv_logo tinyraytracer ST_NICCC
# TARGET=bram writes HEX_OUT, the one firmware image the RTL reads.
# TARGET=flash never touches HEX_OUT; BRAM contents are irrelevant when booting from flash.

PROG   ?= mandelbrot
TARGET ?= bram
# Flash linker script: spiflash1 (plain) or spiflash2 (fastcode in RAM).
LDS    ?= spiflash2
BUILD  ?= build

# The single firmware image. Memory.v reads it with $readmemh("firmware.hex")
# and the Vivado project lists this path in both the synthesis and simulation filesets.
HEX_OUT ?= ../Bruno_RISCV.srcs/sources_1/imports/FROM_BLINKER_TO_RISCV/firmware.hex

# Bytes of on-chip RAM (must match Memory.v) and the flash code offset
# (must match SPIFLASH_CODE_OFFSET in step1.v).
RAM_SIZE          = 6144
FLASH_CODE_OFFSET = 0xD00000

DEMOS = blinker sieve mandelbrot riscv_logo tinyraytracer ST_NICCC

# --- toolchain ----------------------------------------------------------------
CROSS   ?= riscv64-unknown-elf-
AS       = $(CROSS)as
CC       = $(CROSS)gcc
LD       = $(CROSS)ld
OBJCOPY  = $(CROSS)objcopy
VIVADO  ?= vivado

ARCHFLAGS = -march=rv32i -mabi=ilp32
ASFLAGS   = $(ARCHFLAGS) -mno-relax
CFLAGS    = $(ARCHFLAGS) -O2 -fno-pic -fno-stack-protector -w -I.
LDFLAGS   = -m elf32lriscv -nostdlib --no-relax
LIBGCC    = $(shell $(CC) $(ARCHFLAGS) -print-libgcc-file-name)

# The distro toolchain ships no C library. tinyraytracer needs <math.h> and
# libm; the rv32i/ilp32 newlib bundled with Vivado provides both and links
# cleanly against objects from riscv64-unknown-elf-gcc. Optional: used only
# when present, and -lm pulls nothing into demos that do not call libm.
XILINX_RV32_ROOT ?= $(HOME)/Xilinx/2025.2/gnu/riscv/lin/riscv32-xilinx-elf/usr
MATH_LIB_DIR      = $(XILINX_RV32_ROOT)/lib/rv32i/ilp32
ifneq ($(wildcard $(MATH_LIB_DIR)/libm.a),)
  MATH_INC = -I$(XILINX_RV32_ROOT)/include
  MATH_LIB = -L$(MATH_LIB_DIR) -lm
endif

# --- objects ------------------------------------------------------------------
LIBOBJS = $(addprefix $(BUILD)/,putchar.o wait.o print.o memcpy.o errno.o)

FW_WORDS     = $(BUILD)/firmware_words
FW_WORDS_SRC = tools/firmware_words_src/firmware_words.cpp tools/firmware_words_src/femto_elf.c

# Records which demo HEX_OUT currently holds, so `make PROG=x` after
# `make PROG=y` rebuilds the image even though both ELFs already exist.
PROG_STAMP = $(BUILD)/hex.prog

.PHONY: all bram flash check clean print-hex-path
.DELETE_ON_ERROR:
# Keep chained intermediates instead of deleting them after each build.
# Never use a bare `.SECONDARY:` here: it would also mark the ELFs as
# intermediate, and make then skips rebuilding a missing ELF whenever the
# hex is newer than the sources, turning `make` into a no-op.
.SECONDARY: $(LIBOBJS) $(BUILD)/start.o $(BUILD)/start_spiflash1.o $(BUILD)/$(PROG).o \
            $(BUILD)/$(PROG).spiflash.elf

ifeq ($(filter clean print-hex-path,$(MAKECMDGOALS)),)
  ifeq ($(TARGET),bram)
    all: bram
  else ifeq ($(TARGET),flash)
    all: flash
  else
    $(error TARGET must be bram or flash, got '$(TARGET)')
  endif
  ifeq ($(filter $(PROG),$(DEMOS)),)
    $(error PROG must be one of: $(DEMOS))
  endif
endif

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: %.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

# Only tinyraytracer includes <math.h>; keep newlib headers away from the rest.
$(BUILD)/tinyraytracer.o: CFLAGS += $(MATH_INC)

$(FW_WORDS): $(FW_WORDS_SRC) tools/firmware_words_src/femto_elf.h | $(BUILD)
	$(CXX) -O2 -Itools/firmware_words_src -DSTANDALONE_FEMTOELF $(FW_WORDS_SRC) -o $@

ifneq ($(file <$(PROG_STAMP)),$(PROG))
.PHONY: $(PROG_STAMP)
endif
$(PROG_STAMP): | $(BUILD)
	@echo $(PROG) > $@

# --- BRAM boot: start.S + program + support, everything in the 6 KB RAM --------
$(BUILD)/%.bram.elf: $(BUILD)/%.o $(BUILD)/start.o $(LIBOBJS) bram.ld
	$(LD) -T bram.ld $(LDFLAGS) $(BUILD)/start.o $< $(LIBOBJS) \
	    --start-group $(LIBGCC) $(MATH_LIB) --end-group -o $@

$(HEX_OUT): $(BUILD)/$(PROG).bram.elf $(FW_WORDS) $(PROG_STAMP)
	$(FW_WORDS) $< -ram $(RAM_SIZE) -max_addr $(RAM_SIZE) -out $@

bram: $(HEX_OUT)

# --- flash boot: code in SPI flash, .data/.bss/fastcode copied to RAM at startup
$(BUILD)/%.spiflash.elf: $(BUILD)/%.o $(BUILD)/start_spiflash1.o $(LIBOBJS) $(LDS).ld
	$(LD) -T $(LDS).ld $(LDFLAGS) $(BUILD)/start_spiflash1.o $< $(LIBOBJS) \
	    --start-group $(LIBGCC) $(MATH_LIB) --end-group -o $@

$(BUILD)/%.spiflash.bin: $(BUILD)/%.spiflash.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/%.spiflash.mcs: $(BUILD)/%.spiflash.bin tools/write_mcs.tcl
	$(VIVADO) -mode batch -nolog -nojournal -notrace -source tools/write_mcs.tcl \
	    -tclargs $(abspath $<) $(abspath $@) $(FLASH_CODE_OFFSET)

flash: $(BUILD)/$(PROG).spiflash.bin $(BUILD)/$(PROG).spiflash.mcs

# --- utilities ------------------------------------------------------------------
check:
	tests/check_reproducible.sh

print-hex-path:
	@echo $(abspath $(HEX_OUT))

clean:
	rm -rf $(BUILD)
