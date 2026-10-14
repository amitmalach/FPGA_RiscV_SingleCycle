# Pre-refactor baseline

Captured from the RTL as it stood before any refactor (ticket #3), so later tickets can
show that behavior, timing closure and resource use are unchanged.

## Simulation golden trace

`sim/golden/mandelbrot_bram.txt`, produced by `sim/run_regression.sh --update-golden`
with the committed mandelbrot firmware image in BRAM boot. See `sim/README.md`.

The RTL it was captured from is the snapshot commit "Record the working-tree RTL as the
pre-refactor baseline" plus two edits to the SoC top (`rtl/SOC.v`, formerly `step1.v`) that change no logic: `BOOT_ADDR`
became a module parameter (default unchanged) so the testbench can select BRAM boot,
and `wire eos` moved above its first use because xvlog rejects use-before-declaration.

| | |
|---|---|
| Stop reason | `stop_leds`: LED register became 1, the mandelbrot frame counter after the first full frame |
| Cycles simulated | 153 553 434 (0.768 s at 200 MHz; 232 s wall time in xsim) |
| UART bytes | 8368 (46 rows of 46 pixels, ANSI colour escapes) |
| LED changes | 1 (`LEDS 767767168 01`) |

## Synthesis and implementation

`vivado -mode batch -nojournal -nolog -source vivado/baseline.tcl`, Vivado 2025.2,
part `xc7k325tffg900-2`, constraints `Genesys-2-Master.xdc` (200 MHz `sys_clk_p`,
5.000 ns period). Reports in `build/baseline/` (not committed). Post-refactor numbers
are only comparable when produced by the same script; a project-mode run with different
synthesis settings will not match.

| | |
|---|---|
| Timing | met (0 failing endpoints of 1243 setup / 1243 hold) |
| WNS | 0.082 ns |
| WHS | 0.104 ns |
| Fmax (1 / (period - WNS)) | 203.3 MHz |
| Slice LUTs | 930 of 203800 (0.46 %) |
| Slice registers | 244 of 407600 (0.06 %) |
| Block RAM tiles | 2 of 445 (0.45 %) |
| DSPs | 0 |
| Bonded IOBs | 15 |

## Known pre-existing behavior captured in the golden trace

The golden frame is what the current RTL produces, not what the C source means. The
same `mandelbrot.c` compiled natively emits an 11 014-byte first frame; the SoC emits
8368 bytes, and the two diverge at row 8, pixel 36. A diagnostic firmware run in the
same harness shows why: `srai` behaves as `srli` (`-1544416 >> 9` yields
`0x007FF437`, expected `0xFFFFF437`), while software multiplication and the other
operations checked are correct. The cause is this ALU arm in `Processor.v`:

```verilog
3'b101: aluOut = funct7[5] ? ($signed(aluIn1) >>> shamt) : (aluIn1 >> shamt);
```

The unsigned else-arm makes the whole conditional expression unsigned, so `>>>` is
evaluated as a logical shift. Fixing it changes the UART stream, so it is deliberately
not fixed in the refactor tickets; it is tracked as issue #10 and the golden file
must be re-captured when it lands.
