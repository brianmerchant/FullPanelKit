#!/bin/bash
# One FullPanelAttachDemo scenario (SwiftUI WindowGroup windows with
# FullPanelSession; ScenarioTest.swift) under this harness's stop rules.
#
#   ./demo-run.sh <label> <outdir> <scenario> [demo options ...]
#
# The demo is started from this shell, as run-scenarios.sh does, so its band
# captures use the terminal's Screen Recording access. It writes its report and
# captures into <outdir>, never into a folder macOS protects (outdir.sh).
# Stops at once on a system dialog (left untouched, the demo left running;
# <outdir>/STOPPED blocks later runs) or on input not from a harness (the demo
# is quit). Watchdog: 240 s. The caller keeps the scenario within 10
# fullscreen transitions (e.g. -FullPanelAttachLifecycleSteps,
# -FullPanelAttachMissionControlCycles 0).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$ROOT/build/spacesctl"
DEMO="$ROOT/../../Examples/FullPanelAttachDemo/build/FullPanelAttachDemo.app/Contents/MacOS/FullPanelAttachDemo"
LABEL="$1"; OUT="$2"; SCENARIO="$3"; shift 3
[ -x "$C" ] && [ -x "$DEMO" ] || { echo "build SpacesHarness and FullPanelAttachDemo first"; exit 1; }
source "$ROOT/outdir.sh"; harness_outdir "$LABEL" "$OUT" >/dev/null || exit 1
[ -e "$OUT/STOPPED" ] && { echo "$OUT/STOPPED exists: an earlier run was stopped"; exit 3; }
pgrep -x FullPanelAttachDemo >/dev/null && { echo "FullPanelAttachDemo already running; not starting"; exit 1; }
mkdir -p "$OUT/$LABEL"
P="$OUT/$LABEL"; WATCH="$P.watch"
now() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
a=$("$C" alerts) || { echo "a system dialog is on screen; not starting: $a"; exit 1; }
"$C" watch "$WATCH" & WPID=$!
trap 'kill $WPID 2>/dev/null' EXIT
sleep 0.5
head -1 "$WATCH" 2>/dev/null | grep -q "access=1" || { echo "input watch unavailable; not starting"; exit 1; }
START=$(now)
echo "== $LABEL ($SCENARIO $*) $(date '+%H:%M:%S') binary=$(shasum -a 256 "$DEMO" | cut -c1-16)" | tee "$P.summary"
"$DEMO" -FullPanelAttachScenario "$SCENARIO" -FullPanelTrace YES -FullPanelAttachReport "$P.json" \
    -FullPanelAttachShotDir "$P" "$@" > "$P.log" 2>&1 &
DPID=$!
for _ in $(seq 1 480); do
    sleep 0.5
    kill -0 $DPID 2>/dev/null || break
    if ! a=$("$C" alerts); then
        touch "$OUT/STOPPED"; echo "STOPPED (dialog): left untouched, demo left running: $a" | tee -a "$P.summary"; exit 2
    fi
    u=$(awk -v s="$START" '$1 ~ /^[0-9]+$/ && $1 >= s && $2 != "type=12"' "$WATCH" | head -3)
    if [ -n "$u" ]; then
        kill $DPID; touch "$OUT/STOPPED"; echo "STOPPED (input not from the harness): $u" | tee -a "$P.summary"; exit 2
    fi
done
kill $DPID 2>/dev/null && echo "watchdog stopped the demo" | tee -a "$P.summary"
grep -E "scenario (PASS|FAIL)" "$P.log" | sed -E 's/^.*scenario (PASS|FAIL): /\1 /' | tee -a "$P.summary"
grep -E "scenario .* done:" "$P.log" | sed -E 's/^.*scenario /  /; s/; report.*//' | tee -a "$P.summary"
