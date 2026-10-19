# Manual acceptance

Checks that need a person at a notched MacBook: real trackpad gestures, the
lock screen, display sleep, Hot Corners and physical displays. Everything
else in [TESTING.md](TESTING.md) is automated. A check counts only when a
person has done it and recorded the result; this file never records a
result by itself.

> **References.** Commit hashes in this document identify revisions in
> FullPanelKit's private development history, which is not published
> ([PROVENANCE.md](PROVENANCE.md#public-history)). "Release candidate" means
> the earlier, unpublished 0.1.0 candidate, which used the previous
> fullscreen-frame geometry mechanism.

Before you start:
- Build the demo once: `Examples/FullPanelDemo/build-demo.sh`.
- Quit other copies of the demo; builds share a bundle identifier.
- In System Settings, "Automatically hide and show the menu bar in full
  screen" must not be set to *Never* (the default is fine).
- To capture evidence: Shift-Command-5 records the screen; Shift-Command-3
  takes a screenshot. A short recording of steps 3–5 of M1 is the most useful
  single artifact.

The steps describe the demo window as redesigned after `96d3006`; results
recorded before that used the earlier demo (counters labelled "LEFT +1" /
"RIGHT +1") and the same fullscreen code.

Launch command used below (from the repository root):

```sh
open Examples/FullPanelDemo/build/FullPanelDemo.app --args -FullPanelTrace YES
```

Restore at any point: press Control-Command-F to leave fullscreen and quit the
demo (Command-Q). The menu bar must be back to normal everywhere; if a Space
still shows a transparent menu bar, close that fullscreen Space from Mission
Control.

## M1 — Everyday use (about 5 minutes)

| # | Do | Pass | Fail |
| --- | --- | --- | --- |
| 1 | Launch the demo, press Control-Command-F | A green "LEFT OF CAMERA" and a blue "RIGHT OF CAMERA" strip fill the areas left and right of the camera; no menu bar; the window's status reads "FullPanel active" | Black strips (ordinary fullscreen), or a menu bar over the strips |
| 2 | With the trackpad, click inside each strip, then each strip's "+1" button | Each click increases that strip's counter by one; a ring appears where a click lands in the strip | No change, or the click lands on a menu bar |
| 3 | Move the pointer slowly up into a strip, then to the very top edge, then back down | The strips stay visible until the pointer reaches the top edge; then the menu bar slides in. Moving down hides it and the strips return | The menu bar appears as soon as the pointer enters a strip, never appears, or does not hide |
| 4 | Three-finger swipe up (Mission Control), click the demo's small Space thumbnail at the top | The demo's fullscreen Space returns; the strips come back within about a second (a brief black or backdrop flash is expected) | Strips stay black or covered by a menu bar after 2 s |
| 5 | Mission Control again, click the large window preview; then Mission Control and press Escape | As in 4 | As in 4 |
| 6 | Four-finger swipe to the desktop Space and back | Native Space switching; strips return | Swipe does nothing, or strips stay black |
| 7 | Click both strips again after the returns | Counters increase | No response |
| 8 | Control-Command-F to exit | Window back at its windowed size and position; normal menu bar on the desktop | Window at the wrong size, or the desktop menu bar transparent |
| 9 | Optional comparison: turn off "Use FullPanel" in the window, then Control-Command-F; exit again and turn it back on | Ordinary fullscreen: black strips beside the camera; status "Ordinary macOS fullscreen". The window growing or shrinking by its titlebar height when the switch changes is the known style-toggle limitation ([COMPATIBILITY.md](COMPATIBILITY.md)), not a failure | Strips coloured with FullPanel off |

## M2 — Lock and display sleep (about 3 minutes)

With the demo in fullscreen and the strips visible (M1 step 1):

| # | Do | Pass | Fail |
| --- | --- | --- | --- |
| 1 | Control-Command-Q (lock), then unlock | The demo's Space shows the strips again; top-edge reveal still works (M1 step 3) | Strips black, menu bar stuck visible or transparent, demo left fullscreen |
| 2 | Sleep the display (Control-Shift-Power, or wait for display sleep), then wake and unlock | As in 1 | As in 1 |
| 3 | Exit fullscreen (M1 step 8) | As M1 step 8 | As M1 step 8 |

## M3 — Hot Corners (optional, only if you use Hot Corners)

FullPanelKit sets its own presentation options while the strips are visible;
native fullscreen on macOS 27 may treat Hot Corners differently. Compare with
an ordinary app in native fullscreen (for example TextEdit, Control-Command-F).

| # | Do | Pass | Fail |
| --- | --- | --- | --- |
| 1 | In the native app's fullscreen, move to your configured corner | Note what happens (the control result) | — |
| 2 | Same in the demo's fullscreen | Same as the control, or a difference you consider acceptable (note it) | A corner action you rely on stops working, or keeps firing after exit |
| 3 | Exit both; try the corner on the desktop | Corner works normally | Corner stays disabled after leaving fullscreen |

## M4 — Bridges after Mission Control (optional, about 2 minutes each)

The automated suites do not perform Mission Control returns or physical
clicks for the bridges (see [INTEGRATION_EVIDENCE.md](INTEGRATION_EVIDENCE.md)).
For each one:

| Bridge | Launch (from the repository root) | Enter fullscreen |
| --- | --- | --- |
| winit | `cd Integrations/Winit && cargo run --locked -p fullpanel-winit-test` | **F** in window A |
| Tauri | `cd Integrations/Tauri && cargo run --locked -p fullpanel-tauri-test` | **Enter fullscreen** in window A |
| Electron | `cd Integrations/Electron && npm start` (after the build steps in its README) | **Enter fullscreen** in window A |

Then: click in both coloured strips, do M1 steps 3–6, click both strips
again, and exit. Pass and fail are as in M1. Close the app with Command-Q
(Control-C in the terminal for the Rust apps).

## M5 — External display (only if one is connected)

Follow [WINDOW_LIFECYCLE.md](WINDOW_LIFECYCLE.md) checklist items 1, 6 and 7,
and run `Tools/SpacesHarness/migration.sh` in its three modes, with the
external display connected. Then run `swift test`: its 4 screen-release tests
run only while a display without a housing is connected. Expected: a
fullscreen window on the external display is ordinary fullscreen; back on the
built-in display it shows the strips again.

## Recording results

For each check, note pass or fail, the time, and anything unexpected; attach
recordings where useful. Report failures with the `-FullPanelTrace YES`
output (Console.app, process "FullPanelDemo").
