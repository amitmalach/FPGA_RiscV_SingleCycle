# Simulation regression

One script tells you whether the SoC still behaves exactly like the design it was
captured from. It simulates the `SOC` top in xsim with the committed firmware image
(mandelbrot, BRAM boot), records what an outside observer sees, and diffs that trace
against a committed golden file.

```sh
source <vivado-install>/2025.2/Vivado/settings64.sh   # xvlog/xelab/xsim on PATH
sim/run_regression.sh                              # PASS / FAIL, exit 0 / 1
```

A full run simulates one mandelbrot frame, about 154 M clock cycles (0.77 s of
simulated time), and takes about 4 minutes of wall time in xsim.

## What is compared

The testbench (`sim/bench.v`)
writes one line per event to a trace file:

| Line | Meaning |
|---|---|
| `UART <hex>` | one byte decoded from the FPGA-to-PC UART line (115200 8N1) |
| `LEDS <time_ns> <hex>` | the LED register changed, with the simulation time in ns |
| `END <reason> cycles=<n> uart_bytes=<n> leds=<hex>` | why and when the run stopped |

The golden trace is `sim/golden/mandelbrot_bram.txt`. Pass means the new trace is
byte-identical: same UART bytes in the same order, same LED changes at the same times,
same total cycle count. The cycle count in the `END` line is deliberate: it makes the
gate stricter than "same bytes", so a refactor that silently changes instruction timing
fails even when the visible output does not. The testbench reads no internal signals,
so the RTL can be restructured freely without touching it.

To read the UART output as text:

```sh
grep '^UART' sim/golden/mandelbrot_bram.txt | cut -d' ' -f2 | xxd -r -p
```

## Boot mode and firmware

There is no SPI-flash model, so the testbench instantiates `SOC #(.BOOT_ADDR(0))` to
force BRAM boot. The RAM loads `firmware.hex` with `$readmemh`; the script links the
canonical image (`rtl/firmware.hex`, produced by `make -C fw`) into `sim/build/` and
runs xsim from there.

## Stop conditions

The run ends at whichever comes first:

- the LED register becomes `STOP_LEDS` (default 1; negative disables this condition).
  The mandelbrot demo writes its frame counter to the LEDs at the top of every frame,
  so this marks the end of the first complete frame. The run stops at that instant: a
  UART byte still in flight would not be recorded. That is deterministic, so the gate
  is unaffected, and in the golden run the last byte finishes before the LED write;
- `MAX_CYCLES` input-clock cycles (default 400 M, 2 s simulated).

Both are testbench parameters and can be overridden with plusargs
(`+out=`, `+max_cycles=`, `+stop_leds=`; in xsim `-testplusarg "max_cycles=4000000"`).
`run_regression.sh --max-cycles N` passes the budget through for a quick smoke run
(a few seconds for a few million cycles) and skips the compare, since a truncated trace
can never match the golden file.

## Updating the golden file

Only when a behavior change is intended. `sim/run_regression.sh --update-golden`
overwrites the golden trace with the new run; commit it together with the RTL change
and say why in the commit message.

## Assembly test programs

`sim/asm/` holds the tutorial's Verilog assembler (`riscv_assembly.v`) and a sample
program (`program_asm.v`, the ASCII mandelbrot). `make -C sim/asm` runs it under
iverilog and writes `sim/asm/program.hex`, a RAM image in the same format as
`rtl/firmware.hex`. Neither output is tracked.

## Synthesis baseline

`vivado/baseline.tcl` runs synthesis, placement and routing for the Genesys 2 part in
non-project mode and writes reports to `build/baseline/`. The RTL file list it shares
with the run script is `vivado/rtl_sources.txt` (via `vivado/sources.tcl`). The numbers from the unrefactored
design are recorded in `docs/baseline.md`.
