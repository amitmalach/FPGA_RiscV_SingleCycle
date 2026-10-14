# Firmware build for the multi-cycle RV32I SoC.
#
#   make                              mandelbrot demo, BRAM boot -> canonical firmware.hex
#   make PROG=sieve                   another demo, BRAM boot
#   make PROG=ST_NICCC TARGET=flash   flash boot: build/<prog>.spiflash.{elf,bin,mcs}
#   make check                        rebuild from clean and compare against the committed image
#   make clean
#
# Demos: blinker sieve mandelbrot riscv_logo ST_NICCC (BRAM or flash)
#        tinyraytracer (flash only: ~29 KB of code, the RAM holds 6 KB)
# TARGET=bram writes HEX_OUT, the one firmware image the RTL reads.
# TARGET=flash never touches HEX_OUT; BRAM contents are irrelevant when booting from flash.

PROG   ?= mandelbrot
TARGET ?= bram
BUILD  ?= build

# The single firmware image. Memory.v reads it with $readmemh("firmware.hex")
# and the Vivado project lists this path in both the synthesis and simulation filesets.
HEX_OUT ?= ../Bruno_RISCV.srcs/sources_1/imports/FROM_BLINKER_TO_RISCV/firmware.hex

# Bytes of on-chip RAM and the flash code offset. The linker-side copies live
# in memory.ld; the RTL-side ones in Memory.v and step1.v.
RAM_SIZE          = 6144
FLASH_CODE_OFFSET = 0xD00000

DEMOS      = blinker sieve mandelbrot riscv_logo tinyraytracer ST_NICCC
FLASH_ONLY = tinyraytracer

# --- toolchain ----------------------------------------------------------------
CROSS   ?= riscv64-unknown-elf-
AS       = $(CROSS)as
CC       = $(CROSS)gcc
LD       = $(CROSS)ld
OBJCOPY  = $(CROSS)objcopy
HOSTCXX ?= g++
VIVADO  ?= vivado

ARCHFLAGS = -march=rv32i -mabi=ilp32
ASFLAGS   = $(ARCHFLAGS) -mno-relax
CFLAGS    = $(ARCHFLAGS) -O2 -fno-pic -fno-stack-protector -I.
# --no-warn-rwx-segments: a single RWX region is the intended layout here.
LDFLAGS   = -m elf32lriscv -nostdlib --no-relax --no-warn-rwx-segments
LIBGCC    = $(shell $(CC) $(ARCHFLAGS) -print-libgcc-file-name)

# The distro toolchain ships no C library. tinyraytracer needs <math.h> and
# libm; the rv32i/ilp32 newlib bundled with Vivado provides both and links
# cleanly against objects from riscv64-unknown-elf-gcc. Used only for
# tinyraytracer, so every other image builds without Vivado installed.
XILINX_RV32_ROOT ?= $(HOME)/Xilinx/2025.2/gnu/riscv/lin/riscv32-xilinx-elf/usr
MATH_INC = -I$(XILINX_RV32_ROOT)/include
MATH_LIB = -L$(XILINX_RV32_ROOT)/lib/rv32i/ilp32 -lm

# --- objects ------------------------------------------------------------------
LIBOBJS = $(addprefix $(BUILD)/,putchar.o wait.o print.o memcpy.o errno.o)

FW_WORDS     = $(BUILD)/firmware_words
FW_WORDS_SRC = tools/firmware_words_src/firmware_words.cpp tools/firmware_words_src/femto_elf.c

# Records which demo HEX_OUT currently holds, so `make PROG=x` after
# `make PROG=y` rebuilds the image even though both ELFs already exist.
IMAGE_DEMO_STAMP = $(BUILD)/image_demo

# Link: $(1) = linker script, $(2) = startup object. The demo object ($<)
# comes right after the startup code; libgcc (and libm when set) close the group.
link = $(LD) -T $(1) $(LDFLAGS) $(2) $< $(LIBOBJS) \
           --start-group $(LIBGCC) $(EXTRA_LIBS) --end-group -o $@

