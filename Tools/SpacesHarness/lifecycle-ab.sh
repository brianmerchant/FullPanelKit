#!/bin/bash
# Lifecycle checks of FullPanel geometry with FullPanelSession on an AppKit
# subclass (SpacesLab -mode session): one scenario, one option set, at most 10
# transitions, each attempted once.
#
#   ./lifecycle-ab.sh <label> <scenario> <SpacesLab.app> <outdir> [-Option value ...]
#
#   p2      attach + enable inside willEnterFullScreen (P2: an entry the engine
#           was not told about). T1 entry, T2 exit, T3 entry, T4 exit.
#           Set EXPECT_PREPARED to the path expected at T1 (default
#           reservationRequest).
#   multi   a second window in the same process (SECOND=control: unattached,
#           SECOND=session: attached). T1 lab entry, T2 second entry, T3 lab
#           front, T4 second front, T5 second exit, T6 lab front, T7 detach the
#           lab in fullscreen, T8 Space keys away and back, T9 lab exit.
#   reveal  top-edge menu-bar reveal. T1 entry, T2 reveal, T3 hide, T4 reveal,
#           T5 hide, T6 exit.
#   fallback  without the reservation methods (pass
#           -FullPanelSimulateNoReservation YES): T1 entry must be ordinary
#           fullscreen with fallback reason AppKitUnavailable, T2 exit.
#   split   Split View with an unattached second window, starting windowed.
#           T1 the lab tiles left (AppKit's tile action) and the second window
#           is picked by title in the picker: the lab's entry is rejected (P1),
#           AppKit's tile layout, band black; T2 the lab exits, windowed at its
#           size; T3 the second window exits; T4 FullPanel entry again; T5
#           top-edge reveal; T6 hide; T7 exit.
#   detach  T1 entry, T2 detach in fullscreen, T3 exit: the windowed frame is
#           recorded (EXPECT_SIZE judges it when set).
#   lock | wake   ATTENDED ONLY. T1 entry; T2 the harness locks the screen
#           (Control-Command-Q) or puts the Mac to sleep (pmset sleepnow) and
#           waits up to 5 minutes for a person to unlock / wake it; input in
#           that window is the person's and is not judged. 3 s after the
#           unlock: FullPanel again; T3 top-edge reveal; T4 hide; T5 exit.
#
# Each transition is judged by lccheck.py from SpacesLab's DIAG / DIAG2 and the
# band beside the housing. Stops at once (STOPPED, never FAIL; <outdir>/STOPPED
# blocks later configurations) on a system dialog (left untouched), input not
# from this harness, loss of focus while a lab window should be key, a display
# change, or SpacesLab exiting. Synthetic input: marked pointer moves (reveal),
# Control-arrow Space keys (multi T8). Changes no setting. Output must not be
# in a folder macOS protects (outdir.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$ROOT/build/spacesctl"
LABEL="$1"; SCENARIO="$2"; APP="$3"; OUT="$4"; shift 4
[ -x "$C" ] && [ -d "$APP" ] && [[ "$SCENARIO" =~ ^(p2|multi|reveal|fallback|split|detach|lock|wake)$ ]] ||
    { echo "usage: lifecycle-ab.sh <label> <p2|multi|reveal|fallback|split|detach|lock|wake> <SpacesLab.app> <outdir> [options]"; exit 1; }
source "$ROOT/outdir.sh"; harness_outdir "$LABEL" "$OUT" >/dev/null || exit 1
[ -e "$OUT/STOPPED" ] && { echo "$OUT/STOPPED exists: an earlier configuration was stopped"; exit 3; }
mkdir -p "$OUT"
P="$OUT/$LABEL"; RES="$P.results.tsv"; LOG="$P.log"; ERR="$P.stderr"; WATCH="$P.watch"
: > "$RES"; : > "$LOG"; : > "$P.clicks"

now() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
labpid() { pgrep -n -f "$APP/Contents/MacOS/SpacesLab"; }
screens() { "$C" modeinfo | sed -E 's/^screens=([0-9]+).*/\1/'; }
STOPPED=""
cleanup() {
    [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
    if [ "$STOPPED" != dialog ] && [ -n "$(labpid)" ]; then "$C" cmd lab quit; sleep 1; fi
}
trap cleanup EXIT
trap 'STOPPED=${STOPPED:-signal}; echo "STOPPED: signal" | tee -a "$RES"; exit 130' INT TERM HUP
stop() { STOPPED="$1"; touch "$OUT/STOPPED"; echo "STOPPED T${N:-0} ($1): $2" | tee -a "$RES"; exit 2; }
# Input without the harness marker since the start (flagsChanged is derived),
# except between MANUAL_FROM and MANUAL_TO: a person unlocking or waking the Mac.
# A pointer move at exactly the point of a harness click within 1 s is
# re-posted by the system (AXVisualSupportAgent, macOS 27.0.1) without the
# marker; clicks are recorded in $P.clicks.
MANUAL_FROM=0; MANUAL_TO=0
outside_input() {
    awk -v start="$START" -v mf="$MANUAL_FROM" -v mt="$MANUAL_TO" '
        FILENAME == ARGV[1] { ct[n+0] = $1; cx[n+0] = $2; cy[n+0] = $3; n++; next }
        $1 ~ /^[0-9]+$/ && $1 >= start && $2 != "type=12" && !($1 >= mf && $1 <= mt) {
            if ($2 == "type=5") for (i = 0; i < n; i++)
                if ($1 >= ct[i] && $1 <= ct[i] + 1000 && $4 == "x=" cx[i] && $5 == "y=" cy[i]) next
            print }' "$P.clicks" "$WATCH" 2>/dev/null | head -3
}
click() { check; echo "$(now) $1 $2" >> "$P.clicks"; "$C" click "$1" "$2"; }
check() {   # check [focus]
    local a u
    a=$("$C" alerts) || stop dialog "system dialog on screen, left untouched: $a"
    u=$(outside_input); [ -n "$u" ] && stop input "input not from the harness: $(echo "$u" | tr '\n' ' ')"
    [ "$(screens)" = 1 ] || stop display "a display was added or removed"
    [ -n "$(labpid)" ] || stop app "SpacesLab exited"
    if [ "${1:-}" = focus ] && [ "$("$C" front)" != SpacesLab ]; then stop focus "frontmost is $("$C" front)"; fi
    return 0
}
act() { check; "$C" "$@"; }
diag() {   # diag <diag|diag2>: the newest JSON line of that kind, requested now
    local tag="DIAG "; [ "$1" = diag2 ] && tag="DIAG2 "
    local before; before=$(grep -c "^.*$tag" "$LOG")
    "$C" cmd lab "$1"
    for _ in $(seq 1 20); do [ "$(grep -c "^.*$tag" "$LOG")" -gt "$before" ] && break; sleep 0.05; done
    grep "$tag" "$LOG" | tail -1 | sed "s/^.*$tag//"
}
waitfs() {   # waitfs <diag|diag2> <true|false>: until the window's fullscreen style is that
    for _ in $(seq 1 40); do diag "$1" | grep -q "\"labFullScreen\":$2" && return 0; sleep 0.2; done
    return 1
}
N=0
sample() {   # sample <name> <diag|diag2> <kind> <expect>
    local band="" line
    [ "$3" != windowed ] && band=$("$C" band "$P-T$N" | tr -d '\n')
    line=$(diag "$2" | python3 -I "$ROOT/lccheck.py" "$3" "$band" "$4")
    printf "%s\tT%d\t%s\t%s\n" "$LABEL" "$N" "$1" "$line" | tee -a "$RES"
}
step() { N=$((N + 1)); echo "$(now) MARK T$N $1" >> "$LOG"; }

# ---- Run ------------------------------------------------------------------------
pkill -f "SpacesLab.app/Contents/MacOS/SpacesLab"; sleep 1
"$C" watch "$WATCH" & WPID=$!
sleep 0.5
head -1 "$WATCH" 2>/dev/null | grep -q "access=1" || { echo "input watch unavailable; not starting"; exit 1; }
[ "$(screens)" = 1 ] || { echo "more than one display connected; built-in only"; exit 1; }
BIN="$APP/Contents/MacOS/SpacesLab"
EXTRA=()
case "$SCENARIO" in
    p2) EXTRA=(-attachAt willEnter) ;;
    multi) EXTRA=(-second "${SECOND:-control}") ;;
    split) EXTRA=(-second control) ;;
