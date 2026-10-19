#!/bin/bash
# Runs the fullscreen-entry scenario matrix (ScenarioTest.swift) on this Mac's
# built-in notched display and prints a summary. Build first: ./build-demo.sh
#
#   ./run-scenarios.sh [outdir] [missionControlCycles]
#
# Needs, for the launching terminal: Screen Recording (pixel checks beside the
# camera housing) and Accessibility (the Escape key that returns from Mission
# Control). Moves windows into fullscreen, opens Mission Control and relaunches
# the demo several times; do not use the Mac while it runs (about 5 minutes).
#
# Restoration uses -NSQuitAlwaysKeepsWindows YES as a launch argument (the
# demo's argument domain only; no system setting is changed). Each restore check
# exits fullscreen at the end, so the demo's saved state ends windowed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/build/FullPanelAttachDemo.app/Contents/MacOS/FullPanelAttachDemo"
OUT="${1:-$HOME/Downloads/FullPanelAttachDemo-scenarios-$(date +%Y%m%d-%H%M%S)}"
MC="${2:-10}"
KEEP=(-NSQuitAlwaysKeepsWindows YES)
[ -x "$BIN" ] || { echo "Build first: $ROOT/build-demo.sh"; exit 1; }
# Another copy (any build with the same bundle identifier) shares the saved
# window state and activation, and invalidates the restore scenarios.
if pgrep -x FullPanelAttachDemo >/dev/null; then
    echo "FullPanelAttachDemo is already running (pid $(pgrep -x FullPanelAttachDemo | tr '\n' ' ')); quit it first."
    exit 1
fi
mkdir -p "$OUT"

run() {   # run <tag> <scenario> [args...]
    local tag=$1 sc=$2; shift 2
    mkdir -p "$OUT/$tag"
    "$BIN" -FullPanelAttachScenario "$sc" -FullPanelTrace YES \
        -FullPanelAttachReport "$OUT/$tag.json" -FullPanelAttachShotDir "$OUT/$tag" "$@" > "$OUT/$tag.log" 2>&1 &
    local pid=$! i
    for i in $(seq 1 240); do sleep 1; kill -0 $pid 2>/dev/null || break; done
    kill $pid 2>/dev/null && echo "  watchdog stopped $tag"
    grep -E "scenario FAIL" "$OUT/$tag.log" | sed 's/^.*scenario FAIL: /  FAIL: /'
    grep -E "scenario .* done:" "$OUT/$tag.log" | sed "s/^.*scenario /  $tag: /; s/; report.*//"
}

echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) — results in $OUT"
echo "A  fresh entry + $MC Mission Control returns";  run A-fresh fresh -FullPanelAttachMissionControlCycles "$MC"
echo "B  attach inside existing fullscreen";           run B-existing existing -FullPanelAttachManual YES
echo "R1 restored into fullscreen + $MC returns"
run R1-setup restoreSetup "${KEEP[@]}" >/dev/null;   run R1-restore restoreCheck "${KEEP[@]}" -FullPanelAttachMissionControlCycles "$MC"
echo "R2 two windows restored"
run R2-setup restoreSetup "${KEEP[@]}" -FullPanelAttachScenarioWindows 2 >/dev/null
run R2-restore restoreCheck "${KEEP[@]}" -FullPanelAttachScenarioWindows 2
echo "R3 attach inside the restored entry's willEnterFullScreen"
run R3-setup restoreSetup "${KEEP[@]}" >/dev/null;   run R3-restore restoreCheck "${KEEP[@]}" -FullPanelAttachOnWillEnter YES
echo "R4 attach 250 ms late (expected: documented fallback, no bounce)"
run R4-setup restoreSetup "${KEEP[@]}" >/dev/null
run R4-restore restoreCheck "${KEEP[@]}" -FullPanelAttachDelayMs 250 -FullPanelAttachExpectFallback YES
echo "R5 restored while another app is in use, then activated like a Dock click + $MC returns"
run R5-setup restoreSetup "${KEEP[@]}" >/dev/null
run R5-restore restoreCheck "${KEEP[@]}" -FullPanelAttachBackgroundFirst YES -FullPanelAttachMissionControlCycles "$MC"
echo
echo "Recovery path per Mission Control return (expect $MC each):"
for f in A-fresh R1-restore R5-restore; do
    printf "  %-11s away=%s rearm=%s ready(fromAway)=%s reassert=%s\n" "$f" \
        "$(grep -c 'ev=away ' "$OUT/$f.log")" "$(grep -c ev=return-check-rearm "$OUT/$f.log")" \
        "$(grep -cE 'return-ready.*fromAway=1' "$OUT/$f.log")" "$(grep -c ev=reassert-commit "$OUT/$f.log")"
done
echo "Screenshots of the housing band: $OUT/*/*.png (check them; the metric is non-black pixels)"
