# Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
#
# displaymode-ab.sh's checker: reads one SpacesLab DIAG JSON line on stdin and
# judges one transition. Prints a tab-separated record; exit 0 PASS, 1 FAIL.
#
#   python3 -I dmcheck.py <kind> <expected WxH> <expected space id or -> \
#       <band "left=.. right=.."> <shown 0|1> <space id now>
#   kind: housing | nohousing | exit
import json
import sys

kind, expected, want_space, band, shown, space_now = sys.argv[1:7]
d = json.loads(sys.stdin.read())
ew, eh = (float(v) for v in expected.split("x"))


def rect(r):
    return (r["x"], r["y"], r["width"], r["height"]) if r else (0, 0, 0, 0)


def same(a, b):
    return all(abs(x - y) < 0.5 for x, y in zip(a, b))


win, scr = rect(d.get("windowFrame")), rect(d.get("screenFrame"))
inset, fs = d.get("screenSafeAreaTop", 0), bool(d.get("nativeFullscreenStyleMask"))
key, active = bool(d.get("isKeyWindow")), bool(d.get("appActive"))
state, reason, released = d.get("state"), d.get("fallbackReason"), bool(d.get("screenReleased"))
problems = []


def need(ok, what):
    if not ok:
        problems.append(what)


need(d.get("screenCount") == 1, "more than one screen")
need(key and active, "window not key / app not active")
if kind in ("housing", "nohousing"):
    need(fs, "not in fullscreen")
    need(abs(scr[2] - ew) < 0.5 and abs(scr[3] - eh) < 0.5, f"screen {scr[2]:.0f}x{scr[3]:.0f} != {expected}")
    need(same(win, scr), "window frame != screen frame")
    need(shown == "1", "lab's Space not shown")
    need(want_space in ("-", space_now), f"Space changed ({want_space} -> {space_now})")
    need(d.get("geometry") == "reservation", f"entry geometry {d.get('geometry')} (want reservation)")
if kind == "housing":
    need(inset > 0, "no camera housing reported")
    need(state == 2 and reason == 0 and not released, f"state={state} reason={reason} released={released} (want active)")
    try:
        left = float(band.split("left=")[1].split()[0])
        right = float(band.split("right=")[1].split()[0])
    except (IndexError, ValueError):
        left = right = -1.0
    need(left >= 0.9 and right >= 0.9, f"band not covered ({band})")
elif kind == "nohousing":
    need(inset == 0, "housing still reported")
    need(state == 3 and reason == 1 and released, f"state={state} reason={reason} released={released} (want fallback / no housing)")
elif kind == "exit":
    need(not fs, "still in fullscreen")
    need(abs(win[2] - 800) < 1 and abs(win[3] - 500) < 1, f"windowed size {win[2]:.0f}x{win[3]:.0f} != 800x500")
    need(state == 1, f"state={state} (want inactive)")
    need(space_now in ("0", ""), "fullscreen Space still present")

fmt = lambda r: "{{%.0f,%.0f},{%.0f,%.0f}}" % r
print("\t".join([
    "PASS" if not problems else "FAIL",
    f"window={fmt(win)}", f"screen={fmt(scr)}", f"inset={inset:.0f}",
    f"fs={int(fs)}", f"key={int(key)}", f"active={int(active)}",
    f"state={state}", f"reason={reason}", f"released={int(released)}",
    f"space={space_now}", f"band[{band}]",
    f"reservation-requests={d.get('reservationRequests')}",
    "; ".join(problems),
]))
sys.exit(0 if not problems else 1)
