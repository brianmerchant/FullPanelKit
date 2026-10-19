#!/bin/bash
# Bounded A/B/C comparison: one SpacesLab build and option set through a fixed
# sequence of exactly 10 fullscreen transitions, with waits on the observed
# Space state instead of fixed sleeps, and a watch for input that did not come
# from this harness.
#
#   ./abc.sh <label> <SpacesLab.app> <outdir> <mode> [-Option YES ...]
#     mode: fpwindow (FullPanelWindow) or control (native fullscreen)
#
# Transitions (each one is counted, attempted once, never retried):
#   T1  entry          windowed -> fullscreen (-autoFS)
#   T2-T3 mc-thumb     Mission Control, click the Space's small thumbnail
#   T4-T5 mc-swipe-large  from the Space to the left: Mission Control there,
#                      Control-Right inside it to the lab's Space (stand-in for
#                      a trackpad swipe, which cannot be synthesized), click
#                      the lab window's large preview (found through the
#                      Dock's accessibility tree; screen centre as fallback)
#   T6  space-keys     Control-Left away, Control-Right back (keyboard Space
#                      switch; a trackpad swipe cannot be synthesized)
#   T7  finder-cmdtab  activate Finder, Command-Tab back
#   T8  dock           Control-Left away, Finder active, Dock item pressed (AX)
#   T9  cmdtab-away    Control-Left away, Finder active, Command-Tab back
#   T10 exit           fullscreen -> windowed
#
# Classification per transition:
#   PASS / FAIL       the outcome, when nothing else interfered
#   CONTAMINATED      input without the harness marker arrived during it
#                     (spacesctl watch); never counted as a product result
#   HARNESS           a precondition did not hold (e.g. Mission Control did
#                     not open, the lab was not shown or not frontmost)
#   INVALID           a permission prompt or other system dialog was on screen
#                     (spacesctl alerts). The harness sends no further input,
#                     never dismisses it, writes <outdir>/INVALID and stops;
#                     the whole configuration is invalid, not a product result.
# Every synthetic input goes through `act`, which checks for such dialogs
# first. Escape is sent only to close Mission Control (spacesctl mcstate).
# Output must not be in a folder macOS protects (outdir.sh): SpacesLab writes
# its log there and would trigger a Files and Folders prompt.
# Two CONTAMINATED transitions stop the run (the Mac is in use). `touch
# <outdir>/STOP` stops after the current transition. Changes no setting;
# requests no permission (without event-tap access, detection is reported as
# unavailable and every result is marked UNWATCHED).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$ROOT/build/spacesctl"
LABEL="$1"; APP="$2"; OUT="$3"; MODE="$4"; shift 4
[ -x "$C" ] && [ -d "$APP" ] || { echo "usage: abc.sh <label> <SpacesLab.app> <outdir> <mode> [options]; build first"; exit 1; }
source "$ROOT/outdir.sh"; harness_outdir "$LABEL" "$OUT" >/dev/null || exit 1
[ -e "$OUT/INVALID" ] && { echo "$OUT/INVALID exists: an earlier configuration was interrupted by a dialog"; exit 3; }
mkdir -p "$OUT"
P="$OUT/$LABEL"
RES="$P.results.tsv"; LOG="$P.log"; ERR="$P.stderr"; WATCH="$P.watch"
now() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
labpid() { pgrep -n -f "$APP/Contents/MacOS/SpacesLab"; }
shown() { "$C" space "$(labpid)" | sed -E 's/.*shown=([01]).*/\1/'; }
front() { "$C" front; }
INVALID=""
ui_ok() {      # no permission prompt or system alert on screen; otherwise the run is INVALID
    [ -n "$INVALID" ] && return 1
    local a; a=$("$C" alerts) && return 0
    INVALID="$a"; echo "$a" > "$OUT/INVALID"
    echo "INVALID T$N: system dialog on screen; no further input sent: $a" | tee -a "$RES"
    return 1
}
act() { ui_ok && "$C" "$@"; }   # every synthetic input goes through here
escape_mc() {  # Escape only to close an open Mission Control, never at a dialog
    ui_ok || return 1
    if "$C" mcstate | grep -q "open=1"; then "$C" key 53
    else echo "no Escape sent: Mission Control not open" >> "$LOG"; fi
}
center() { act move 900 620; }
unmarked() {   # unmarked <from ms> <to ms>: input events not posted by the harness
    # flagsChanged (type 12) is left out: WindowServer derives it from the
    # harness's own Command-key events without carrying the marker.
    awk -v a="$1" -v b="$2" '$1 ~ /^[0-9]+$/ && $1 >= a && $1 <= b && $2 != "type=12"' "$WATCH" 2>/dev/null | wc -l | tr -d ' '
}
thumb() {
    act move 900 4; sleep 1.0
    local s; s=$("$C" space "$(labpid)")
    read -r x y <<< "$("$C" bar builtin "$(echo "$s" | sed -E 's/.*count=([0-9]+).*/\1/')" \
                                         "$(echo "$s" | sed -E 's/.*index=([0-9]+).*/\1/')")"
    act click "$x" "$y"
}
# Settled sample 1.2 s after the return: band teal, frame, front app.
settle() {
    sleep 1.2; center; sleep 0.2
    BAND=$("$C" band "$P-T$N" | tr -d '\n')
    "$C" cmd lab dump; sleep 0.3
    FRAME=$(grep "after dump" "$LOG" | tail -1 | sed -E 's/.* fr=(\{\{[^}]*\}, \{[^}]*\}\}).*/\1/')
    STATE=$(grep "after dump" "$LOG" | tail -1 | grep -oE 'fp\{state=[0-9]+' | sed 's/fp{//')
    FRONT=$(front)
}
band_ok() {    # FullPanel: teal >= 0.90 both sides; control: <= 0.05
    local l r; l=$(echo "$BAND" | sed -E 's/.*left=([0-9.]+).*/\1/'); r=$(echo "$BAND" | sed -E 's/.*right=([0-9.]+).*/\1/')
    if [ "$MODE" = control ]; then awk -v l="$l" -v r="$r" 'BEGIN{exit !(l<=0.05 && r<=0.05)}'
    else awk -v l="$l" -v r="$r" 'BEGIN{exit !(l>=0.90 && r>=0.90)}'; fi
}
CONTAMINATED=0; N=0
record() {     # record <name> <outcome> <detail>; uses T0 and the settled sample
    local t1 u outcome="$2"; t1=$(now); u=$(unmarked "$T0" "$t1")
    if [ -n "$INVALID" ]; then outcome="INVALID($2)"
    elif [ "$WATCHING" = 0 ]; then outcome="$outcome/UNWATCHED"
    elif [ "$u" -gt 0 ]; then outcome="CONTAMINATED($2)"; CONTAMINATED=$((CONTAMINATED + 1)); fi
    printf "%s\tT%d\t%s\t%s\t%s\tband[%s]\tframe=%s\t%s\tfront=%s\tunmarked=%s\n" \
        "$LABEL" "$N" "$1" "$outcome" "$3" "${BAND:-}" "${FRAME:-}" "${STATE:-}" "${FRONT:-}" "$u" | tee -a "$RES"
}
begin() { N=$((N + 1)); T0=$(now); BAND=""; FRAME=""; STATE=""; FRONT=""; "$C" cmd lab dump >/dev/null; echo "MARK T$N $1 $T0" >> "$LOG"; }
stop_requested() { [ -e "$OUT/STOP" ] || [ "$CONTAMINATED" -ge 2 ] || [ -n "$INVALID" ]; }
returned() {   # returned <name> <wait output>: classify a return to the lab's Space
    if [[ "$2" == ok* ]]; then
        settle
        if [ "$MODE" != control ] && ! band_ok; then record "$1" FAIL "returned ${2#ok }ms; band"
        elif [ "$MODE" = control ] && ! band_ok; then record "$1" FAIL "returned ${2#ok }ms; control band not black"
        elif [ "$FRONT" != SpacesLab ]; then record "$1" FAIL "returned ${2#ok }ms; lab not frontmost"
        else record "$1" PASS "returned ${2#ok }ms"; fi
    else
        BAND=""; FRONT=$(front)
        if ! ui_ok; then record "$1" INVALID "system dialog on screen; not returned (${2})"; return; fi
        record "$1" FAIL "not returned (${2}); shown=$(shown)"
        # One recovery attempt, outside the counted transition: Escape, only
        # if Mission Control is open, closes it back to the Space it opened from.
        escape_mc && { "$C" waitshown "$(labpid)" 1 3000 >> "$LOG" || echo "RECOVERY failed" | tee -a "$RES"; }
    fi
}

