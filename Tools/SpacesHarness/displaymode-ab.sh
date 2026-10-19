#!/bin/bash
# Display-mode validation of FullPanel geometry: one SpacesLab build and option
# set through exactly 6 transitions on the built-in display.
#
#   ./displaymode-ab.sh <label> <SpacesLab.app> <outdir> [-Option YES ...]
#
#   T1 entry       windowed -> fullscreen in the original mode (must have a housing)
#   T2 housing     the other scaled mode with a housing (1512 x 982)
#   T3 revert      back to the original mode
#   T4 no-housing  the mode below the housing (1800 x 1125): FullPanel must
#                  fall back to ordinary fullscreen
#   T5 revert      back to the original mode: FullPanel must resume
#   T6 exit        fullscreen -> windowed
#
# LABMODE=session runs an attached AppKit subclass (FullPanelSession) instead
# of FullPanelWindow (default fpwindow).
#
# Each transition records the window and screen frames, the notch inset,
# fullscreen, key and active state, FullPanel's state and geometry, the Space
# and the band beside the housing (dmcheck.py judges it).
#
# Display modes: the original is recorded before anything changes (in
# <outdir>/original-mode.txt, shared by the configurations of one outdir).
# Each change is held by `spacesctl modehold` (kCGConfigureForAppOnly): macOS
# restores the original when that process ends, and it ends by itself if this
# script dies. On every exit this script ends the hold and verifies the
# original mode is back; if it is not, it restores the user's permanent
# configuration and verifies again.
#
# Stops at once (STOPPED, never FAIL; <outdir>/STOPPED blocks later
# configurations) on: a system dialog (left untouched), input not from this
# harness (a pointer move within 2.5 s of a planned mode change is tolerated:
# WindowServer moves the pointer then), loss of focus, an unplanned display or
# mode change, or SpacesLab exiting. Sends one marked pointer move at the
# start and no other input. Output must not be in a folder macOS protects.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$ROOT/build/spacesctl"
LABEL="$1"; APP="$2"; OUT="$3"; shift 3
[ -x "$C" ] && [ -d "$APP" ] ||
    { echo "usage: displaymode-ab.sh <label> <SpacesLab.app> <outdir> [options]"; exit 1; }
source "$ROOT/outdir.sh"; harness_outdir "$LABEL" "$OUT" >/dev/null || exit 1
[ -e "$OUT/STOPPED" ] && { echo "$OUT/STOPPED exists: an earlier configuration was stopped"; exit 3; }
mkdir -p "$OUT"
P="$OUT/$LABEL"; RES="$P.results.tsv"; LOG="$P.log"; ERR="$P.stderr"; WATCH="$P.watch"; MARKS="$P.marks"
: > "$RES"; : > "$MARKS"

now() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
note() { echo "$(now) $*" >> "$MARKS"; }
labpid() { pgrep -n -f "$APP/Contents/MacOS/SpacesLab"; }
modespec() { "$C" modeinfo | sed -E 's/.*builtin=([^ ]+) px=([^ ]+) hz=([0-9]+).*/\1 \2 \3/'; }
screens() { "$C" modeinfo | sed -E 's/^screens=([0-9]+).*/\1/'; }

# ---- Original mode ------------------------------------------------------------
ORIGFILE="$OUT/original-mode.txt"
if [ ! -e "$ORIGFILE" ]; then
    "$C" modeinfo > "$ORIGFILE" || { echo "cannot read the built-in display's mode"; exit 1; }
fi
ORIGSPEC=$(sed -E 's/.*builtin=([^ ]+) px=([^ ]+) hz=([0-9]+).*/\1 \2 \3/' "$ORIGFILE")
ORIGSIZE=${ORIGSPEC%% *}
[ "$(modespec)" = "$ORIGSPEC" ] || { echo "current mode $(modespec) != recorded original $ORIGSPEC; not starting"; exit 1; }
[ "$(screens)" = 1 ] || { echo "more than one display connected; built-in only"; exit 1; }
grep -q "inset=0 " "$ORIGFILE" && { echo "original mode has no camera housing; not starting"; exit 1; }
read -r _ OPX OHZ <<< "$ORIGSPEC"
OTHER="1512x982 3024x1964 $OHZ"; NOHOUSING="1800x1125 3600x2250 $OHZ"
OTHER_I=$("$C" modeindex $OTHER) && NOHOUSING_I=$("$C" modeindex $NOHOUSING) ||
    { echo "test modes not offered at $OHZ Hz"; exit 1; }

