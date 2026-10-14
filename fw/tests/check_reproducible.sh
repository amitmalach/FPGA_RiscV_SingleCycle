#!/usr/bin/env bash
# Firmware reproducibility check: from a clean tree, the default `make`
# regenerates the committed firmware image byte-for-byte.
#
# The reference is the image committed at HEAD (falls back to the working
# copy when the file is not tracked yet). The working-copy image is deleted
# before the build so a no-op `make` cannot pass by accident.
set -euo pipefail

FW_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# --no-print-directory: when run as a sub-make, the inherited -w flag would
# otherwise print an "Entering directory" banner into this capture.
HEX="$(make -s --no-print-directory -C "$FW_DIR" print-hex-path)"

[ -f "$HEX" ] || { echo "FAIL: canonical image $HEX does not exist"; exit 1; }

REF="$(mktemp)"
trap 'rm -f "$REF"' EXIT
HEX_REPO_PATH="$(git -C "$FW_DIR" ls-files --full-name "$HEX" 2>/dev/null || true)"
if [ -n "$HEX_REPO_PATH" ] && git -C "$FW_DIR" cat-file -e "HEAD:$HEX_REPO_PATH" 2>/dev/null; then
    git -C "$FW_DIR" show "HEAD:$HEX_REPO_PATH" > "$REF"
    SRC="image committed at HEAD"
elif [ -n "$HEX_REPO_PATH" ]; then
    # Tracked but not yet in HEAD (e.g. staged after a move): compare against the index.
    git -C "$FW_DIR" show ":$HEX_REPO_PATH" > "$REF"
    SRC="image staged in the index"
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
    diff "$REF" "$HEX" | head -20 || true
    exit 1
fi
