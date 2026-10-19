#!/bin/bash
# Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
#
# mc-escape-check.sh <outdir> <cycles>
# FullPanelDemo in FullPanel fullscreen; per cycle: Mission Control opened in
# the Space (open -a "Mission Control"), left with Escape, band measured at
# ~0.4 s and 1.2 s (as SpacesHarness missioncontrol.sh "escape"), with the
# engine trace captured. DEMO_APP selects the build (A/B). Synthetic input.
set -u
OUT="$1"; N="${2:-3}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${DEMO_APP:-$ROOT/Examples/FullPanelDemo/build/FullPanelDemo.app}"
CTL="$ROOT/Tools/SpacesHarness/build/spacesctl"
mkdir -p "$OUT"; BM="$OUT/bandmeasure"
swiftc -O "$ROOT/Tools/BehaviorProbes/BandMeasure/main.swift" -o "$BM" 2>/dev/null || exit 1
pgrep -f 'FullPanelDemo.app/Contents/MacOS' >/dev/null && { echo "demo already running"; exit 1; }
open -n "$APP" --stderr "$OUT/demo.log" --args -FullPanelTrace YES
sleep 3; "$CTL" move 900 620
[ "$("$CTL" front)" = "FullPanel Demo" ] || { echo "ABORT: demo not frontmost"; exit 1; }
"$CTL" key 3 ctrl cmd; sleep 4
echo "entry $("$BM" "$OUT/entry.png" | tail -1)"
for i in $(seq 1 "$N"); do
  echo "mark cycle $i" >> "$OUT/marks.txt"; date +%s.%N >> "$OUT/marks.txt"
  open -a "Mission Control"; sleep 1.4; "$CTL" key 53
  sleep 0.4; "$CTL" move 900 620
  a=$("$BM" "$OUT/c$i-0.4.png" | tail -1); sleep 0.6
  b=$("$BM" "$OUT/c$i-1.2.png" | tail -1); sleep 1.8
  echo "cycle $i  0.4: $a"; echo "         1.2: $b"
done
[ "$("$CTL" front)" = "FullPanel Demo" ] && { "$CTL" key 3 ctrl cmd; sleep 3; }
osascript -e 'tell application id "dev.brianmerchant.FullPanelDemo" to quit' >/dev/null 2>&1; sleep 1.5