esac
AUTOFS=YES; [ "$SCENARIO" = split ] && AUTOFS=NO
echo "== $LABEL ($SCENARIO ${EXTRA[*]:-} $*) $(date '+%H:%M:%S') binary=$(shasum -a 256 "$BIN" | cut -c1-16)" | tee -a "$RES"
START=$(now)
a=$("$C" alerts) || { echo "a system dialog is on screen; not starting: $a"; exit 1; }
"$C" move 900 620   # marked; keeps the pointer off the top edge

step entry
open -n --stderr "$ERR" "$APP" --args -mode session -tag lab -log "$LOG" -autoFS "$AUTOFS" -FullPanelTrace YES ${EXTRA[@]+"${EXTRA[@]}"} "$@"
for _ in $(seq 1 40); do [ -n "$(labpid)" ] && break; sleep 0.2; done
"$C" waitshown "$(labpid)" 1 8000 > /dev/null; sleep 1.5
grep -q "launched active=0" "$LOG" && stop focus "SpacesLab launched inactive"
check focus
case "$SCENARIO" in
split)
    sample windowed diag windowed "size=800x500"
    step split-entry; "$C" cmd lab tileLeft; sleep 2.5; check focus
    "$C" wincenter "SpacesLab lab-2" > "$P.picker" || stop app "second window not in the Split View picker"
    read -r PX PY _ < "$P.picker"; click "$PX" "$PY"; waitfs diag2 true; sleep 2.5; check focus
    sample split-lab diag tile "entryRejected=True,geometry=reservation,frameAccepted=False"
    sample split-second diag2 tile "sessionAttached=False"
    step split-exit; "$C" cmd lab exit; waitfs diag false; sleep 1.5; check focus
    sample lab-windowed diag windowed "size=800x500"
    step second-exit; "$C" cmd lab front2; sleep 0.5; "$C" cmd lab exit2; waitfs diag2 false; sleep 1.5; check
    sample second-windowed diag2 windowed -
    step re-entry; "$C" cmd lab front; sleep 0.5; "$C" cmd lab enter; waitfs diag true; sleep 2; check focus
    sample re-entry diag fp "geometry=reservation,entryRejected=False"
    step reveal; act move 900 0; sleep 0.3; act move 901 0; sleep 1.5; check focus
    sample reveal diag revealed "geometry=reservation"
    step hide; act move 900 620; sleep 2.0; check focus
    sample hide diag fp "geometry=reservation"
    step exit; "$C" cmd lab exit; waitfs diag false; sleep 1; check focus
    sample exit diag windowed "size=800x500"
    ;;
detach)
    sample entry diag fp "geometry=${GEOMETRY:-reservation}"
    step detach; "$C" cmd lab detach; sleep 1.5; check focus
    sample detach diag detached -
    step exit; "$C" cmd lab exit; waitfs diag false; sleep 1.5; check focus
    sample exit diag windowed "${EXPECT_SIZE:+size=$EXPECT_SIZE}${EXPECT_SIZE:--}"
    ;;
