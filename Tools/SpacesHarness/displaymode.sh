#!/bin/bash
# Display-mode changes on the built-in display while a window is in fullscreen:
# native fullscreen (control), FullPanelSession and FullPanelWindow.
#
#   ./displaymode.sh [housing-mode] [no-housing-mode] [outdir]
#
# A notched panel offers each scaled size twice: with the band beside the
# housing (safeAreaInsets.top > 0) and without it (a shorter mode below the
# housing). Defaults for a 14-inch MacBook Pro: 54 = 1512 x 982 (housing) and
# 60 = 1800 x 1125 (no housing); list yours with `build/spacesctl modes`.
#
# Steps per mode: enter fullscreen; switch to the other scaled mode with a
# housing (FullPanel must follow the new display size); revert; switch to a
# mode without a housing (FullPanel must release: .fallback / noCameraHousing,
# ordinary fullscreen); revert (FullPanel must resume).
#
# Modes are changed with kCGConfigureForAppOnly by `spacesctl modehold`, so
# macOS restores the previous mode when that process exits: nothing persists,
# and an interrupted run restores the mode too. Needs Screen Recording for the
# terminal. Do not use the Mac while it runs (about 3 minutes).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$ROOT/build"; C="$B/spacesctl"
WITH="${1:-54}"; WITHOUT="${2:-60}"
source "$(dirname "${BASH_SOURCE[0]}")/outdir.sh"; OUT=$(harness_outdir "SpacesHarness-displaymode" "${3:-}") || exit 1
[ -x "$C" ] || { echo "Build first: $ROOT/build.sh"; exit 1; }
mkdir -p "$OUT"
labpid() { pgrep -n -f "SpacesLab.app/Contents/MacOS/SpacesLab"; }
sample() {   # sample <label>
    "$C" cmd lab dump; sleep 0.4
    local last; last=$(tail -1 "$OUT/$MODE.log")
    local line="$1 band[$("$C" band "$OUT/$MODE-$1" | tr -d '\n')]"
    line+=" $(echo "$last" | grep -oE ' fr=\{\{[^}]*\}, \{[^}]*\}\}' | sed 's/^ //')"
    line+=" $(echo "$last" | grep -oE 'fp\{state=[0-9]+ reason=[0-9]+' | sed 's/fp{//')"
    line+=" $(echo "$last" | grep -oE 'released=[01]')"
    line+=" shown=$("$C" space "$(labpid)" | sed -E 's/.*shown=([01]).*/\1/')"
    echo "  $line" | tee -a "$OUT/$MODE.results"
}
hold() {   # hold <mode> <label>: change the mode, sample inside it, then let it revert
    "$C" modehold "$1" 9 > "$OUT/$MODE-$2-hold.txt" 2>&1 &
    local h=$!
    sleep 5; sample "$2"
    wait $h
    sleep 4; sample "$2-reverted"
}
echo "Modes: housing=$("$C" modes | awk -v i="$WITH" '$1==i{print $2}') no-housing=$("$C" modes | awk -v i="$WITHOUT" '$1==i{print $2}') current=$("$C" modes | awk '/current/{print $2}')"
for MODE in control session fpwindow; do
    pkill -f "SpacesLab.app/Contents/MacOS/SpacesLab"; sleep 1
    : > "$OUT/$MODE.results"
    echo "== $MODE"
    open -n "$B/SpacesLab.app" --args -mode "$MODE" -tag lab -log "$OUT/$MODE.log" -autoFS YES -FullPanelTrace YES
    sleep 5; "$C" move 900 620; sleep 1
    sample entry
    hold "$WITH" other-scale
    hold "$WITHOUT" no-housing
    "$C" cmd lab exit; sleep 2.5; "$C" cmd lab quit; sleep 1.5
done
echo "Mode after the run: $("$C" modes | awk '/current/{print $2}')"
echo "Logs and band captures: $OUT"
