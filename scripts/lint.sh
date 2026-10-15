#!/usr/bin/env bash
# Mechanical checks that need no EDA tools. Exit 1 on the first failing group.
#
#   scripts/lint.sh                  all checks below
#   scripts/lint.sh --moves <rev>    only: every file moved since <rev> is a 100 % rename
#
# 1. No ignored by-products under rtl/, sim/ or fw/ except the build outputs
#    the Makefiles own (sim/build/, fw/build/, sim/asm/program.hex, program_asm.out).
#    Catches Vivado writing .Xil/ or clockInfo.txt next to the sources.
# 2. No tracked file outside rtl/ refers to a retired path (old Vivado import
#    tree, firmware/, bench_iverilog.v, vivado/sources.tcl). rtl/ is exempt
#    until ticket #5 trims its comments.
# 3. Markdown prose lines are at most 100 characters; table rows are exempt.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

moves_check() {
    local base="$1"
    [ -n "$base" ] || { echo "usage: scripts/lint.sh --moves <rev>" >&2; exit 2; }
    # With -M100% only byte-identical moves are reported as renames; anything
    # else shows up as an add or delete and is listed here.
    local bad
    bad=$(git diff -M100% --name-status --diff-filter=AD "$base" -- . ':!*.md' ':!LICENSE' ':!Makefile' ':!.gitignore' ':!scripts/*' ':!vivado/*')
    if [ -n "$bad" ]; then
        echo "FAIL: not a pure move since $base (A = added, D = deleted):"
        echo "$bad"
        exit 1
    fi
    echo "PASS: every file moved since $base is a byte-identical rename"
    exit 0
}
[ "${1:-}" = "--moves" ] && moves_check "${2:-}"

echo "== by-products in the source tree"
allowed='^!! (sim/build/|fw/build/|sim/asm/program\.hex|sim/asm/program_asm\.out)$'
stray=$(git status --short --ignored -- rtl sim fw | grep '^!!' | grep -Ev "$allowed" || true)
if [ -n "$stray" ]; then
    echo "FAIL: ignored files under rtl/, sim/ or fw/ that no Makefile owns:"
    echo "$stray"
    fail=1
fi

echo "== retired paths"
retired='Bruno_RISCV|FROM_BLINKER_TO_RISCV|bench_iverilog\.v|vivado/sources\.tcl|(^|[^a-z_/])firmware/'
hits=$(git ls-files | grep -v '^rtl/' | xargs grep -nE "$retired" 2>/dev/null | grep -v '^scripts/lint.sh:' || true)
if [ -n "$hits" ]; then
    echo "FAIL: references to paths that no longer exist:"
    echo "$hits"
    fail=1
fi

echo "== markdown line length"
long=$(git ls-files '*.md' | xargs awk 'length > 100 && $0 !~ /^\|/ {print FILENAME":"FNR": "length" chars"}')
if [ -n "$long" ]; then
    echo "FAIL: prose lines over 100 characters:"
    echo "$long"
    fail=1
fi

[ "$fail" = 0 ] && echo "PASS: lint clean"
exit "$fail"