lock|wake)
    sample entry diag fp "geometry=reservation"
    step "$SCENARIO"; check focus
    if [ "$SCENARIO" = lock ]; then WANT="com.apple.screenIsUnlocked"; else WANT="NSWorkspaceDidWakeNotification"; fi
    BEFORE=$(grep -c "EV $WANT" "$LOG")
    MANUAL_FROM=$(now); MANUAL_TO=$((MANUAL_FROM + 330000))
    if [ "$SCENARIO" = lock ]; then "$C" key 12 cmd ctrl; else pmset sleepnow > /dev/null; fi
    for _ in $(seq 1 600); do [ "$(grep -c "EV $WANT" "$LOG")" -gt "$BEFORE" ] && break; sleep 0.5; done
    [ "$(grep -c "EV $WANT" "$LOG")" -gt "$BEFORE" ] || stop manual "no $WANT within 5 minutes"
    if [ "$SCENARIO" = wake ]; then   # the unlock follows the wake when a password is required
        for _ in $(seq 1 240); do grep -q "EV com.apple.screenIsUnlocked" "$LOG" && break; sleep 0.5; done
    fi
    sleep 3; MANUAL_TO=$(now); check focus
    sample "after-$SCENARIO" diag fp "geometry=reservation"
    step reveal; act move 900 0; sleep 0.3; act move 901 0; sleep 1.5; check focus
    sample reveal diag revealed "geometry=reservation"
    step hide; act move 900 620; sleep 2.0; check focus
    sample hide diag fp "geometry=reservation"
    step exit; "$C" cmd lab exit; waitfs diag false; sleep 1; check focus
    sample exit diag windowed -
    ;;
p2)
    sample entry diag fp "geometry=${GEOMETRY:-reservation},entryPreparedBy=${EXPECT_PREPARED:-reservationRequest}"
    step exit; "$C" cmd lab exit; waitfs diag false; sleep 1; check focus
    sample exit diag windowed -
    step re-entry; "$C" cmd lab enter; waitfs diag true; sleep 2; check focus
    sample re-entry diag fp "geometry=${GEOMETRY:-reservation},entryPreparedBy=willEnterFullScreen"
    step exit; "$C" cmd lab exit; waitfs diag false; sleep 1; check focus
    sample exit diag windowed -
    ;;
multi)
    sample lab-entry diag fp "geometry=reservation"
    if [ "${SECOND:-control}" = control ]; then K2=native; X2="sessionAttached=False"; else K2=fp; X2="geometry=reservation"; fi
    step second-entry; "$C" cmd lab front2; sleep 0.5; "$C" cmd lab enter2; waitfs diag2 true; sleep 2; check focus
    sample second-entry diag2 "$K2" "$X2"
    step lab-front; "$C" cmd lab front; sleep 2.5; check focus
    sample lab-front diag fp "geometry=reservation"
    step second-front; "$C" cmd lab front2; sleep 2.5; check focus
    sample second-front diag2 "$K2" "$X2"
    step second-exit; "$C" cmd lab exit2; waitfs diag2 false; sleep 1.5; check
    sample second-exit diag2 windowed -
    step lab-front; "$C" cmd lab front; sleep 2.5; check focus
    sample lab-front diag fp "geometry=reservation"
    step detach; "$C" cmd lab detach; sleep 1.5; check focus
    sample detach diag detached -
    step space-keys; act key 123 ctrl fn; "$C" waitshown "$(labpid)" 0 3000 > /dev/null; sleep 0.8
    act key 124 ctrl fn; "$C" waitshown "$(labpid)" 1 3000 > /dev/null; sleep 1.5; check focus
    sample space-keys-after-detach diag detached -
    step exit; "$C" cmd lab exit; waitfs diag false; sleep 1; check focus
    sample exit diag windowed -
    ;;
reveal)
    sample entry diag fp "geometry=reservation"
    for i in 1 2; do
        step reveal; act move 900 0; sleep 0.3; act move 901 0; sleep 1.5; check focus
        sample reveal diag revealed "geometry=reservation"
        step hide; act move 900 620; sleep 2.0; check focus
        sample hide diag fp "geometry=reservation"
    done
    step exit; "$C" cmd lab exit; waitfs diag false; sleep 1; check focus
    sample exit diag windowed -
    ;;
fallback)
    sample entry diag native "state=3,fallbackReason=2,geometry=none,frameAccepted=False"
    step exit; "$C" cmd lab exit; waitfs diag false; sleep 1; check focus
    sample exit diag windowed -
    ;;
esac
awk -F'\t' -v l="$LABEL" '$2 ~ /^T[0-9]/ { n++; if ($4 == "PASS") p++; else f++ }
    END { printf "%s: %d transitions attempted: %d PASS, %d FAIL\n", l, n, p, f }' "$RES" | tee -a "$RES"
