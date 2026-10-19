# Evidence for the 0.1.0 release candidate

Small, inspectable artifacts behind the claims in
[INTEGRATION_EVIDENCE.md](../../INTEGRATION_EVIDENCE.md) and
[TESTING.md](../../TESTING.md). All of it was captured on a physical
MacBook Pro 14-inch 2021 (MacBookPro18,3, M1 Pro), built-in display
1800 × 1169 pt with a 38 pt camera housing, running macOS 27.0.1 (26A434).
Nothing here is simulated, rendered or retouched.

> **References.** Commit hashes in this document identify revisions in
> FullPanelKit's private development history, which is not published
> ([PROVENANCE.md](../../PROVENANCE.md#public-history)). "Release candidate" means
> the earlier, unpublished 0.1.0 candidate, which used the previous
> fullscreen-frame geometry mechanism.

Full logs and every screenshot (about 14 MB) stay with the maintainer. The
files below were extracted from them by a script that also replaces local
paths with `<repo>`, `<validation>` or `~`.

## How to read a band capture

Each `*-band.png` is a real `screencapture` of the top 38 pt of the built-in
display at 2× (3600 × 76 px). It covers the area left of the camera housing,
the housing itself, and the area right of it.

- **Coloured left and right areas:** the app's window draws there, so
  FullPanel is active.
- **Black left and right areas:** ordinary native fullscreen. macOS keeps the
  window below the housing.
- **The middle section** lies behind the camera housing and is physically
  invisible. Some demos draw a hatch or outline there.
- macOS colour-manages the apps' sRGB colours for the display, so the
  captured values differ slightly from the colours in the source. For
  example, winit's `#ff8c1a` is captured as about `#f4a34b`.

## Release candidate `30fa67b` (recorded 2026-10-17)

| File | What it shows |
| --- | --- |
| `bridges/electron-autotest.checks.txt` | Electron bridge automated suite, 63/63 plus 2 informational |
| `bridges/tauri-autotest.checks.txt` | Tauri bridge automated suite, 101/101 |
| `bridges/winit-autotest.checks.txt` | winit bridge automated suite, 140/140 |
| `bridges/<bridge>-A-band.png`, `-B-band.png` | Window A (FullPanelSession) and window B (control, no session) in native fullscreen |
| `bridges/<bridge>-band-probe.txt` | The measurement for those captures: non-black fraction and mean colour beside the housing |
| `demos/fullpaneldemo-appkit-band.png`, `-swiftui-band.png` | `Examples/FullPanelDemo` (`FullPanelWindow`) in native fullscreen |
| `demos/interact-*-2-clicked.png` | The same after synthetic clicks on the "+1" buttons beside the housing: counters at 2 (left) and 1 (right) |
| `demos/interact-appkit-4-hidden.png` | The band again after the pointer touched the top edge (menu bar revealed) and moved away (menu bar hidden) |
| `demos/fullpaneldemo-*-probe.txt` | Measurements for the demo captures, including the top-edge reveal |

Clicks and pointer moves in the demo checks are synthetic `CGEvent`s posted
by `Tools/SpacesHarness`'s `spacesctl`. Fullscreen was entered through the
window's Accessibility `AXFullScreen` attribute, which is AppKit's own
native fullscreen. The captures that show the revealed menu bar are not
included: they contain the maintainer's menu-bar items.

## Final acceptance run, SDK code of `601d06a` (recorded 2026-10-17)

The SDK code is functionally identical to the release candidate: commits
after `601d06a` change comments, documentation and one harness line.

| File | What it shows |
| --- | --- |
| `core/scenarios.summary.txt` | `run-scenarios.sh`: A, B, R1–R5, 77/77, with the recovery path per Mission Control return |
| `core/missioncontrol.summary.txt` | `missioncontrol.sh 3`: native control vs. FullPanelSession vs. FullPanelWindow, 6 return paths × 3, band sampled at 0.4 / 1.2 / 3.0 s |
| `core/activation.summary.txt` | Dock click and Command-Tab, compared with native fullscreen |
| `core/displaymode.summary.txt` | Display-mode changes with and without the housing band |
| `core/autotest.checks.txt`, `core/appkit-subclass.checks.txt`, `core/lifecycle.checks.txt` | FullPanelAttachDemo autotest 82/82, AppKit-subclass autotest 48/48, lifecycle 28/28 |
| `core/scenario-A-*.png` | Scenario A band at entry and after the first Mission Control return |
| `core/mc-*.png` | Mission Control samples: native control (black), session at 0.4 s and 3.0 s, FullPanelWindow at 3.0 s |
