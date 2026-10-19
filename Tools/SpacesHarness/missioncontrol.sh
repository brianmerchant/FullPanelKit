#!/bin/bash
# Mission Control and Space-switch returns to a fullscreen window: native
# fullscreen (control), FullPanelSession and FullPanelWindow through the same
# real HID steps. After each return it records whether the window's Space is
# shown and how much of SpacesLab's teal content is in the areas beside the
# camera housing (spacesctl band) 0.4 s, 1.2 s and 3 s later.
#
#   ./missioncontrol.sh [cycles] [outdir]
#
# Paths, each `cycles` times (default 3):
#   escape        Mission Control opened in the Space, left with Escape
#   large         click the window's large preview in Mission Control
#   thumb         pointer to the top edge, click the Space's small thumbnail
#   large-thumb   hover the large preview first, then the small thumbnail
#   away-thumb    Control-Left to the desktop, Mission Control there, then the
#                 Space's small thumbnail
#   switch        Control-Left to the desktop, Control-Right back (no Mission Control)
#
# Expected: the Space is shown after every return in all three modes; teal
# beside the housing ~0 for the control (ordinary fullscreen leaves it black)
# and ~1 for FullPanel by 3 s. A path where the control is not shown either is a
# calibration problem of this script, not a FullPanel result. The 0.4 s sample
# can still include Mission Control's closing animation (its Spaces bar and
# backdrop over the window); only the 1.2 s and 3 s samples are settled.
#
# Needs Accessibility and Screen Recording for the terminal and the built-in
# notched display (any number of Desktops; thumbnail positions come from
# WindowServer's Space order and the calibration in README.md). Do not use the Mac while it runs
# (about 6 minutes with 3 cycles). Changes no setting.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$ROOT/build"; C="$B/spacesctl"
N="${1:-3}"; source "$(dirname "${BASH_SOURCE[0]}")/outdir.sh"; OUT=$(harness_outdir "SpacesHarness-missioncontrol" "${2:-}") || exit 1
[ -x "$C" ] || { echo "Build first: $ROOT/build.sh"; exit 1; }
mkdir -p "$OUT"
labpid() { pgrep -n -f "SpacesLab.app/Contents/MacOS/SpacesLab"; }
field() { echo "$2" | sed -E "s/.*$1=([^ ]+).*/\1/"; }
center() { "$C" move 900 620; }            # away from the top edge (no menu-bar reveal)
mc() { open -a "Mission Control"; sleep 1.4; }
thumb() {                                    # click the lab Space's small thumbnail
    "$C" move 900 4; sleep 1.0               # pointer at the top edge: the Spaces bar expands
    local s; s=$("$C" space "$(labpid)")
    read -r x y <<< "$("$C" bar builtin "$(field count "$s")" "$(field index "$s")")"
    "$C" click "$x" "$y"
}
sample() {   # sample <label>
    local line="$1" t prev=0 b
    for t in 0.4 1.2 3.0; do
        sleep "$(echo "$t - $prev" | bc)"; prev=$t
        [ "$t" = 0.4 ] && center
        b=$("$C" band "$OUT/$MODE-$1-$t")
        line+=" t$t[$(echo "$b" | tr -d '\n')]"
    done
    local s; s=$("$C" space "$(labpid)")
    "$C" cmd lab dump; sleep 0.3
    local st; st=$(tail -1 "$OUT/$MODE.log" | grep -oE 'fp\{state=[0-9]+' | sed 's/fp{//')
    line+=" shown=$(field shown "$s") ${st:-state=-}"
    echo "  $line" | tee -a "$OUT/$MODE.results"
}
for MODE in control session fpwindow; do
    pkill -f "SpacesLab.app/Contents/MacOS/SpacesLab"; sleep 1
    : > "$OUT/$MODE.results"
    echo "== $MODE"
    open -n "$B/SpacesLab.app" --args -mode "$MODE" -tag lab -log "$OUT/$MODE.log" -autoFS YES -FullPanelTrace YES
    sleep 5; center; sleep 1
    sample entry
    for i in $(seq 1 "$N"); do
        mc; "$C" key 53;                                   sample "escape-$i"
        mc; "$C" click 900 620;                            sample "large-$i"
        mc; thumb;                                         sample "thumb-$i"
        mc; "$C" move 900 620; sleep 0.6; thumb;           sample "large-thumb-$i"
        "$C" key 123 ctrl fn; sleep 1.8; mc; thumb;        sample "away-thumb-$i"
        "$C" key 123 ctrl fn; sleep 1.8; "$C" key 124 ctrl fn; sample "switch-$i"
    done
    "$C" cmd lab exit; sleep 2.5; "$C" cmd lab quit; sleep 1.5
done
echo
echo "Summary (shown at 3 s; FullPanel: teal >= 0.90 on both sides at 3 s; control: teal <= 0.05):"
for MODE in control session fpwindow; do
    awk -v m="$MODE" '
        { n++; shown = ($0 ~ /shown=1/); ok = shown
          if (match($0, /t3.0\[left=[0-9.]+ right=[0-9.]+\]/)) {
              split(substr($0, RSTART, RLENGTH), a, /[=\] ]/); l = a[2] + 0; r = a[4] + 0
              if (m == "control") ok = ok && l <= 0.05 && r <= 0.05; else ok = ok && l >= 0.9 && r >= 0.9 }
          if (ok) pass++; else print "  " m " NOT OK:" $0 }
        END { printf "  %-8s %d/%d\n", m, pass, n }' "$OUT/$MODE.results"
done
echo "Logs and band captures: $OUT"