HOLD=""; EXPECT="$ORIGSPEC"; STOPPED=""
restore_mode() {
    if [ -n "$HOLD" ]; then kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""; fi
    local i
    for i in $(seq 1 50); do
        if [ "$(modespec)" = "$ORIGSPEC" ]; then
            echo "RESTORE verified: $ORIGSPEC" | tee -a "$RES"; return 0
        fi
        sleep 0.1
    done
    echo "RESTORE: still $(modespec) after 5 s; restoring the permanent configuration" | tee -a "$RES"
    "$C" restore >> "$RES"; sleep 2
    if [ "$(modespec)" = "$ORIGSPEC" ]; then echo "RESTORE verified after permanent restore: $ORIGSPEC" | tee -a "$RES"
    else echo "RESTORE FAILED: current $(modespec), original $ORIGSPEC" | tee -a "$RES"; return 1; fi
}
cleanup() {
    restore_mode
    [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
    # SpacesLab is left running only when a dialog is on screen (untouched).
    if [ "$STOPPED" != dialog ] && [ -n "$(labpid)" ]; then "$C" cmd lab quit; sleep 1; fi
}
trap cleanup EXIT
trap 'STOPPED=${STOPPED:-signal}; echo "STOPPED: signal" | tee -a "$RES"; exit 130' INT TERM HUP

stop() {   # stop <kind> <why>
    STOPPED="$1"; touch "$OUT/STOPPED"
    echo "STOPPED T${N:-0} ($1): $2" | tee -a "$RES"; exit 2
}
# Input without the harness marker since the run started. flagsChanged is
# derived by WindowServer; a pointer move within 2.5 s after a planned mode
# change is WindowServer moving the pointer to the new geometry.
outside_input() {
    awk -v start="$START" 'NR == FNR { if ($2 == "planned-mode-change") c[n++] = $1; next }
        $1 ~ /^[0-9]+$/ && $1 >= start && $2 != "type=12" {
            if ($2 == "type=5") { for (i = 0; i < n; i++) if ($1 >= c[i] && $1 <= c[i] + 2500) next }
            print }' "$MARKS" "$WATCH" 2>/dev/null | head -3
}
check() {   # check <phase> [focus]: stop on anything not planned
    local a u
    a=$("$C" alerts) || stop dialog "system dialog on screen, left untouched: $a"
    u=$(outside_input); [ -n "$u" ] && stop input "input not from the harness: $(echo "$u" | tr '\n' ' ')"
    [ "$(screens)" = 1 ] || stop display "a display was added"
    [ "$(modespec)" = "$EXPECT" ] || stop display "unplanned mode change: $(modespec), expected $EXPECT"
    [ "$1" = start ] || [ -n "$(labpid)" ] || stop app "SpacesLab exited"
    if [ "${2:-}" = focus ] && [ "$("$C" front)" != SpacesLab ]; then stop focus "frontmost is $("$C" front)"; fi
    return 0
}
diag() {   # the newest DIAG JSON, requested now
    local before; before=$(grep -c "DIAG " "$LOG")
    "$C" cmd lab diag
    for _ in $(seq 1 20); do [ "$(grep -c "DIAG " "$LOG")" -gt "$before" ] && break; sleep 0.05; done
    grep "DIAG " "$LOG" | tail -1 | sed 's/^.*DIAG //'
}
settled() {   # window frame equals the screen frame (or windowed again for exit)
    diag | python3 -I -c 'import json,sys; d=json.load(sys.stdin); w=d["windowFrame"]; s=d.get("screenFrame",{})
sys.exit(0 if all(abs(w[k]-s.get(k,-9))<0.5 for k in ("x","y","width","height")) else 1)'
}
SPACE1=""
sample() {   # sample <name> <kind> <expected size>
    local s band="" shown space line rc
    s=$("$C" space "$(labpid)"); shown=$(echo "$s" | sed -E 's/.*shown=([01]).*/\1/'); space=$(echo "$s" | sed -E 's/.*space=([0-9]+).*/\1/')
    [ "$2" = housing ] && band=$("$C" band "$P-T$N" | tr -d '\n')
    line=$(diag | python3 -I "$ROOT/dmcheck.py" "$2" "$3" "${SPACE1:--}" "$band" "$shown" "$space"); rc=$?
    printf "%s\tT%d\t%s\t%s\n" "$LABEL" "$N" "$1" "$line" | tee -a "$RES"
    [ -z "$SPACE1" ] && [ "$2" != exit ] && SPACE1=$space
    return $rc
}
change_mode() {   # change_mode <spec> <index>: hold it, wait until it applies and the window follows
    EXPECT="$1"; note planned-mode-change "$1"
    "$C" modehold "$2" 40 >> "$P.hold" 2>&1 & HOLD=$!
    for _ in $(seq 1 50); do [ "$(modespec)" = "$EXPECT" ] && break; sleep 0.1; done
    note mode-applied "$(modespec)"
    note planned-mode-change "settle"
    for _ in $(seq 1 30); do settled && break; sleep 0.2; done
    sleep 1
}
revert_mode() {
    EXPECT="$ORIGSPEC"; note planned-mode-change revert
    kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""
    for _ in $(seq 1 50); do [ "$(modespec)" = "$EXPECT" ] && break; sleep 0.1; done
    note mode-applied "$(modespec)"
    note planned-mode-change "settle"
    for _ in $(seq 1 30); do settled && break; sleep 0.2; done
    sleep 1
}

# ---- Run ----------------------------------------------------------------------
pkill -f "SpacesLab.app/Contents/MacOS/SpacesLab"; sleep 1
"$C" watch "$WATCH" & WPID=$!
sleep 0.5
head -1 "$WATCH" 2>/dev/null | grep -q "access=1" || { echo "input watch unavailable; not starting"; exit 1; }
BIN="$APP/Contents/MacOS/SpacesLab"
LABMODE="${LABMODE:-fpwindow}"
echo "== $LABEL ($LABMODE $*) $(date '+%H:%M:%S') binary=$(shasum -a 256 "$BIN" | cut -c1-16) original=[$ORIGSPEC] other=#$OTHER_I nohousing=#$NOHOUSING_I" | tee -a "$RES"
START=$(now); N=0
check start
"$C" move 900 620   # the only synthetic input: keep the pointer off the top edge

N=1; note T1 entry
open -n --stderr "$ERR" "$APP" --args -mode "$LABMODE" -tag lab -log "$LOG" -autoFS YES -FullPanelTrace YES "$@"
for _ in $(seq 1 40); do [ -n "$(labpid)" ] && break; sleep 0.2; done
"$C" waitshown "$(labpid)" 1 8000 > /dev/null; sleep 1.5
grep -q "launched active=0" "$LOG" && stop focus "SpacesLab launched inactive"
check T1 focus
sample entry housing "$ORIGSIZE"

N=2; note T2 other-housing; check T2 focus
change_mode "$OTHER" "$OTHER_I"; check T2 focus
sample other-housing housing "${OTHER%% *}"

N=3; note T3 revert; check T3 focus
revert_mode; check T3 focus
sample revert housing "$ORIGSIZE"

N=4; note T4 no-housing; check T4 focus
change_mode "$NOHOUSING" "$NOHOUSING_I"; check T4 focus
sample no-housing nohousing "${NOHOUSING%% *}"

N=5; note T5 revert; check T5 focus
revert_mode; check T5 focus
sample revert housing "$ORIGSIZE"

N=6; note T6 exit; check T6 focus
"$C" cmd lab exit
"$C" waitshown "$(labpid)" 0 5000 > /dev/null
for _ in $(seq 1 25); do diag | grep -q '"nativeFullscreenStyleMask":false' && break; sleep 0.2; done
sleep 1; check T6 focus
sample exit exit "800x500"

awk -F'\t' -v l="$LABEL" '$2 ~ /^T[0-9]/ { n++; if ($4 == "PASS") p++; else f++ }
    END { printf "%s: %d transitions attempted: %d PASS, %d FAIL\n", l, n, p, f }' "$RES" | tee -a "$RES"
