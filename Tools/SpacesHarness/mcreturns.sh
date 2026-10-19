#!/bin/bash
# Mission Control returns only: one SpacesLab build and option set, a fullscreen
# entry, exactly 10 Mission Control returns, an exit. For comparing one
# mechanism at a time (presentation forcing, titlebar handling) on the same
# build, and native fullscreen as the control.
#
#   ./mcreturns.sh <label> <SpacesLab.app> <outdir> <mode> [-Option YES ...]
#     mode: fpwindow, session or control (native fullscreen)
#
# Return routes (fixed order R1..R10; each attempted once, never retried):
#   thumb       Mission Control opened in the lab's Space; the pointer rests on
#               the large preview for 0.6 s, then at the top edge for 1 s
#               (the Spaces bar expands), then clicks the Space's own small
#               thumbnail. The route of the archived ignored clicks
#               (missioncontrol.sh "large-thumb").
#   away-thumb  Control-Left to the Desktop, Finder activated there, Mission
#               Control opened there, click the lab Space's thumbnail. The
#               archived context: the first returns after another app's Space.
#   large       Control-Left to the Desktop, Mission Control opened there,
#               Control-Right inside it to the lab's Space, click the lab
#               window's large preview (found in the Dock's accessibility tree
#               when exposed; on macOS 27.0.1 it is not, and the display's
#               centre is clicked, which returns natively too). abc.sh's
#               mc-swipe-large route.
# Order: thumb, away-thumb, large, thumb, away-thumb, large, thumb,
# away-thumb, thumb, large (4 thumb, 3 away-thumb, 3 large).
# MC_ROUTES="<10 routes>" replaces that order (still exactly 10 returns).
#
# MC_STOP_ON_FAIL=1 (campaign mode, mccampaign.sh): a FAIL stops the run as a
# suspected product failure (STOPPED product) after recording the evidence,
# with no recovery input; on any stop the harness then sends no input at all
# and leaves Mission Control and SpacesLab as they are for inspection.
#
# Every click inside Mission Control is sent only after Mission Control is
# verified open (spacesctl waitmc). A return is PASS when Mission Control
# closed, the lab's Space is shown, SpacesLab is frontmost with its window key
# and, for FullPanel, the band beside the housing is teal (>= 0.90); for the
# control, black. A return that does not happen within 3 s is FAIL; its
# Mission Control state, the Dock's windows and the top of the display are
# recorded, then Escape (only while Mission Control is open) recovers once,
# outside the count. If the lab cannot be recovered, the run stops.
#
# Stops at once (STOPPED, never a product result; <outdir>/STOPPED blocks later
# configurations) on: a permission prompt or other system dialog (left
# untouched), any input that does not carry the harness marker (flagsChanged
# is derived and ignored; a pointer move re-posted at a harness click point
# within 1 s by AXVisualSupportAgent is tolerated), a display change, or
# SpacesLab exiting. Output must not be in a folder macOS protects (outdir.sh).
# Changes no setting.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$ROOT/build/spacesctl"
LABEL="$1"; APP="$2"; OUT="$3"; MODE="$4"; shift 4
ROUTES="${MC_ROUTES:-thumb away-thumb large thumb away-thumb large thumb away-thumb thumb large}"
STOP_ON_FAIL="${MC_STOP_ON_FAIL:-0}"
[ "$(echo $ROUTES | wc -w | tr -d ' ')" = 10 ] && [[ " $ROUTES " =~ ^(\ (thumb|away-thumb|large))+\ $ ]] ||
    { echo "MC_ROUTES must name exactly 10 routes (thumb, away-thumb, large)"; exit 1; }
[ -x "$C" ] && [ -d "$APP" ] && [[ "$MODE" =~ ^(fpwindow|session|control)$ ]] ||
    { echo "usage: mcreturns.sh <label> <SpacesLab.app> <outdir> <fpwindow|session|control> [options]"; exit 1; }
source "$ROOT/outdir.sh"; harness_outdir "$LABEL" "$OUT" >/dev/null || exit 1
[ -e "$OUT/STOPPED" ] && { echo "$OUT/STOPPED exists: an earlier configuration was stopped"; exit 3; }
mkdir -p "$OUT"
P="$OUT/$LABEL"; RES="$P.results.tsv"; LOG="$P.log"; ERR="$P.stderr"; WATCH="$P.watch"
: > "$RES"; : > "$LOG"; : > "$P.clicks"

now() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
labpid() { pgrep -n -f "$APP/Contents/MacOS/SpacesLab"; }
shown() { "$C" space "$(labpid)" | sed -E 's/.*shown=([01]).*/\1/'; }
screens() { "$C" modeinfo | sed -E 's/^screens=([0-9]+).*/\1/'; }
STOPPED=""
cleanup() {
    [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
    # Campaign mode: after any stop, no input and no quit; the state is evidence.
    [ "$STOP_ON_FAIL" = 1 ] && [ -n "$STOPPED" ] && return
    # A Mission Control this harness opened is closed (Escape), never at a dialog.
    if [ "$STOPPED" != dialog ] && [ "$STOPPED" != input ] && "$C" alerts > /dev/null &&
       "$C" mcstate | grep -q "open=1"; then "$C" key 53; "$C" waitmc 0 3000 > /dev/null; fi
    if [ "$STOPPED" != dialog ] && [ -n "$(labpid)" ]; then "$C" cmd lab quit; sleep 1; fi
}
trap cleanup EXIT
trap 'STOPPED=${STOPPED:-signal}; echo "STOPPED: signal" | tee -a "$RES"; exit 130' INT TERM HUP
stop() { STOPPED="$1"; touch "$OUT/STOPPED"; echo "STOPPED R${N:-0} ($1): $2" | tee -a "$RES"; summary; exit 2; }
outside_input() {   # as lifecycle-ab.sh
    awk -v start="$START" '
        FILENAME == ARGV[1] { ct[n+0] = $1; cx[n+0] = $2; cy[n+0] = $3; n++; next }
        $1 ~ /^[0-9]+$/ && $1 >= start && $2 != "type=12" {
            if ($2 == "type=5") for (i = 0; i < n; i++)
                if ($1 >= ct[i] && $1 <= ct[i] + 1000 && $4 == "x=" cx[i] && $5 == "y=" cy[i]) next
            print }' "$P.clicks" "$WATCH" 2>/dev/null | head -3
}
check() {
    local a u
    a=$("$C" alerts) || stop dialog "system dialog on screen, left untouched: $a"
    u=$(outside_input); [ -n "$u" ] && stop input "input not from the harness: $(echo "$u" | tr '\n' ' ')"
    [ "$(screens)" = 1 ] || stop display "a display was added or removed"
    [ -n "$(labpid)" ] || stop app "SpacesLab exited"
    return 0
}
act() { check; "$C" "$@"; }
click() { check; echo "$(now) $1 $2" >> "$P.clicks"; "$C" click "$1" "$2"; }
mark() { echo "$(now) MARK R$N $1" >> "$LOG"; }
summary() {
    awk -F'\t' -v l="$LABEL" '$2 ~ /^R([1-9]|10)$/ { n++; if ($4=="PASS") p++; else f++ }
        END { printf "%s: %d Mission Control returns judged: %d PASS, %d FAIL\n", l, n, p, f }' "$RES" | tee -a "$RES"
}
band_ok() {   # FullPanel: teal >= 0.90 both sides; control: <= 0.05
    local l r; l=$(echo "$1" | sed -E 's/.*left=([0-9.]+).*/\1/'); r=$(echo "$1" | sed -E 's/.*right=([0-9.]+).*/\1/')
    if [ "$MODE" = control ]; then awk -v l="$l" -v r="$r" 'BEGIN{exit !(l<=0.05 && r<=0.05)}'
    else awk -v l="$l" -v r="$r" 'BEGIN{exit !(l>=0.90 && r>=0.90)}'; fi
}
mc_still_open() {   # immediately before a click inside Mission Control
    local m; m=$("$C" mcstate)
    echo "$(now) PRECLICK R$N $m" >> "$LOG"
    [[ "$m" == open=1* ]] || stop harness "Mission Control not open before the click ($m)"
}
thumb_click() {   # pointer to the top edge (Spaces bar expands), click the lab Space's thumbnail
    act move 900 4; sleep 1.0
    # Located by its teal pixels (spacesctl labthumb); the Spaces bar's layout
    # depends on the Spaces present, and a predicted position can miss.
    local s x y t; s=$("$C" space "$(labpid)")
    t=$("$C" labthumb "$P-R$N") || stop harness "lab thumbnail not found in the Spaces bar ($t)"
    read -r x y _ <<< "$t"
    echo "$(now) THUMB R$N $s labthumb=$t click=$x,$y" >> "$LOG"
    mc_still_open
    click "$x" "$y"
}
open_mc() {   # opens Mission Control and verifies it; HARNESS-stops otherwise
    check; open -a "Mission Control"
    "$C" waitmc 1 3000 > /dev/null || stop harness "Mission Control did not open ($("$C" mcstate))"
    echo "$(now) MCOPEN R$N $("$C" mcstate)" >> "$LOG"
    sleep 0.6
}
fail_evidence() {   # campaign mode: read-only snapshot of the failure state, no input
    {   echo "$(now) EVIDENCE R$N"
        echo "mcstate: $("$C" mcstate)"; echo "space: $("$C" space "$(labpid)")"
        echo "front: $("$C" front)"; echo "alerts: $("$C" alerts)"
    } >> "$P.failure.txt"
    "$C" shot "$P-R$N-failscreen" >> "$P.failure.txt"
    "$C" cmd lab dump; sleep 0.3; grep "after dump" "$LOG" | tail -1 >> "$P.failure.txt"
}
judge() {   # judge <route>: after the click; waits up to 3 s for the return
    local route="$1" t0 w m band key front fp
    t0=$(now)
    w=$("$C" waitshown "$(labpid)" 1 3000)
    m=$("$C" waitmc 0 1500)
    if [[ "$w" == ok* ]] && [[ "$m" == ok* ]]; then
        sleep 1.2; act move 900 620; sleep 0.2
        band=$("$C" band "$P-R$N" | tr -d '\n')
        "$C" cmd lab dump; sleep 0.3
        fp=$(grep "after dump" "$LOG" | tail -1)
        key=$(echo "$fp" | grep -oE ' key=[01]' | head -1 | tr -d ' ')
        front=$("$C" front)
        local pres; pres=$(echo "$fp" | grep -oE 'pres=0x[0-9a-f]+' | head -1)
        local st; st=$(echo "$fp" | grep -oE 'fp\{state=[0-9]+' | sed 's/fp{//')
        local active; active=$(echo "$fp" | grep -oE 'after dump active=[01]' | sed 's/after dump //')
        local sp; sp=$("$C" space "$(labpid)" | grep -oE 'space=[0-9]+')
        local verdict=PASS why="shown ${w#ok }ms, mc closed ${m#ok }ms after"
        if ! band_ok "$band"; then verdict=FAIL; why="$why; band"; fi
        [ "$front" = SpacesLab ] || { verdict=FAIL; why="$why; front=$front"; }
        [ "$key" = key=1 ] || { verdict=FAIL; why="$why; window not key"; }
        printf "%s\tR%d\t%s\t%s\t%s\tband[%s]\t%s\t%s\t%s\t%s\t%s\n" "$LABEL" "$N" "$route" "$verdict" "$why" \
            "$band" "$pres" "${st:-state=-}" "$key" "${active:-active=-}" "${sp:-space=-}" | tee -a "$RES"
        if [ "$verdict" = FAIL ] && [ "$STOP_ON_FAIL" = 1 ]; then
            fail_evidence; stop product "R$N $route returned but judged FAIL ($why)"
        fi
        return
    fi
    # Not returned: record what is on screen, then one recovery outside the count.
    local mc; mc=$("$C" mcstate)
    "$C" band "$P-R$N-fail" > /dev/null
    "$C" cmd lab dump; sleep 0.3
    fp=$(grep "after dump" "$LOG" | tail -1)
    printf "%s\tR%d\t%s\t%s\t%s\tmc[%s]\tshown=%s\tfront=%s\t%s\n" "$LABEL" "$N" "$route" FAIL \
        "not returned (${w}; mc-close ${m})" "$mc" "$(shown)" "$("$C" front)" \
        "$(echo "$fp" | grep -oE 'pres=0x[0-9a-f]+| key=[01]|fp\{state=[0-9]+' | tr '\n' ' ')" | tee -a "$RES"
    echo "$(now) FAILSTATE R$N $mc" >> "$LOG"
    if [ "$STOP_ON_FAIL" = 1 ]; then
        fail_evidence; stop product "R$N $route not returned (${w}; mc-close ${m})"
    fi
    check
    if "$C" mcstate | grep -q "open=1"; then
        "$C" key 53; "$C" waitmc 0 3000 >> "$LOG"
    fi
    "$C" waitshown "$(labpid)" 1 3000 >> "$LOG" || stop recovery "lab's Space not shown after the recovery Escape"
    sleep 1.0
}

# ---- Run ------------------------------------------------------------------------
pkill -f "SpacesLab.app/Contents/MacOS/SpacesLab"; sleep 1
"$C" watch "$WATCH" & WPID=$!
sleep 0.5
head -1 "$WATCH" 2>/dev/null | grep -q "access=1" || { echo "input watch unavailable; not starting"; exit 1; }
[ "$(screens)" = 1 ] || { echo "more than one display connected; built-in only"; exit 1; }
BIN="$APP/Contents/MacOS/SpacesLab"
echo "== $LABEL ($MODE $*) $(date '+%H:%M:%S') binary=$(shasum -a 256 "$BIN" | cut -c1-16) routes=[$ROUTES] stop-on-fail=$STOP_ON_FAIL" | tee -a "$RES"
# Start after 5 s without outside input (at most 60 s).
for i in $(seq 1 60); do
    t=$(now); START=$((t - 5000))
    [ -z "$(outside_input)" ] && break
    sleep 1
done
START=$(now)
a=$("$C" alerts) || { echo "a system dialog is on screen; not starting: $a"; exit 1; }
"$C" move 900 620

N=0; mark entry
open -n --stderr "$ERR" "$APP" --args -mode "$MODE" -tag lab -log "$LOG" -autoFS YES -FullPanelTrace YES "$@"
for _ in $(seq 1 40); do [ -n "$(labpid)" ] && break; sleep 0.2; done
"$C" waitshown "$(labpid)" 1 8000 > /dev/null; sleep 2.0
grep -q "launched active=0" "$LOG" && stop focus "SpacesLab launched inactive"
check
[ "$("$C" front)" = SpacesLab ] && [ "$(shown)" = 1 ] || stop harness "lab not frontmost and shown after entry"
band=$("$C" band "$P-R0" | tr -d '\n')
band_ok "$band" || stop harness "entry band unexpected: $band"
printf "%s\tR0\tentry\tok\tband[%s]\n" "$LABEL" "$band" | tee -a "$RES"

for route in $ROUTES; do
    N=$((N + 1)); mark "$route"
    check
    [ "$(shown)" = 1 ] && [ "$("$C" front)" = SpacesLab ] || stop harness "lab not shown and frontmost before R$N"
    case "$route" in
    thumb)
        open_mc
        act move 900 620; sleep 0.6
        thumb_click ;;
    away-thumb)
        act key 123 ctrl fn
        "$C" waitshown "$(labpid)" 0 3000 > /dev/null || stop harness "Control-Left did not leave the Space"
        sleep 0.8; act activate com.apple.finder >> "$LOG"; sleep 1.2
        [ "$(shown)" = 0 ] || stop harness "activating Finder returned to the lab's Space"
        open_mc
        thumb_click ;;
    large)
        act key 123 ctrl fn
        "$C" waitshown "$(labpid)" 0 3000 > /dev/null || stop harness "Control-Left did not leave the Space"
        sleep 0.8; open_mc
        act key 124 ctrl fn
        "$C" waitshown "$(labpid)" 1 3000 > /dev/null || stop harness "Control-Right in Mission Control did not reach the lab's Space"
        sleep 0.8
        POS=$("$C" mcwindow "SpacesLab lab"); echo "$(now) MCWINDOW R$N $POS" >> "$LOG"
        read -r x y _ <<< "$POS"
        mc_still_open
        click "$x" "$y" ;;
    esac
    judge "$route"
done

N=11; mark exit
check
"$C" cmd lab exit; sleep 3.0
"$C" cmd lab dump; sleep 0.3
FR=$(grep "after dump" "$LOG" | tail -1 | sed -E 's/.* fr=(\{\{[^}]*\}, \{[^}]*\}\}).*/\1/')
EX="frame $FR"; [[ "$FR" == *"{800, 500}"* ]] && EX="windowed again"
printf "%s\texit\t%s\n" "$LABEL" "$EX" | tee -a "$RES"
check
summary
