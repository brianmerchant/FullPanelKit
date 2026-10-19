#!/bin/bash
# Moves a fullscreen Space from the built-in display to the external display
# and back by dragging its thumbnail in Mission Control, then leaves Mission
# Control one of three ways. Records which display shows what, the window's
# state and, for FullPanel, the engine state on each display.
#
#   ./migration.sh <control|session|fpwindow> <escape|moved|desktop> [outdir]
#     escape:  Escape (returns to the Space Mission Control was opened from)
#     moved:   click the moved Space's thumbnail on the target display
#     desktop: click the Desktop left behind on the source display
#
# macOS 27.0.1 leaves a display showing only its black backstop after
# `escape` and `moved` (native fullscreen too; docs/WINDOW_LIFECYCLE.md). The
# script detects that and recovers the display by entering and leaving a
# fullscreen window there. Needs Accessibility and Screen Recording for the
# terminal; the Spaces-bar points are calibrated (README). Do not use the Mac
# while it runs.
#
# The Command-Tab steps need the activation to show the window's Space, so
# SpacesLab runs with AppleSpacesSwitchOnActivate=YES in its own argument
# domain (SWITCH=system to use this Mac's setting; nothing system-wide changes).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$ROOT/build"; C="$B/spacesctl"
MODE="${1:?mode}"; DISMISS="${2:?dismiss}"
source "$(dirname "${BASH_SOURCE[0]}")/outdir.sh"; OUT=$(harness_outdir "SpacesHarness-migration-$MODE-$DISMISS" "${3:-}") || exit 1
[ -x "$C" ] || { echo "Build first: $ROOT/build.sh"; exit 1; }
mkdir -p "$OUT"
SWITCH="${SWITCH:-YES}"
SWARGS=(); [ "$SWITCH" != system ] && SWARGS=(-AppleSpacesSwitchOnActivate "$SWITCH")
other() { [ "$1" = builtin ] && echo external || echo builtin; }
labpid() { pgrep -n -f "SpacesLab.app/Contents/MacOS/SpacesLab"; }
state() {
    echo "== $1"
    echo "   lab Space: $("$C" space "$(labpid)")"
    "$C" shot "$OUT/$1" | sed 's/^/   /'
    "$C" cmd lab dump; sleep 0.3
    tail -1 "$OUT/app.log" | grep -oE 'active=[01]|pres=0x[0-9a-f]+|scr=[^ ]+|fp\{[^}]*\}' | tr '\n' ' ' | sed 's/^/   /'; echo
}
move() {   # move <to>: drag the lab's fullscreen Space to the other display's Spaces bar
    local from; from=$(other "$1")
    open -a "Mission Control"; sleep 1.4
    "$C" move 900 4; sleep 1.0   # pointer at the top edge: the Spaces bars expand
    for attempt in 1 2 3; do
        local where; where=$("$C" space "$(labpid)")
        local idx cnt; idx=$(echo "$where" | sed -E 's/.*index=([0-9]+).*/\1/'); cnt=$(echo "$where" | sed -E 's/.*count=([0-9]+).*/\1/')
        read -r sx sy <<< "$("$C" bar "$from" "$cnt" "$idx")"
        read -r tx ty <<< "$("$C" bar "$1" 1 0)"   # the target display's single Desktop
        "$C" drag "$sx" "$sy" $((tx + 110)) "$ty"; sleep 2
        "$C" space "$(labpid)" | grep -q "display=$1" && break
        echo "   drag attempt $attempt did not move the Space ($("$C" space "$(labpid)"))"
    done
    case "$DISMISS" in
        escape) "$C" key 53 ;;
        moved)
            local where; where=$("$C" space "$(labpid)")
            read -r x y <<< "$("$C" bar "$1" "$(echo "$where" | sed -E 's/.*count=([0-9]+).*/\1/')" "$(echo "$where" | sed -E 's/.*index=([0-9]+).*/\1/')")"
            "$C" click "$x" "$y" ;;
        desktop) read -r x y <<< "$("$C" bar "$from" 1 0)"; "$C" click "$x" "$y" ;;
    esac
    sleep 3
}
recover() {
    for which in builtin external; do
        local nb; nb=$("$C" shot "$OUT/check" | awk -v w="$which" '$1==w {split($2,a,"="); print a[2]}')
        [ -z "$nb" ] && continue
        if awk -v n="$nb" 'BEGIN{exit !(n<0.05)}'; then
            echo "!! $which display black ($nb): recovering"
            open -n "$B/SpacesLab.app" --args -mode control -tag recover -screen "$which" -log "$OUT/recover-$which.log" -autoFS YES; sleep 4.5
            "$C" cmd recover exit; sleep 2.5; "$C" cmd recover quit; sleep 1.5
        fi
    done
    "$C" shot "$OUT/recovered" | sed 's/^/   recovered /'
}
pkill -f "SpacesLab.app/Contents/MacOS/SpacesLab"; sleep 1
"$B/SpacesLab.app/Contents/MacOS/SpacesLab" -mode "$MODE" -tag lab -log "$OUT/app.log" -autoFS YES -FullPanelTrace YES ${SWARGS[@]+"${SWARGS[@]}"} \
    > "$OUT/trace.txt" 2>&1 &
sleep 5
state 0-fullscreen-builtin
move external; state 1-moved-to-external
"$C" cmdtab; sleep 2.5; state 2-activated-on-external
move builtin; state 3-moved-back-to-builtin
"$C" cmdtab; sleep 2.5; state 4-activated-on-builtin
"$C" cmd lab exit; sleep 2.5; state 5-exited
"$C" cmd lab quit; sleep 2
recover
echo "Logs and captures: $OUT"
