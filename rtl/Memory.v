`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// Memory -- program + data RAM
// -----------------------------------------------------------------------------
// Single-port synchronous RAM, shared by instruction fetch and Load/Store --
// there is no separate instruction memory; Processor.v just happens to
// request program words from here during FETCH_INSTR/WAIT_INSTR, and data
// words during LOAD/STORE, over the exact same bus.
//
// Reads and writes are NOT symmetric in timing:
//   - a read is registered: the word requested this cycle only appears on
//     mem_rdata the *next* cycle -- exactly why Processor.v has a dedicated
//     WAIT_INSTR/WAIT_DATA state after every read request.
//   - a write takes effect on the very same clock edge its address/data/mask
//     are presented. There is no answer to wait for, so Processor.v needs no
//     extra state after a STORE (see the note by STORE in Processor.v).
// -----------------------------------------------------------------------------


// =============================================================================
// HOW TO BUILD firmware.hex  --  compiling real C / assembly for this CPU
// =============================================================================
// The $readmemh("firmware.hex") call further down is the ONLY link between this
// hardware and the software it runs. Everything below explains how that file is
// produced, from nothing, using the real GNU RISC-V toolchain. Read this before
// touching the software side of the project.
//
// Historical note: earlier versions of this project generated program.hex with
// a VERILOG-based assembler (riscv_assembly.v + program_asm.v, run through
// iverilog). That still works and those files are still in the project, but the
// flow described here replaces it -- the machine code is identical, it just
// comes from standard tools instead, which is what makes it possible to compile
// C rather than hand-assemble everything.
//
//
// -----------------------------------------------------------------------------
// 0. THE BIG PICTURE -- four stages, four file types
// -----------------------------------------------------------------------------
//
//    foo.c  /  foo.S          your program (C source, or assembly source)
//         |
//         |   COMPILE (gcc)  or  ASSEMBLE (as)
//         v
//    foo.o                    "object file": machine code, but with no fixed
//                             addresses yet, and calls to other files unresolved
//         |
//         |   LINK (ld, guided by bram.ld)
//         v
//    foo.elf                  complete executable: every instruction now has a
//                             real address, every call resolved. Standard ELF
//                             format (same container Linux binaries use).
//         |
//         |   CONVERT (firmware_words)
//         v
//    firmware.hex             plain ASCII text, one 32-bit word per token --
//                             the only format $readmemh() understands
//         |
//         |   $readmemh()  (below in this file)
//         v
//    MEM[0:1535]              this module's Block RAM, pre-loaded at power-on
//
// A note on why the last conversion step exists at all: ld emits ELF, which is
// a structured binary container (headers, section tables, symbols). $readmemh()
// wants none of that -- just bare hex numbers as text. firmware_words bridges
// the two. It also handles endianness: RISC-V is little-endian, so a word's
// low-order byte sits at the low address, but $readmemh reads each token
// most-significant-digit-first like a human reads hex. firmware_words emits the
// four bytes of each word in reverse order so the value reassembles correctly.
// Get this wrong and every instruction fetched is byte-swapped garbage.
//
//
// -----------------------------------------------------------------------------
// 1. ONE-TIME SETUP  (only ever needs doing once per machine)
// -----------------------------------------------------------------------------
//
// 1a. Install the CROSS TOOLCHAIN.
//
//     WHAT "CROSS" MEANS. An ordinary compiler produces code for the machine it
//     is running on. Type "gcc hello.c" on this laptop and you get an x86-64
//     program that runs on this laptop. That is useless here, because the CPU we
//     are targeting is the RISC-V core in this very file -- a completely
//     different instruction set, sitting inside an FPGA, with no operating
//     system on it at all.
//
//     A CROSS compiler is one that RUNS on one architecture but PRODUCES code
//     for another. This one runs on x86-64 Linux and emits RISC-V machine code.
//     It cannot run what it builds; it only writes the bytes out to a file, and
//     those bytes are later loaded into MEM below.
//
//     That is also why every tool name is prefixed "riscv64-unknown-elf-":
//         riscv64  target architecture
//         unknown  target vendor (nobody in particular)
//         elf      target "OS" -- bare metal, output in ELF file format
//     The prefix is what keeps them distinct from the plain gcc/as/ld already on
//     this machine, which build for the PC. Both sets are used in this document
//     and they are NOT interchangeable:
//         riscv64-unknown-elf-gcc / -as / -ld   build code FOR the RISC-V core
//         g++ (plain, no prefix)                builds firmware_words FOR the PC
//
//     Despite the "riscv64" in the name, this toolchain builds 32-bit RV32I code
//     perfectly well -- that is what the -march=rv32i -mabi=ilp32 flags select.
//     There is no separate riscv32- package to look for.
//
//     COMMANDS TO RUN (Ubuntu/Debian Linux; copy-paste one line at a time):
//
//       sudo apt-get update
//       sudo apt-get install gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf
//
//     gcc-riscv64-unknown-elf      the C compiler, and its libgcc.a (see 5c)
//     binutils-riscv64-unknown-elf the assembler (as), linker (ld), and
//                                  inspection tools (objdump, objcopy, nm)
//
//     Then confirm all three tools are on the PATH and report a version:
//
//       riscv64-unknown-elf-gcc --version
//       riscv64-unknown-elf-as --version
//       riscv64-unknown-elf-ld --version
//
//     Expect GCC 13.x and binutils 2.4x on Ubuntu 24.04. If a command instead
//     prints "command not found", the install did not succeed -- re-run it and
//     read the apt output rather than continuing.
//
//     Do NOT use the tutorial's alternative ("make ICESTICK.firmware_config"),
//     which downloads a prebuilt toolchain tarball into Bruno Levy's repo. The
//     apt packages above are newer, get security updates, need no PATH edits,
//     and produce identical RV32I machine code -- the base integer instruction
//     encodings have not changed since the ISA was ratified.
//
// 1b. Build firmware_words, the ELF -> hex converter. It is a normal PC program
//     (hence plain g++, not the cross compiler), living in Bruno Levy's repo:
//
//       mkdir -p ~/vivado_projects/Bruno_RISCV/firmware/tools
//       g++ -I/home/amit/BrunoLevy_learnFPGA_repo/FemtoRV/FIRMWARE/LIBFEMTORV32 \
//           -DSTANDALONE_FEMTOELF \
//           /home/amit/BrunoLevy_learnFPGA_repo/FemtoRV/FIRMWARE/TOOLS/FIRMWARE_WORDS_SRC/firmware_words.cpp \
//           /home/amit/BrunoLevy_learnFPGA_repo/FemtoRV/FIRMWARE/LIBFEMTORV32/femto_elf.c \
//           -o ~/vivado_projects/Bruno_RISCV/firmware/tools/firmware_words
//
//       -I<dir>                 where to find femto_elf.h, which the .cpp includes
//       -DSTANDALONE_FEMTOELF   femto_elf.c is dual-purpose: normally it is
//                               compiled INTO RISC-V firmware (where it blinks
//                               LEDs for progress and has no host OS). This
//                               define switches it to plain desktop mode --
//                               ordinary stdio file reading, LEDS() becomes a
//                               no-op. Without it, it will not build here.
//
//     Sanity check: run it with no arguments; it should print its usage text.
//
// 1c. Create the working directory and the linker script (see section 3):
//
//       ~/vivado_projects/Bruno_RISCV/firmware/          <- sources live here
//       ~/vivado_projects/Bruno_RISCV/firmware/tools/    <- firmware_words
//
//
// -----------------------------------------------------------------------------
// 2. THE FLAGS, ONCE -- every command below reuses these
// -----------------------------------------------------------------------------
//
//   -march=rv32i     Generate ONLY base 32-bit integer instructions. This is
//                    the exact instruction set Processor.v implements. Leave it
//                    off and the compiler will happily emit MUL/DIV (rv32im) or
//                    compressed 16-bit instructions (rv32ic) that this CPU
//                    cannot decode -- it would fetch them and behave randomly,
//                    with no error message anywhere.
//
//   -mabi=ilp32      Calling convention: which registers carry arguments and
//                    return values, how the stack is managed. Must match what
//                    start.S and the hand-written .S routines assume. ("ilp32"
//                    = int/long/pointer are all 32 bits, no hardware floats.)
//
//   -mno-relax       (assembler/compiler) and
//   --no-relax       (linker -- note the DOUBLE dash, see the gotcha in sec. 6)
//                    Disable "linker relaxation". Relaxation is an optimization
//                    where the linker rewrites far calls into shorter gp-relative
//                    ones. That would clobber gp -- and in this design gp is
//                    permanently reserved as the memory-mapped IO base pointer
//                    (0x400000, loaded once by start.S). Relaxation must stay off.
//
//   -nostdlib        (linker) Do not pull in the host C runtime or standard
//                    library. There is no operating system here; start.S is the
//                    entry point and 6KB of RAM cannot hold a real libc anyway.
//
//   -m elf32lriscv   (linker) Output format: 32-bit little-endian RISC-V.
//
//   -T bram.ld       (linker) Use our memory layout script -- see section 3.
//
//   For C compilation only:
//   -O2              Optimize. Worth having: unoptimized RV32I code is bulky,
//                    and 6KB fills up fast.
//   -fno-pic         No position-independent code. The program is linked to run
//                    at a fixed address (0), so PIC's indirection is pure waste.
//   -fno-stack-protector  No stack-guard instrumentation -- it would call into
//                    libc support functions that do not exist here.
//   -w               Silence warnings (the tutorial's example C files are old
//                    and noisy under modern gcc; the code itself is fine).
//
//
// -----------------------------------------------------------------------------
// 3. bram.ld -- the linker script (WHERE code and data land in RAM)
// -----------------------------------------------------------------------------
// The linker needs to be told what memory this machine has. Keep this file at
// ~/vivado_projects/Bruno_RISCV/firmware/bram.ld :
//
//     MEMORY
//     {
//        BRAM (RWX) : ORIGIN = 0x0000, LENGTH = 0x1800  /* 6kB RAM */
//     }
//     SECTIONS
//     {
//         /DISCARD/ : { *(.riscv.attributes) *(.comment) }
//         everything :
//         {
//     	. = ALIGN(4);
//     	start.o (.text)
//             *(.*)
//         } >BRAM
//     }
//
// Line by line:
//   ORIGIN = 0x0000     Processor.v resets PC to 0, so code must start at 0.
//   LENGTH = 0x1800     6144 bytes = exactly MEM[0:1535] below. If these two
//                       ever disagree, the linker will happily produce a program
//                       that overruns this RAM, and firmware_words will refuse
//                       it (see its "Memory exceeded!" check).
//   start.o (.text)     Force start.o's code to be placed FIRST, so that
//                       address 0 -- where the CPU begins executing -- is
//                       start.S's entry point and not some random function.
//                       Note this also pulls start.o into the link automatically:
//                       it does NOT need to be listed on the ld command line.
//   *(.*)               Then everything else from every other object file.
//
//   /DISCARD/ ...       IMPORTANT, and NOT in the tutorial's original version.
//                       Modern binutils (2.42, what is installed here) auto-adds
//                       a .riscv.attributes metadata section to every object
//                       file; the tutorial was written against a ~2019 toolchain
//                       that did not. Because *(.*) means "take EVERY section",
//                       that metadata gets laid down in RAM *interleaved between
//                       your functions*, where the CPU may run straight into it
//                       and execute ASCII text as instructions. /DISCARD/ throws
//                       it away before *(.*) can see it. (.comment is another
//                       such auto-added section, discarded defensively.)
//                       Symptom if omitted: firmware_words reports roughly
//                       double the expected code size, and objdump -D shows
//                       stretches of nonsense like ".insn 2, 0x1941" between
//                       real functions.
//
//
// -----------------------------------------------------------------------------
// 4. BUILDING AN ASSEMBLY-ONLY PROGRAM  (tutorial step 20, e.g. blinker.S)
// -----------------------------------------------------------------------------
// Source files, copied from the tutorial's FIRMWARE/ directory into
// ~/vivado_projects/Bruno_RISCV/firmware/ :
//
//   start.S    entry point at address 0: sets gp = 0x400000 (the IO base) and
//              sp = 0x1800 (top of RAM, stack grows down), calls main, then
//              EBREAK. EVERY program needs this linked in.
//   blinker.S  the program itself (main): writes 5, then 10, to the LEDS
//              register, with a delay between, forever.
//   wait.S     software delay loop, called by blinker.S.
//
//   cd ~/vivado_projects/Bruno_RISCV/firmware
//   riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 -mno-relax start.S   -o start.o
//   riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 -mno-relax blinker.S -o blinker.o
//   riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 -mno-relax wait.S    -o wait.o
//
//   riscv64-unknown-elf-ld blinker.o wait.o -o blinker.elf \
//        -T bram.ld -m elf32lriscv -nostdlib --no-relax
//
//   ./tools/firmware_words blinker.elf -ram 6144 -max_addr 6144 -out firmware.hex
//
// firmware_words arguments:
//   -ram 6144        size of this machine's RAM in BYTES; must match MEM below.
//   -max_addr 6144   refuse to emit anything reaching past this address. Useful
//                    as a guard: set it lower than -ram to reserve headroom for
//                    the stack, since the stack grows DOWN from 0x1800 into the
//                    same 6KB and silently overwriting your own code is a
//                    miserable bug to chase.
//   -out <file>      output filename; the .hex extension selects hex output
//                    (the same tool can also emit raw .bin).
//
// Expected output for blinker: "Code size: 20 words ... Occupancy: 1%".
// (If it says 40 words, /DISCARD/ is missing from bram.ld -- see section 3.)
//
//
// -----------------------------------------------------------------------------
// 5. BUILDING A C PROGRAM  (tutorial step 21, e.g. sieve.c)
// -----------------------------------------------------------------------------
// Extra files needed beyond start.S/wait.S, again from the tutorial's FIRMWARE/:
//
//   sieve.c     the program (Sieve of Eratosthenes; exercises multiply, divide
//               and modulo, none of which exist in RV32I hardware -- see libgcc
//               below -- and prints its results over UART).
//   print.c     a tiny printf/puts/print_dec/print_hex implementation. Real
//               libc printf supports so many formats that it will not fit in
//               6KB, so this minimal stand-in is used instead.
//   putchar.S   the bottom of the output stack: writes one byte to the UART
//               data register, then polls the UART status register until the
//               transmitter reports "not busy". Its .equ constants
//               (IO_BASE 0x400000, IO_UART_DAT 8, IO_UART_CNTL 16) must agree
//               with the memory map in step1.v -- they do.
//   memcpy.c    gcc emits calls to memcpy() on its own for struct/array copies,
//               even if the source never calls it. Link it in or risk an
//               "undefined reference".
//   errno.c     dummy __errno, for the same reason.
//
// 5a. THE MISSING HEADER, and how to fix it.
//
//     THE PROBLEM. sieve.c starts with #include <stdio.h>, but the Debian
//     gcc-riscv64-unknown-elf package ships NO C library headers at all -- its
//     include path holds only gcc's own headers. Compiling as-is fails with:
//         sieve.c:12:10: fatal error: stdio.h: No such file or directory
//
//     WHY NOT JUST INSTALL A C LIBRARY. The obvious move is
//     "sudo apt-get install picolibc-riscv64-unknown-elf". Do not bother:
//     it is a ~158MB download, its headers install to
//     /usr/lib/picolibc/riscv64-unknown-elf/include/ which is NOT on gcc's
//     default search path (so the error would persist unchanged), and its
//     printf is precisely the bloated thing that will not fit in 6KB of RAM.
//     Avoiding it is the entire reason print.c exists.
//
//     THE FIX. All the compiler actually needs is a DECLARATION -- the shape of
//     printf(), so it can typecheck the calls. The real code is supplied later,
//     at link time, by print.c. So write a two-line stub header of our own.
//
//     COMMANDS TO RUN (copy-paste the whole block at once -- it is one command;
//     the shell keeps reading lines until it sees the closing EOF):
//
//       cd ~/vivado_projects/Bruno_RISCV/firmware
//       cat > stdio.h << 'EOF'
//       #pragma once
//       int printf(const char *fmt, ...);
//       EOF
//
//     What that does: "cat > stdio.h" means "write what follows into a new file
//     called stdio.h", and "<< 'EOF'" (a here-document) feeds it every following
//     line until a line containing exactly EOF. The quotes around 'EOF' stop the
//     shell from trying to interpret anything in between. Net effect: a file
//     named stdio.h containing exactly those two lines.
//
//     Verify it landed correctly:
//
//       cat ~/vivado_projects/Bruno_RISCV/firmware/stdio.h
//
//     Expected output, exactly:
//         #pragma once
//         int printf(const char *fmt, ...);
//
//     (If you would rather not use a here-document, just open a text editor and
//     save those two lines as ~/vivado_projects/Bruno_RISCV/firmware/stdio.h --
//     the result is identical.)
//
//     HOW IT GETS FOUND. Adding -I. to the compile command means "also search
//     the current directory for headers". Since you compile from inside
//     ~/vivado_projects/Bruno_RISCV/firmware, #include <stdio.h> then resolves
//     to this stub. This does NOT affect the real hardware in any way -- it only
//     silences a compile-time lookup. The actual printf machinery comes from
//     print.c, which in turn calls putchar.S, which writes to the UART.
//
//     If a future C program includes other headers (<stdint.h>, <stddef.h>,
//     <stdarg.h>), note those three DO ship with gcc itself and need no stub --
//     only C-library headers like <stdio.h> or <string.h> are missing. For those,
//     extend this same stdio.h approach: declare only what the program calls, and
//     make sure something in the link actually implements it.
//
// 5b. Compile and link:
//
//   cd ~/vivado_projects/Bruno_RISCV/firmware
//   riscv64-unknown-elf-gcc -c sieve.c  -o sieve.o  -I. \
//        -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//   riscv64-unknown-elf-gcc -c print.c  -o print.o  -I. \
//        -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//   riscv64-unknown-elf-gcc -c memcpy.c -o memcpy.o \
//        -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//   riscv64-unknown-elf-gcc -c errno.c  -o errno.o \
//        -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//   riscv64-unknown-elf-as putchar.S -o putchar.o -march=rv32i -mabi=ilp32 -mno-relax
//
//   LIBGCC=$(riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -print-libgcc-file-name)
//   riscv64-unknown-elf-ld sieve.o wait.o print.o memcpy.o errno.o putchar.o \
//        -o sieve.elf -T bram.ld -m elf32lriscv -nostdlib --no-relax "$LIBGCC"
//
//   ./tools/firmware_words sieve.elf -ram 6144 -max_addr 6144 -out firmware.hex
//
// 5c. WHY libgcc.a IS REQUIRED. Processor.v implements RV32I only -- there is
//     no multiply, divide or modulo instruction in the hardware. When C code
//     writes "a * b" or "j % 2", gcc cannot emit a MUL, so it emits a CALL to a
//     software routine (__mulsi3, __divsi3, __umodsi3 ...). Those routines live
//     in libgcc.a, which ships with the compiler. Omit it and the link fails
//     with "undefined reference to `__mulsi3'".
//
//     Ask gcc where the right copy is rather than hardcoding a path:
//     -print-libgcc-file-name returns the variant matching -march/-mabi, e.g.
//     /usr/lib/gcc/riscv64-unknown-elf/13.2.0/rv32i/ilp32/libgcc.a . A hardcoded
//     path breaks on the next toolchain update; this does not. Note it must come
//     LAST on the ld command line -- ld resolves symbols left to right, so a
//     library must appear after everything that references it.
//
//     (This is the same job mulsi3_ did by hand in the old program_asm.v
//     Mandelbrot program -- now the compiler arranges it automatically.)
//
// 5d. DO NOT LINK perf.S. The tutorial lists it among its library objects, but
//     it provides rdcycle()/rdinstret(), which read RISC-V CSR performance
//     counters. This core has no CSRs -- Processor.v's SYSTEM handling covers
//     EBREAK and nothing else. Any program that actually calls them will
//     misbehave. sieve.c does not, so simply leave perf.S out of the link.
//
// Expected output for sieve: "Code size: 724 words ... Occupancy: 47%".
//
//
// -----------------------------------------------------------------------------
// 6. LOADING IT INTO THE HARDWARE (Vivado)
// -----------------------------------------------------------------------------
// $readmemh() below resolves "firmware.hex" as a bare filename, so the file has
// to be somewhere the tool doing the reading will look. Vivado handles that by
// copying every file registered in the project into the simulation/synthesis
// working directory -- which means the file must be TRACKED in the project, not
// merely present on disk.
//
//   6a. Copy the freshly built hex next to the Verilog sources:
//
//         cp ~/vivado_projects/Bruno_RISCV/firmware/firmware.hex \
//            ~/vivado_projects/Bruno_RISCV/Bruno_RISCV.srcs/sources_1/imports/FROM_BLINKER_TO_RISCV/
//
//   6b. FIRST TIME ONLY: add it to the project. Sources panel -> "+" ->
//       "Add or Create Design Sources" -> Add Files -> pick the copy from 6a
//       (the one beside step1.v, NOT the one in firmware/ -- otherwise Vivado
//       imports it into a separate imports/firmware/ subfolder and the paths
//       diverge confusingly). Repeat via "Add or Create Simulation Sources" so
//       both sources_1 and sim_1 filesets have it, exactly as program.hex does.
//       Vivado may file it under "Unknown" rather than "Memory File" in the
//       hierarchy view; that label is cosmetic and does not affect the copy.
//
//       On later rebuilds only 6a is needed -- same path, new contents.
//
//   6c. Simulation: right-click sim_1 -> "Reset Behavioral Simulation" (a plain
//       re-run may reuse the old working directory and thus the old hex), then
//       run it. If the file was not found, xsim does NOT stop with an error --
//       it prints a WARNING in simulate.log ("File firmware.hex ... cannot be
//       opened for reading"), leaves MEM full of X, and the CPU sits doing
//       nothing while LEDS stay at their reset value of 0. If a program appears
//       to do nothing at all, check simulate.log for that warning FIRST.
//
//   6d. Hardware: re-run synthesis -> implementation -> generate bitstream ->
//       program device. The hex contents are baked into the Block RAM
//       initialization at synthesis time, so changing firmware.hex requires a
//       full rebuild, not just re-programming.
//
//
// -----------------------------------------------------------------------------
// 7. PRACTICAL NOTES LEARNED THE HARD WAY
// -----------------------------------------------------------------------------
//
//   * ld's flag is --no-relax, with TWO dashes. The tutorial's README shows
//     "-norelax", which binutils 2.42 rejects outright:
//     "unable to disambiguate: -norelax (did you mean --norelax ?)".
//     The assembler's spelling is different again: -mno-relax.
//
//   * "warning: <file> has a LOAD segment with RWX permissions" from ld is
//     expected and harmless. It is a security warning about memory that is
//     simultaneously writable and executable -- which is exactly what a single
//     unified bare-metal BRAM is. There is no OS here to enforce W^X.
//
//   * Delay loops are tuned for far slower boards. wait.S uses 2^17 iterations,
//     which on this 200MHz core is about 5.24ms -- so blinker.S alternates its
//     two LED patterns at roughly 190Hz. That is far above the eye's flicker
//     fusion threshold, so LEDS[3:0] simply look CONTINUOUSLY LIT (each of those
//     four bits is set in exactly one of 0x05/0x0A) rather than blinking.
//     Nothing is broken; change the shift in wait.S from 17 to 23 (a 64x longer
//     delay, ~335ms) to actually see it blink.
//
//   * Simulation runtimes must be generous. A single wait() call is ~5.24ms of
//     simulated time, and UART output runs at 115200 baud = ~87us PER CHARACTER,
//     so sieve.c's full prime list takes tens of milliseconds. Vivado's default
//     run time is far too short; use "run 70ms" in the Tcl console. In
//     bench_iverilog.v the equivalent knob is the #<time> before $finish.
//
//   * To watch UART output in simulation, read the "UART PIN byte:" lines
//     printed by bench_iverilog.v's serial decoder -- it samples the actual
//     uart_rx_out pin like a real receiver. Do NOT trust step1.v's
//     "UART TX char:" lines for anything pin-related: they print what the CPU
//     handed to the UART, not what left the chip, and were blind to the
//     TX/RX pin-direction bug that once stopped all output reaching the PC.
//
//   * On real hardware, UART output appears on /dev/ttyUSB0 via the board's
//     separate "USB UART" connector (J15, an FT232R), NOT the JTAG connector:
//         gtkterm --port /dev/ttyUSB0 --speed 115200
//
//   * Watch the occupancy figure firmware_words prints. This RAM is only 6KB
//     and the stack grows down into the very same space from 0x1800. A program
//     that nearly fills RAM will have its code silently overwritten by its own
//     stack, and the CPU will wander off into garbage.
//
//
// =============================================================================
// 8. CHEAT SHEET -- running a new C program, commands only
// =============================================================================
// Everything above explains WHY. This section is just WHAT TO TYPE. Sections
// 1-3 (installing the toolchain, building firmware_words, writing bram.ld and
// stdio.h) are one-time setup and are assumed done already.
//
// Below, the example program is called myprog.c -- change the PROG= line to
// your own filename (WITHOUT the .c extension) and everything else follows.
//
//
// ---- PHASE 0: put your C file in the firmware directory ---------------------
//
//   cd ~/vivado_projects/Bruno_RISCV/firmware
//   #  ... place myprog.c here (write it, or copy it in) ...
//   #  It must define:  int main(void)
//
//
// ---- PHASE 1: set the program name (every later command reuses this) --------
//
//   cd ~/vivado_projects/Bruno_RISCV/firmware
//   PROG=myprog
//
//   NOTE: this shell variable lasts only for the current terminal window. If you
//   open a new terminal, re-run both lines above before continuing.
//
//
// ---- PHASE 2: build the support objects (ONCE -- skip if *.o already exist) --
//
//   riscv64-unknown-elf-as start.S   -o start.o   -march=rv32i -mabi=ilp32 -mno-relax
//   riscv64-unknown-elf-as wait.S    -o wait.o    -march=rv32i -mabi=ilp32 -mno-relax
//   riscv64-unknown-elf-as putchar.S -o putchar.o -march=rv32i -mabi=ilp32 -mno-relax
//   riscv64-unknown-elf-gcc -c print.c  -o print.o  -I. -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//   riscv64-unknown-elf-gcc -c memcpy.c -o memcpy.o     -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//   riscv64-unknown-elf-gcc -c errno.c  -o errno.o      -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//
//
// ---- PHASE 3: compile your program ------------------------------------------
//
//   riscv64-unknown-elf-gcc -c $PROG.c -o $PROG.o -I. -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//
//
// ---- PHASE 4: link everything into one executable ---------------------------
//
//   LIBGCC=$(riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -print-libgcc-file-name)
//   riscv64-unknown-elf-ld $PROG.o wait.o print.o memcpy.o errno.o putchar.o -o $PROG.elf -T bram.ld -m elf32lriscv -nostdlib --no-relax "$LIBGCC"
//
//   (One warning is normal and harmless:
//    "warning: <file> has a LOAD segment with RWX permissions")
//
//
// ---- PHASE 5: convert the executable into firmware.hex ----------------------
//
//   ./tools/firmware_words $PROG.elf -ram 6144 -max_addr 6144 -out firmware.hex
//
//   CHECK THE OUTPUT: "Occupancy: NN%" must be comfortably below 100%.
//   If it says "Memory exceeded!", the program is too big for this 6KB RAM.
//
//
// ---- PHASE 6: copy it where Vivado reads it ---------------------------------
//
//   cp firmware.hex ~/vivado_projects/Bruno_RISCV/Bruno_RISCV.srcs/sources_1/imports/FROM_BLINKER_TO_RISCV/firmware.hex
//
//
// ---- PHASE 7: run it (in Vivado -- GUI, nothing to paste) -------------------
//
//   SIMULATION:
//     1. right-click sim_1 -> "Reset Behavioral Simulation"
//     2. Run Behavioral Simulation
//     3. in the Tcl console:   run 70ms
//     4. read the "UART PIN byte:" lines in the Tcl console for UART output
//
//   REAL HARDWARE:
//     1. Run Synthesis -> Run Implementation -> Generate Bitstream
//     2. Open Hardware Manager -> Open Target -> Program Device
//     3. in a terminal:   gtkterm --port /dev/ttyUSB0 --speed 115200
//
//
// ---- EVERYTHING IN PHASES 1,3,4,5,6 AS ONE PASTE ----------------------------
// (after Phase 2 has been done once; change myprog to your program name)
//
//   cd ~/vivado_projects/Bruno_RISCV/firmware
//   PROG=myprog
//   riscv64-unknown-elf-gcc -c $PROG.c -o $PROG.o -I. -march=rv32i -mabi=ilp32 -O2 -fno-pic -fno-stack-protector -w
//   LIBGCC=$(riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -print-libgcc-file-name)
//   riscv64-unknown-elf-ld $PROG.o wait.o print.o memcpy.o errno.o putchar.o -o $PROG.elf -T bram.ld -m elf32lriscv -nostdlib --no-relax "$LIBGCC"
//   ./tools/firmware_words $PROG.elf -ram 6144 -max_addr 6144 -out firmware.hex
//   cp firmware.hex ~/vivado_projects/Bruno_RISCV/Bruno_RISCV.srcs/sources_1/imports/FROM_BLINKER_TO_RISCV/firmware.hex
//
//
// ---- FOR AN ASSEMBLY-ONLY PROGRAM (e.g. blinker.S) --------------------------
// Same idea, but assemble instead of compile, and no C support objects needed:
//
//   cd ~/vivado_projects/Bruno_RISCV/firmware
//   PROG=blinker
//   riscv64-unknown-elf-as $PROG.S -o $PROG.o -march=rv32i -mabi=ilp32 -mno-relax
//   riscv64-unknown-elf-ld $PROG.o wait.o -o $PROG.elf -T bram.ld -m elf32lriscv -nostdlib --no-relax
//   ./tools/firmware_words $PROG.elf -ram 6144 -max_addr 6144 -out firmware.hex
//   cp firmware.hex ~/vivado_projects/Bruno_RISCV/Bruno_RISCV.srcs/sources_1/imports/FROM_BLINKER_TO_RISCV/firmware.hex
// =============================================================================
module Memory (
    input  wire        clk,
    input  wire        clk_enable,

    input  wire [31:0] mem_addr,               // address to read or write (word-aligned access only)
    output reg  [31:0] mem_rdata,              // word read back, one cycle after mem_rstrb was high
    input  wire        mem_rstrb,               // read strobe: high for one cycle to request a read

    input  wire [31:0] mem_wdata,  // word to write (mem_wmask below picks which bytes actually land)
    input  wire [3:0]  mem_wmask   // per-byte write enable; all zero = no write
);

    // 1536 words x 4 bytes/word = 6144 bytes = 6KB of RAM, mapped by Vivado
    // onto the FPGA's Block RAM tiles.
    reg [31:0] MEM [0:1535];

    initial begin
        // Load the assembled program (and its initial data) from a plain
        // hex text file, one 32-bit word per line. This runs once, setting
        // the RAM's starting contents for both simulation and synthesis
        // (Vivado turns it into the Block RAM's init values).
        //
        // firmware.hex is produced by the GNU RISC-V toolchain, NOT by hand and
        // not by this project's older VERILOG assembler -- see the full
        // "HOW TO BUILD firmware.hex" section at the top of this file for the
        // complete compile/link/convert recipe, the flags each step needs, and
        // how to register the file with Vivado so it is actually found here.
        //
        // Note the bare filename: it is resolved relative to whatever directory
        // the simulator or synthesizer runs in, not relative to this .v file.
        // If it cannot be found, $readmemh does NOT fail loudly -- MEM is simply
        // left as X and the CPU executes nothing.
        $readmemh("firmware.hex", MEM);

    end

    // mem_addr[31:2] is the word index (the 2 dropped LSBs would select a
    // byte within a word -- irrelevant here, since a read always returns
    // the whole word and a write is masked per byte, not re-addressed).
    //
    // Read is registered (synchronous): like all Block RAM, one clock cycle
    // passes between mem_rstrb going high and the requested word appearing
    // on mem_rdata. Processor.v accounts for this with a dedicated WAIT_*
    // state after every memory request.
    always @(posedge clk) begin
        if(clk_enable) begin
            if (mem_rstrb) begin
                mem_rdata <= MEM[mem_addr[31:2]];
            end
            // Each mem_wmask bit independently enables writing its matching
            // byte of mem_wdata -- this is what lets SB/SH modify a single
            // byte/halfword of a word without touching the other bytes.
            if (mem_wmask[0]) MEM[mem_addr[31:2]][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wmask[1]) MEM[mem_addr[31:2]][15: 8] <= mem_wdata[15: 8];
            if (mem_wmask[2]) MEM[mem_addr[31:2]][23:16] <= mem_wdata[23:16];
            if (mem_wmask[3]) MEM[mem_addr[31:2]][31:24] <= mem_wdata[31:24];

        end
    end

endmodule
