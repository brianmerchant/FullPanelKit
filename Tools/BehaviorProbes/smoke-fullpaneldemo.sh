#!/bin/bash
# Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
#
# smoke-fullpaneldemo.sh <outdir> [swiftui|accessory]
# FullPanelDemo (FullPanelWindow) on the built-in display: enter native
# fullscreen (Control-Command-F), measure the band, click both band areas,
# reveal the menu bar at the top edge (HID moves), move away, exit. Writes
# the engine's diagnostics report after each step. Synthetic input only;
# needs Accessibility and Screen Recording for the terminal.
set -u
OUT="$1"; VARIANT="${2:-appkit}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${DEMO_APP:-$ROOT/Examples/FullPanelDemo/build/FullPanelDemo.app}"
CTL="$ROOT/Tools/SpacesHarness/build/spacesctl"
mkdir -p "$OUT"
BM="$OUT/bandmeasure"
swiftc -O "$ROOT/Tools/BehaviorProbes/BandMeasure/main.swift" -o "$BM" 2>/dev/null || { echo "bandmeasure build failed"; exit 1; }
if pgrep -f 'FullPanelDemo.app/Contents/MacOS' >/dev/null; then echo "another FullPanelDemo is running; quit it first"; exit 1; fi
if [ -e "$HOME/Downloads/FullPanelDemo-report.json" ]; then echo "~/Downloads/FullPanelDemo-report.json exists; move it first"; exit 1; fi
ARGS=(-FullPanelTrace YES)
[ "$VARIANT" = swiftui ] && ARGS+=(-FullPanelDemoSwiftUI YES)
# accessory: AppKit window with a hidden titlebar accessory (opaque titlebar window).
[ "$VARIANT" = accessory ] && ARGS+=(-FullPanelDemoTitlebarAccessory YES)
step() { echo "== $1"; }
front_is_demo() { [ "$("$CTL" front)" = "FullPanel Demo" ] || { echo "ABORT: frontmost is '$("$CTL" front)', not the demo; no keys sent"; exit 1; }; }
report() {  # Cmd-R writes ~/Downloads/FullPanelDemo-report.json
  front_is_demo
  "$CTL" key 15 cmd; sleep 1.0
  if [ -e "$HOME/Downloads/FullPanelDemo-report.json" ]; then
    mv "$HOME/Downloads/FullPanelDemo-report.json" "$OUT/$VARIANT-$1.json"
    /usr/bin/python3 -c "import json,sys;d=json.load(open('$OUT/$VARIANT-$1.json'));print('   ', ' '.join(f'{k}={d.get(k)}' for k in ['state','appKitFrameCoversDisplay','menuBarOverrideSubmitted','revealActive','revealSource','revealAllowed','menuBarRevealed','titlebarPassThrough','presentationForcing','appPresentationOptionsRaw','leftClicks','rightClicks','lastError']))"
  else echo "    (no report)"; fi
}
measure() { "$BM" "$OUT/$VARIANT-$1.png" | sed 's/^/    /'; }

step "launch ($VARIANT)"
open -n "$APP" --stderr "$OUT/$VARIANT-demo.log" --args "${ARGS[@]}"
sleep 3; "$CTL" move 900 600
step "enter fullscreen (Control-Command-F)"
front_is_demo; "$CTL" key 3 ctrl cmd; sleep 3.5
measure 1-entered
TARGETS=$("$BM" "$OUT/$VARIANT-targets.png" | sed -n 's/^targets //p')
LX=$(echo "$TARGETS" | sed 's/left=\([0-9]*\),\([0-9]*\).*/\1/'); LY=$(echo "$TARGETS" | sed 's/left=[0-9]*,\([0-9]*\).*/\1/')
RX=$(echo "$TARGETS" | sed 's/.*right=\([0-9]*\),.*/\1/')
report 1-entered
step "clicks: left x2, right x1 (y=$LY)"
"$CTL" click "$LX" "$LY"; sleep 0.3; "$CTL" click "$LX" "$LY"; sleep 0.3; "$CTL" click "$RX" "$LY"; sleep 0.5
"$CTL" move 900 600; sleep 0.5
report 2-clicked
step "pointer to the top edge (two approaches)"
for y in 300 240 180 120 60 20 0; do "$CTL" move 400 $y; sleep 0.03; done
for i in $(seq 1 15); do "$CTL" move 400 0; sleep 0.03; done
for y in 10 30 60 30 10 0; do "$CTL" move 400 $y; sleep 0.03; done
for i in $(seq 1 40); do "$CTL" move 400 0; sleep 0.03; done
sleep 0.6
measure 3-revealed
report 3-revealed
step "pointer back into the content"
for y in 20 60 120 200 300 450 600; do "$CTL" move 400 $y; sleep 0.03; done
sleep 1.5
measure 4-hidden
report 4-hidden
step "click left once more after the reveal"
"$CTL" click "$LX" "$LY"; sleep 0.5; "$CTL" move 900 600; sleep 0.3
report 5-clicked-after-reveal
step "exit fullscreen"
front_is_demo; "$CTL" key 3 ctrl cmd; sleep 3
report 6-exited
osascript -e 'tell application id "dev.brianmerchant.FullPanelDemo" to quit' >/dev/null 2>&1; sleep 1.5
pgrep -f 'FullPanelDemo.app/Contents/MacOS' >/dev/null && echo "WARNING: demo still running"
echo "log: $OUT/$VARIANT-demo.log"
