#!/bin/bash
# Dock click and Command-Tab back to a fullscreen window in another Space:
# native fullscreen (control), FullPanelSession and FullPanelWindow, each from
# another application's fullscreen Space and from the desktop.
#
#   ./activation.sh [switch] [outdir]
#     switch: system (default; this Mac's "switch to a Space with open windows")
#             or YES / NO (AppleSpacesSwitchOnActivate in SpacesLab's own
#             argument domain only; no system setting is changed)
#
# Moves Spaces with Control-Arrow and opens fullscreen windows; do not use the
# Mac while it runs (about 2 minutes). Needs Accessibility for the terminal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$ROOT/build"; C="$B/spacesctl"
SW="${1:-system}"; source "$(dirname "${BASH_SOURCE[0]}")/outdir.sh"; OUT=$(harness_outdir "SpacesHarness-activation" "${2:-}") || exit 1
[ -x "$C" ] || { echo "Build first: $ROOT/build.sh"; exit 1; }
mkdir -p "$OUT"
ARGS=(); [ "$SW" != system ] && ARGS=(-AppleSpacesSwitchOnActivate "$SW")
labpid() { pgrep -n -f "SpacesLab.app/Contents/MacOS/SpacesLab"; }
left() { for _ in 1 2 3; do "$C" key 123 ctrl fn; sleep 1.8; done; }   # to the leftmost Space
check() {   # check <label> <front before>: did the activation show the lab's fullscreen Space?
    local s; s=$("$C" space "$(labpid)")
    local shown; shown=$(echo "$s" | sed -E 's/.*shown=([01]).*/\1/')
    printf "  %-34s before=%-10s front=%-10s %s -> %s\n" "$1" "$2" "$("$C" front)" "$s" "$([ "$shown" = 1 ] && echo switched || echo stayed)"
    echo "$1 $shown" >> "$OUT/$MODE.results"
}
# SpacesOther's window: windowed on the built-in desktop first, then fullscreen.
OTHER_X=900; OTHER_Y=600   # its window's centre (event coordinates), and the
                           # centre of its fullscreen Space later
activate_other() { "$C" click $OTHER_X $OTHER_Y; sleep 1.2; }
# Command-Tab to SpacesLab. Arriving on the desktop activates the application
# whose window is there (e.g. the terminal running this script), which then
# sits between SpacesOther and SpacesLab in Command-Tab's recent order.
cmdtab_lab() { if [ "$1" = SpacesLab ]; then "$C" cmdtab 1; else "$C" cmdtab 2; fi; }
for MODE in control session fpwindow; do
    pkill -f "SpacesLab.app/Contents/MacOS/SpacesLab"; pkill -f "SpacesOther.app/Contents/MacOS/SpacesOther"; sleep 1
    : > "$OUT/$MODE.results"
    echo "== $MODE (switch=$SW)"
    open -n "$B/SpacesLab.app" --args -mode "$MODE" -tag lab -log "$OUT/$MODE.log" -autoFS YES ${ARGS[@]+"${ARGS[@]}"}; sleep 5
    open -n "$B/SpacesOther.app" --args -mode plain -tag other -log "$OUT/$MODE-other.log"; sleep 4
    left; activate_other
    F=$("$C" front); "$C" dock SpacesLab >/dev/null; sleep 2.5; check "Dock click, other app on desktop" "$F"
    left; D=$("$C" front); activate_other
    F=$("$C" front); cmdtab_lab "$D"; sleep 2.5; check "Command-Tab, other app on desktop" "$F"
    left; D=$("$C" front); activate_other; "$C" cmd other enter; sleep 4   # SpacesOther in its own fullscreen Space
    activate_other
    F=$("$C" front); cmdtab_lab "$D"; sleep 2.5; check "Command-Tab, other app fullscreen" "$F"
    "$C" key 124 ctrl fn; sleep 1.8; "$C" key 124 ctrl fn; sleep 1.8; activate_other   # back to SpacesOther's Space
    F=$("$C" front); "$C" dock SpacesLab >/dev/null; sleep 2.5; check "Dock click, other app fullscreen" "$F"
    "$C" cmd other quit; sleep 1.5
    "$C" cmd lab dump; "$C" cmd lab exit; sleep 2.5; "$C" cmd lab quit; sleep 1.5
done
echo
for MODE in session fpwindow; do
    if cmp -s "$OUT/control.results" "$OUT/$MODE.results"; then echo "$MODE: same as native fullscreen"
    else echo "$MODE: DIFFERS from native fullscreen"; fi
done
echo "Logs: $OUT"
