# Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
#
# lifecycle-ab.sh's checker: reads one SpacesLab DIAG/DIAG2 JSON line on stdin
# and judges one transition. Prints a tab-separated record; exit 0 PASS, 1 FAIL.
#
#   python3 -I lccheck.py <kind> <band "left=.. right=.."> <expect>
#   kind:   fp        FullPanel: whole display, active, band covered
#           native    ordinary fullscreen of an unattached window: camera-safe
#                     frame (display minus the band), band black
#           windowed  not in fullscreen
#           revealed  FullPanel with the menu bar revealed: options relaxed,
#                     band not covered
#           detached  session detached in fullscreen: options released, band
#                     black (the frame is recorded, not judged)
#           tile      a Split View tile: fullscreen, narrower than the display
#                     and AppKit's camera-safe height, band not covered,
#                     options not forced
#   expect: key=value[,key=value] extra diagnostics that must match, e.g.
#           geometry=reservation,entryPreparedBy=reservationRequest ("-": none);
#           size=WxH checks the window's frame size
import json
import sys

kind, band, expect = sys.argv[1:4]
d = json.loads(sys.stdin.read())
FORCED = 0x40A   # FullScreen | HideMenuBar | HideDock


def rect(r):
    return (r.get("x", 0), r.get("y", 0), r.get("width", 0), r.get("height", 0)) if r else (0, 0, 0, 0)


win, scr = rect(d.get("labWindowFrame")), rect(d.get("labScreenFrame"))
fs, key, onspace = bool(d.get("labFullScreen")), bool(d.get("labKey")), bool(d.get("labOnActiveSpace"))
inset = d.get("screenSafeAreaTop", 38)
state, pres = d.get("state"), d.get("appPresentationOptionsRaw", -1)
try:
    left = float(band.split("left=")[1].split()[0])
    right = float(band.split("right=")[1].split()[0])
except (IndexError, ValueError):
    left = right = -1.0
problems = []


def need(ok, what):
    if not ok:
        problems.append(what)


def same(a, b):
    return all(abs(x - y) < 0.5 for x, y in zip(a, b))


if kind in ("fp", "native", "revealed", "detached"):
    need(fs, "not in fullscreen")
    need(onspace, "window's Space not shown")
if kind == "fp":
    need(same(win, scr), "window frame != screen frame")
    need(state == 2, f"state={state} (want active)")
    need(d.get("frameAccepted") is True, "entry not accepted")
    need(left >= 0.9 and right >= 0.9, f"band not covered ({band})")
    need(not key or pres == FORCED, f"presentation 0x{pres:x} (want 0x40a while key)")
elif kind == "native":
    # AppKit's camera-safe tile: the display minus the band, which AppKit
    # rounds up (1169 - 38 inset -> 1130 on the 14-inch panel).
    need(abs(win[2] - scr[2]) < 0.5 and scr[3] - inset - 2 <= win[3] <= scr[3] - inset,
         f"frame {win[2]:.0f}x{win[3]:.0f} is not AppKit's camera-safe tile below the {inset:.0f} pt band")
    need(0 <= left <= 0.05 and 0 <= right <= 0.05, f"band not black ({band})")
elif kind == "revealed":
    need(d.get("menuBarRevealed") is True, "reveal not seen")
    need(pres != FORCED, "options still forced while revealed")
    need(0 <= left < 0.5 and 0 <= right < 0.5, f"band still covered while revealed ({band})")
elif kind == "detached":
    need(d.get("sessionAttached") is False, "session still attached")
    need(pres != FORCED, f"presentation 0x{pres:x} still forced")
    need(0 <= left <= 0.05 and 0 <= right <= 0.05, f"band not black ({band})")
elif kind == "tile":
    need(fs, "not in fullscreen")
    need(win[2] < scr[2] - 100, f"width {win[2]:.0f} is not a tile of {scr[2]:.0f}")
    need(scr[3] - inset - 2 <= win[3] <= scr[3] - inset, f"height {win[3]:.0f} is not AppKit's camera-safe height")
    need(0 <= left <= 0.05 and 0 <= right <= 0.05, f"band not black ({band})")
    need(pres != FORCED, f"presentation 0x{pres:x} forced in a tile")
elif kind == "windowed":
    need(not fs, "still in fullscreen")
if expect != "-":
    for pair in expect.split(","):
        k, v = pair.split("=", 1)
        if k == "size":
            need(f"{win[2]:.0f}x{win[3]:.0f}" == v, f"size {win[2]:.0f}x{win[3]:.0f} (want {v})")
        else:
            need(str(d.get(k)) == v, f"{k}={d.get(k)} (want {v})")

fmt = lambda r: "{{%.0f,%.0f},{%.0f,%.0f}}" % r
print("\t".join([
    "PASS" if not problems else "FAIL",
    f"window={fmt(win)}", f"screen={fmt(scr)}", f"fs={int(fs)}", f"key={int(key)}", f"onSpace={int(onspace)}",
    f"state={state}", f"pres=0x{pres:x}" if isinstance(pres, int) and pres >= 0 else "pres=-",
    f"geometry={d.get('geometry', '-')}", f"accepted={d.get('frameAccepted', '-')}",
    f"preparedBy={d.get('entryPreparedBy', '-')}", f"revealed={d.get('menuBarRevealed', '-')}",
    f"rejected={d.get('entryRejected', '-')}", f"reason={d.get('fallbackReason', '-')}",
    f"band[{band}]",
    f"reservation-requests={d.get('reservationRequests', '-')}",
    "; ".join(problems),
]))
sys.exit(0 if not problems else 1)