pkill -f "SpacesLab.app/Contents/MacOS/SpacesLab"; sleep 1
: > "$RES"; : > "$LOG"; rm -f "$OUT/STOP"
"$C" watch "$WATCH" & WPID=$!
sleep 0.5
WATCHING=1; head -1 "$WATCH" 2>/dev/null | grep -q "access=1" || WATCHING=0
trap 'kill $WPID 2>/dev/null' EXIT
echo "== $LABEL ($MODE $*) watch=$WATCHING $(date '+%H:%M:%S')" | tee -a "$RES"

# Start only after 5 s without outside input (at most 60 s): the hand that
# started the run may still be on the trackpad.
if [ "$WATCHING" = 1 ]; then
    for i in $(seq 1 60); do
        t=$(now); [ "$(unmarked $((t - 5000)) "$t")" = 0 ] && [ "$i" -gt 5 ] && break
        sleep 1
    done
    echo "quiet before T1 after ${i}s" >> "$LOG"
fi

# T1 entry
begin entry
open -n --stderr "$ERR" "$APP" --args -mode "$MODE" -tag lab -log "$LOG" -autoFS YES -FullPanelTrace YES "$@"
sleep 1.5
for _ in $(seq 1 40); do [ -n "$(labpid)" ] && break; sleep 0.2; done
# A script-launched app can stay inactive, and macOS then never shows the
# Space it enters. Activate it by bundle path (never by bundle ID: other
# builds share it) and record that this was needed.
W=$("$C" waitshown "$(labpid)" 1 4000)
if [[ "$W" != ok* ]] && grep -q "launched active=0" "$LOG"; then
    if ui_ok; then
        echo "NOTE T1: lab launched inactive; activated by path" | tee -a "$RES"
        open "$APP"; W=$("$C" waitshown "$(labpid)" 1 4000)
    fi