.PHONY: all bram flash check clean print-hex-path
.DELETE_ON_ERROR:
# Keep chained intermediates instead of deleting them after each build.
# Never use a bare `.SECONDARY:` here: it would also mark the ELFs as
# intermediate, and make then skips rebuilding a missing ELF whenever the
# hex is newer than the sources, turning `make` into a no-op.
.SECONDARY: $(LIBOBJS) $(BUILD)/start.o $(BUILD)/start_spiflash.o $(BUILD)/$(PROG).o \
            $(BUILD)/$(PROG).spiflash.elf

ifeq ($(TARGET),bram)
all: bram
else ifeq ($(TARGET),flash)
all: flash
endif

# Validate the selectors only when a build goal is requested. The flash-only
# check applies to the image goals (`all`/`bram`), not to explicit flash files.
GOALS = $(if $(MAKECMDGOALS),$(MAKECMDGOALS),all)
ifneq ($(filter-out clean print-hex-path,$(GOALS)),)
  ifeq ($(filter bram flash,$(TARGET)),)
    $(error TARGET must be bram or flash, got '$(TARGET)')
  endif
  ifeq ($(filter $(PROG),$(DEMOS)),)
    $(error PROG must be one of: $(DEMOS))
  endif
  ifneq ($(filter all bram,$(GOALS)),)
    ifeq ($(TARGET)/$(filter $(PROG),$(FLASH_ONLY)),bram/$(PROG))
      $(error $(PROG) does not fit in the $(RAM_SIZE)-byte RAM; build it with TARGET=flash)
    endif
  endif
  ifeq ($(PROG)/$(wildcard $(XILINX_RV32_ROOT)/lib/rv32i/ilp32/libm.a),tinyraytracer/)
    $(error tinyraytracer needs libm: no $(XILINX_RV32_ROOT)/lib/rv32i/ilp32/libm.a; set XILINX_RV32_ROOT to a Vivado RISC-V toolchain)
  endif
endif

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: %.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

# Only tinyraytracer uses <math.h> and libm.
$(BUILD)/tinyraytracer.o:            CFLAGS     += $(MATH_INC)
$(BUILD)/tinyraytracer.spiflash.elf: EXTRA_LIBS  = $(MATH_LIB)

$(FW_WORDS): $(FW_WORDS_SRC) tools/firmware_words_src/femto_elf.h | $(BUILD)
	$(HOSTCXX) -O2 -Itools/firmware_words_src -DSTANDALONE_FEMTOELF $(FW_WORDS_SRC) -o $@

ifneq ($(file <$(IMAGE_DEMO_STAMP)),$(PROG))
.PHONY: $(IMAGE_DEMO_STAMP)
endif
$(IMAGE_DEMO_STAMP): | $(BUILD)
	@echo $(PROG) > $@

# --- BRAM boot: start.S + program + support, everything in the 6 KB RAM --------
$(BUILD)/%.bram.elf: $(BUILD)/%.o $(BUILD)/start.o $(LIBOBJS) bram.ld memory.ld
	$(call link,bram.ld,$(BUILD)/start.o)

$(HEX_OUT): $(BUILD)/$(PROG).bram.elf $(FW_WORDS) $(IMAGE_DEMO_STAMP)
	$(FW_WORDS) $< -ram $(RAM_SIZE) -max_addr $(RAM_SIZE) -out $@

bram: $(HEX_OUT)

# --- flash boot: code in SPI flash, .data/.bss/fastcode copied to RAM at startup
$(BUILD)/%.spiflash.elf: $(BUILD)/%.o $(BUILD)/start_spiflash.o $(LIBOBJS) spiflash.ld memory.ld
	$(call link,spiflash.ld,$(BUILD)/start_spiflash.o)

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
