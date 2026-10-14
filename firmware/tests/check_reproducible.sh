#!/usr/bin/env bash
# Firmware reproducibility check: from a clean tree, the default `make`
# regenerates the committed firmware image byte-for-byte.
#
# The reference is the image committed at HEAD (falls back to the working
# copy when the file is not tracked yet). The working-copy image is deleted
# before the build so a no-op `make` cannot pass by accident.
set -euo pipefail

FW_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HEX="$(make -s -C "$FW_DIR" print-hex-path)"

[ -f "$HEX" ] || { echo "FAIL: canonical image $HEX does not exist"; exit 1; }

REF="$(mktemp)"
trap 'rm -f "$REF"' EXIT
if git -C "$FW_DIR" ls-files --error-unmatch "$HEX" >/dev/null 2>&1; then
    git -C "$FW_DIR" show "HEAD:$(git -C "$FW_DIR" ls-files --full-name "$HEX")" > "$REF"
    SRC="image committed at HEAD"
else
    cp "$HEX" "$REF"
    SRC="working-copy image (not tracked yet)"
fi

make -s -C "$FW_DIR" clean
rm -f "$HEX"
make -s -C "$FW_DIR"

if cmp -s "$REF" "$HEX"; then
    echo "PASS: regenerated $(basename "$HEX") is byte-identical to the $SRC ($(wc -c < "$HEX") bytes)"
else
    echo "FAIL: regenerated $HEX differs from the $SRC"
    diff "$REF" "$HEX" | head -20
    exit 1
fi
