#!/usr/bin/env bash
# SoC simulation regression (seam 1).
#
# Simulates the SoC top in xsim with the canonical firmware image (mandelbrot,
# BRAM boot), writes the observed UART bytes and LED changes to a trace file,
# and diffs it against the committed golden trace. Exit status is non-zero on
# any difference, so this can gate a refactor.
#
#   sim/run_regression.sh                 run and compare
#   sim/run_regression.sh --update-golden run and overwrite the golden trace
#   sim/run_regression.sh --max-cycles N  smoke run with a short budget; no compare
#
# Needs Vivado's xvlog/xelab/xsim on PATH (source settings64.sh first).
set -euo pipefail

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SIM_DIR/.." && pwd)"

# Source locations. The RTL list is shared with the Vivado scripts.
RTL_LIST="$ROOT/vivado/rtl_sources.txt"
BENCH="$ROOT/sim/bench.v"
HEX="$ROOT/rtl/firmware.hex"

GOLDEN="$SIM_DIR/golden/mandelbrot_bram.txt"
BUILD="$SIM_DIR/build"
TRACE="$BUILD/trace.txt"
SNAPSHOT=soc_regression

usage() {
    cat <<USAGE
usage: sim/run_regression.sh [--update-golden | --max-cycles N]

Simulates the SoC in xsim with the canonical firmware image and diffs the
observed UART bytes and LED changes against sim/golden/mandelbrot_bram.txt.
Exit status 0 on a match, 1 on any difference, 2 on a usage or tool error.

  --update-golden   overwrite the golden trace with this run (shows the diff first)
  --max-cycles N    smoke run with a budget of N cycles; the trace is not compared
USAGE
}

UPDATE_GOLDEN=0
MAX_CYCLES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --update-golden) UPDATE_GOLDEN=1 ;;
        --max-cycles)
            [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] \
                || { echo "--max-cycles needs a positive integer" >&2; exit 2; }
            MAX_CYCLES="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
if [ "$UPDATE_GOLDEN" = 1 ] && [ -n "$MAX_CYCLES" ]; then
    echo "--update-golden and --max-cycles cannot be combined: a truncated run is not a golden" >&2
    exit 2
fi

for tool in xvlog xelab xsim; do
    command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH (source Vivado's settings64.sh)" >&2; exit 2; }
done
XILINX_VIVADO="${XILINX_VIVADO:-$(cd "$(dirname "$(command -v xvlog)")/.." && pwd)}"
GLBL="$XILINX_VIVADO/data/verilog/src/glbl.v"
[ -f "$GLBL" ] || { echo "FAIL: glbl.v not found at $GLBL" >&2; exit 2; }
[ -f "$HEX" ]  || { echo "FAIL: firmware image not found at $HEX" >&2; exit 2; }

RTL_FILES=()
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    RTL_FILES+=("$ROOT/$line")
done < "$RTL_LIST"

# xsim resolves $readmemh("firmware.hex") against its working directory, so
# run everything from the build directory with a link to the canonical image.
rm -rf "$BUILD"
mkdir -p "$BUILD"
ln -s "$HEX" "$BUILD/firmware.hex"
cd "$BUILD"

echo "== compile"
xvlog --nolog "${RTL_FILES[@]}" "$BENCH" "$GLBL" > xvlog.out 2>&1 \
    || { cat xvlog.out; echo "FAIL: xvlog"; exit 1; }
echo "== elaborate"
xelab --nolog -L unisims_ver --snapshot "$SNAPSHOT" work.bench work.glbl > xelab.out 2>&1 \
    || { cat xelab.out; echo "FAIL: xelab"; exit 1; }

echo "== simulate"
PLUSARGS=(-testplusarg "out=$TRACE")
[ -n "$MAX_CYCLES" ] && PLUSARGS+=(-testplusarg "max_cycles=$MAX_CYCLES")
start=$(date +%s)
xsim --nolog "$SNAPSHOT" --runall "${PLUSARGS[@]}" > xsim.out 2>&1 \
    || { cat xsim.out; echo "FAIL: xsim"; exit 1; }
grep '^bench:' xsim.out || true
echo "   wall time: $(( $(date +%s) - start )) s"
[ -s "$TRACE" ] || { cat xsim.out; echo "FAIL: no trace written"; exit 1; }

if [ -n "$MAX_CYCLES" ]; then
    echo "SMOKE: budget of $MAX_CYCLES cycles, trace in $TRACE; not compared to the golden file"
    grep '^END' "$TRACE"
    exit 0
fi

if [ "$UPDATE_GOLDEN" = 1 ]; then
    mkdir -p "$(dirname "$GOLDEN")"
    if [ -f "$GOLDEN" ]; then
        if cmp -s "$GOLDEN" "$TRACE"; then
            echo "UNCHANGED: new trace is identical to $(basename "$GOLDEN")"
            exit 0
        fi
        echo "== golden changes (old < > new, first 20 lines)"
        diff "$GOLDEN" "$TRACE" | head -20 || true
    fi
    cp "$TRACE" "$GOLDEN"
    echo "UPDATED: $GOLDEN ($(wc -l < "$GOLDEN") lines); review with git diff before committing"
    exit 0
fi

[ -f "$GOLDEN" ] || { echo "FAIL: no golden trace at $GOLDEN (run with --update-golden to capture one)"; exit 1; }
if cmp -s "$GOLDEN" "$TRACE"; then
    echo "PASS: trace matches $(basename "$GOLDEN") ($(wc -l < "$TRACE") lines)"
else
    echo "FAIL: trace differs from $(basename "$GOLDEN")"
    diff "$GOLDEN" "$TRACE" | head -40 || true
    exit 1
fi