fi
returned entry "$W"

for name in mc-thumb mc-thumb; do
    stop_requested && break
    begin "$name"
    if [ "$(shown)" != 1 ]; then BAND=""; record "$name" HARNESS "lab not shown before the step"; escape_mc; sleep 1.5; continue; fi
    ui_ok && open -a "Mission Control"
    if ! "$C" waitshown "$(labpid)" 0 3000 >/dev/null; then
        record "$name" HARNESS "Mission Control did not open"; continue
    fi
    echo "MCSTATE T$N $("$C" mcstate)" >> "$LOG"   # checks the open-state rule
    sleep 0.6; thumb
    returned "$name" "$("$C" waitshown "$(labpid)" 1 3000)"
done

for name in mc-swipe-large mc-swipe-large; do
    stop_requested && break
    begin "$name"
    if [ "$(shown)" != 1 ]; then BAND=""; record "$name" HARNESS "lab not shown before the step"; escape_mc; sleep 1.5; continue; fi
    act key 123 ctrl fn
    if ! "$C" waitshown "$(labpid)" 0 3000 >/dev/null; then record "$name" HARNESS "Control-Left did not leave the Space"; continue; fi
    sleep 0.8; ui_ok && open -a "Mission Control"
    if ! "$C" waitmc 1 3000 >/dev/null; then
        echo "MCSTATE T$N $("$C" mcstate)" >> "$LOG"
        record "$name" HARNESS "Mission Control open state not detected"; escape_mc; sleep 1.5; continue
    fi
    sleep 0.6; act key 124 ctrl fn   # inside Mission Control: to the lab's Space
    if ! "$C" waitshown "$(labpid)" 1 3000 >/dev/null; then
        record "$name" HARNESS "Control-Right in Mission Control did not reach the lab's Space"; escape_mc; sleep 1.5; continue
    fi
    sleep 0.8
    POS=$("$C" mcwindow "SpacesLab lab"); echo "MCWINDOW T$N $POS" >> "$LOG"
    read -r x y _ <<< "$POS"
    act click "$x" "$y"
    W=$("$C" waitmc 0 3000)
    if [[ "$W" == ok* ]] && [ "$(shown)" = 1 ]; then returned "$name" "ok ${W#ok } (preview: ${POS#* * })"
    else returned "$name" "click ignored: Mission Control still open (${W}; preview: ${POS#* * })"; fi
