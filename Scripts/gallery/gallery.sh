#!/bin/sh
# The screenshot gallery: every session in Scripts/gallery/sessions played headless (after the
# quick boot) on the native engine and on the lab, into out/gallery/native and out/gallery/lab,
# then out/gallery/index.html, a contact sheet with the two side by side and a note per image
# whether the pixels are identical (Scripts/gallery/index.swift). out/ is git-ignored. When a
# ReplayMatrixTests run left its last-checkpoint frames in build/testdata/replay-matrix/frames, the
# contact sheet shows them too (native engine replay against the lab recording).
#
#     Scripts/gallery/gallery.sh
#
# The disk image is $FS2_D64, else the app's imported copy in ~/Library/Application Support/FS2/.
# Runs SwiftPM, so in a sandboxed shell run it outside the sandbox. Every command has a wall-clock
# cap (Scripts/capped, which kills the command's whole process group when the time is up).
set -eu
# A failed (or capped) headless run must stop the script, not vanish into the grep below.
set -o pipefail
cd "$(dirname "$0")/../.."
D64=${FS2_D64:-"$HOME/Library/Application Support/FS2/FlightSimulatorII.d64"}
OUT=out/gallery
cap() { Scripts/capped "$@"; }

cap 900 swift build -c release --product FS2
BIN="$(cap 600 swift build -c release --show-bin-path)/FS2"
rm -rf "$OUT"
mkdir -p "$OUT/native" "$OUT/lab"
for session in Scripts/gallery/sessions/*.txt; do
    for engine in native lab; do
        echo "== $(basename "$session") on the $engine engine"
        cap 900 "$BIN" --headless --engine "$engine" --quick-boot --session "@$session" \
            --screenshot-dir "$OUT/$engine" --d64 "$D64" | grep -v '^wrote '
    done
done
# The replay matrix's last-checkpoint frames (written by ReplayMatrixTests), when a test run left them.
if [ -d build/testdata/replay-matrix/frames ]; then
    mkdir -p "$OUT/replay"
    cp build/testdata/replay-matrix/frames/*.png "$OUT/replay/"
fi
cap 600 swift Scripts/gallery/index.swift "$OUT" Scripts/gallery/sessions