done

if ! stop_requested; then
    begin space-keys
    act key 123 ctrl fn
    if "$C" waitshown "$(labpid)" 0 3000 >/dev/null; then
        sleep 0.8; act key 124 ctrl fn
        returned space-keys "$("$C" waitshown "$(labpid)" 1 3000)"
    else record space-keys HARNESS "Control-Left did not leave the Space"; fi
fi

if ! stop_requested; then
    begin finder-cmdtab
    act activate com.apple.finder >> "$LOG"; sleep 1.5
    F=$(front)
    if [ "$F" != Finder ]; then record finder-cmdtab HARNESS "Finder not frontmost ($F)"
    else
        act cmdtab 1
        returned finder-cmdtab "$("$C" waitshown "$(labpid)" 1 3000)"
    fi
fi

for name in dock cmdtab-away; do
    stop_requested && break
    begin "$name"
    act key 123 ctrl fn
    if ! "$C" waitshown "$(labpid)" 0 3000 >/dev/null; then record "$name" HARNESS "Control-Left did not leave the Space"; continue; fi
    sleep 0.8; act activate com.apple.finder >> "$LOG"; sleep 1.2
    if [ "$(shown)" = 1 ]; then record "$name" HARNESS "activating Finder returned to the lab's Space"; continue; fi
    if [ "$name" = dock ]; then act dock SpacesLab >> "$LOG"; else act cmdtab 1; fi
    returned "$name" "$("$C" waitshown "$(labpid)" 1 3000)"
done

if ! stop_requested; then
    begin exit
    "$C" cmd lab exit
    if "$C" waitshown "$(labpid)" 0 5000 >/dev/null; then
        sleep 1.5; "$C" cmd lab dump; sleep 0.3
        FRAME=$(grep "after dump" "$LOG" | tail -1 | sed -E 's/.* fr=(\{\{[^}]*\}, \{[^}]*\}\}).*/\1/')
        STATE=$(grep "after dump" "$LOG" | tail -1 | grep -oE 'fp\{state=[0-9]+' | sed 's/fp{//'); FRONT=$(front)
        if [[ "$FRAME" == *"{800, 500}"* ]]; then record exit PASS "windowed again"
        else record exit FAIL "windowed frame not restored"; fi
    else record exit FAIL "still in its fullscreen Space"; fi
fi

if [ -n "$INVALID" ]; then
    echo "RUN INVALID: a system dialog appeared; it was left untouched and SpacesLab was left running. Results above are not product results." | tee -a "$RES"
else
    "$C" cmd lab quit; sleep 1.5
fi
[ "$CONTAMINATED" -ge 2 ] && echo "STOPPED: input from outside the harness in $CONTAMINATED transitions (Mac in use?)" | tee -a "$RES"
[ -e "$OUT/STOP" ] && echo "STOPPED: $OUT/STOP" | tee -a "$RES"
awk -F'\t' -v l="$LABEL" '$2 ~ /^T/ { n++; o=$4; sub(/\/UNWATCHED/, "", o)
        if (o=="PASS") p++; else if (o=="FAIL") f++; else if (o ~ /^CONTAMINATED/) c++; else if (o ~ /^INVALID/) v++; else h++ }
    END { printf "%s: %d transitions attempted: %d PASS, %d FAIL, %d CONTAMINATED, %d HARNESS, %d INVALID\n", l, n, p, f, c, h, v }' "$RES" | tee -a "$RES"
