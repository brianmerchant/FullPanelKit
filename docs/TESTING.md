# Testing

FullPanelKit's behavior depends on a notched display, WindowServer and
Mission Control, so it is tested at three levels. Unit tests run anywhere;
everything else needs the hardware named below and cannot be simulated.
A pass in one level is not evidence for another.

> **References.** Commit hashes in this document identify revisions in
> FullPanelKit's private development history, which is not published
> ([PROVENANCE.md](PROVENANCE.md#public-history)). "Release candidate" means
> the earlier, unpublished 0.1.0 candidate, which used the previous
> fullscreen-frame geometry mechanism.

| Level | What it proves | Where |
| --- | --- | --- |
| Unit tests | Decision logic, state machine, lifecycle and ownership, hook scoping and the absence of window-class changes, against real `NSWindow`s off screen | `swift test` |
| Package check | A separate package can consume a committed ref from a clean clone; the decision SPI is not public | `Tools/ConsumerCheck/check.sh` |
| Hardware acceptance | Real fullscreen Spaces, pixels beside the housing in screen captures, Mission Control, activation, display modes | `Examples/FullPanelAttachDemo`, `Tools/SpacesHarness` |
| Manual | Things that need a person (hover reveal, trackpad gestures, lock screen, physical displays) | checklists below |

## Unit tests

```sh
swift test                         # 103 tests (4 skip without a display lacking a housing)
swift test --sanitize=address
swift build -Xswiftc -warnings-as-errors -Xcc -Werror
```

| Suite | Covers |
| --- | --- |
| `DecisionTests` | rect tolerance, arming precedence, state resolution, reveal rule, compositor math, return readiness, re-arm and re-assert rules, presentation targets |
| `ReservationHookTests` | the menu-bar reservation hook: installed once at enable, only its one method changed, entry geometry, fallback to ordinary fullscreen when unavailable or replaced by other code, removed geometry options ignored; installation check, entry verification (P1) |
| `EntryPreparationTests` | which entry path arms (toggle, `willEnterFullScreen`, the reservation request), late enable reported not adopted |
| `ReturnRecoveryTests` | Mission Control return recovery in the engine (budget restart, re-assert scheduling and cancellation) |
| `SessionTests` | attach/detach, refusal of AppKit classes, no window class modified (method tables of the class chain before and after attach, enable, entry preparation, detach; no block-based implementation), subclass overrides kept, KVO, notifications, ownership |
| `WindowLifecycleTests` | enable/disable style round trip, close, termination, the application's own delegate, no class modified by `FullPanelWindow` |
| `WindowLifetimeTests` | window freed while attached or in a pending restore; fails deterministically if the engine holds the window unretained (the OmacVM #402 pattern) |
| `DisplayAndActivationTests` | screen release/resume, activation-relevant window attributes |
| `GeometryTests` | housing geometry and layout conversion |

Four `DisplayAndActivationTests` skip unless a display **without** a camera
housing is connected (external or Sidecar). They are counted as skipped, never
as passed.

## Package check

```sh
Tools/ConsumerCheck/check.sh            # HEAD
Tools/ConsumerCheck/check.sh v0.1.1     # a release tag
```

Clones the committed ref into a temporary directory (no working-tree files,
caches or untracked files), builds `Tools/ConsumerCheck/Consumer` against it,
runs it (public API used by the quick starts and the examples), then verifies that `FPKDecisions` is not reachable
through `import FullPanelKit`. Against the pre-release `main` (`9dde660`) the
last step fails, as it should.

## Hardware acceptance

Requirements: a notched MacBook built-in display; the terminal that runs the
scripts needs **Accessibility** and **Screen Recording**; nobody uses the Mac
while they run (they open Mission Control, switch Spaces and press keys).
Each script refuses to run, or reports a harness precondition failure, rather
than passing when its setup is wrong.

Quit every other copy of a test app first: builds share bundle identifiers,
and `open -b` or saved window state can pick another copy
(`run-scenarios.sh` refuses to start while one is running).

### FullPanelAttachDemo (SwiftUI `WindowGroup` + `FullPanelSession`)

```sh
cd Examples/FullPanelAttachDemo && ./build-demo.sh
./run-scenarios.sh <outdir> 5        # A, B, R1–R5
build/FullPanelAttachDemo.app/Contents/MacOS/FullPanelAttachDemo -FullPanelAttachScenario lifecycle
build/FullPanelAttachDemo.app/Contents/MacOS/FullPanelAttachDemo -FullPanelAttachAutotest YES -FullPanelAttachMissionControl NO
… -FullPanelAttachAutotest YES -FullPanelAttachAppKitSubclassOnly YES -FullPanelAttachMissionControl NO
```

| Scenario | What it does |
| --- | --- |
| A | attach, enter normally, N originating-Space Mission Control returns |
| B | enter unattached, attach inside fullscreen (documented fallback), next entry |
| R1 | relaunch restores the window into fullscreen, N returns |
| R2 | two windows restored into two fullscreen Spaces |
| R3 | host attaches inside the restored entry's `willEnterFullScreen` |
| R4 | host attaches 250 ms late (documented fallback; band captured black) |
| R5 | restored while another app is in use; activated like a Dock click; N returns |
| lifecycle | 20 attach/detach cycles; close in fullscreen; close during entry/exit (vs. an ordinary window); two FullPanel windows in two Spaces and presentation ownership |
| autotest | identity, delegate, controller, ordinary-window isolation, `FullPanelWindow` in the same process, second window, close, detach/re-attach in fullscreen, presentation restore, plain `NSWindow` refusal, KVO probe |

Pixels: each check captures the band beside the housing with
`screencapture` and reports the fraction of the demo's colors; ordinary
fullscreen leaves it black. Inspect the saved PNGs too.

### SpacesHarness (native fullscreen control vs. FullPanel)

```sh
cd Tools/SpacesHarness && ./build.sh
./missioncontrol.sh 3        # 6 return paths × 3, sampled at 0.4 / 1.2 / 3 s
./activation.sh              # Dock and Command-Tab, this Mac's setting
./activation.sh NO           # setting off in SpacesLab's argument domain
./displaymode.sh 54 60       # mode change with / without housing (see `build/spacesctl modes`)
./migration.sh <mode> <escape|moved|desktop>   # needs a second display
```

Every SpacesHarness script runs native fullscreen (`control`) through the
same steps; a FullPanel result only counts where the control behaves as
expected. `spacesctl band` measures SpacesLab's teal beside the housing, so an
opaque menu bar counts as not rendered. Mission Control's closing animation
can still be on screen at 0.4 s; 1.2 s and 3 s are the settled samples.

## Results

### 0.1.1, 2026-10-20

Release code (`Prepare FullPanelKit 0.1.1`; core sources as in the fix
commit). MacBook Pro 14-inch (M1 Pro), built-in display, macOS 27.0.1. The
fix concerns menu-bar reveal sensing for windows whose fullscreen titlebar
window AppKit keeps opaque (CHANGELOG 0.1.1).

| Check | Result |
| --- | --- |
| `swift build`, `--build-tests`, `-warnings-as-errors -Werror` | clean |
| `swift test` / `--sanitize=address` | 107 executed, 4 skipped (no display without a housing), 0 failures / same, no reports |
| `Tools/ConsumerCheck/check.sh HEAD` | PASS (public API; decision SPI not visible) |
| Examples and `Tools/SpacesHarness` | build |
| `smoke-fullpaneldemo.sh` `appkit`, `accessory`, `swiftui` | all three: band filled after entry, menu bar revealed at the top edge, band filled again after moving away |
| FullPanelDemo, plain and `-FullPanelDemoTitlebarAccessory YES`: entry, 3 × (Mission Control + Escape, Control-Left/Right) | band filled after all 6 returns in both; the accessory window takes the new path (trace `source=titlebar-pinned`) |
| Attachment autotest / AppKit subclass | 82/82 / 49/49 |
| Lifecycle scenario, plain / `NSZombieEnabled=YES MallocScribble=1` | 28/28 / 28/28 |
| `run-scenarios.sh <outdir> 5` (Terminal.app): A, B, R1–R5 | 77/77; recovery path on every Mission Control return |
| Owner, physical pointer, an application whose windows have a titlebar accessory view controller | menu bar revealed and hidden at the top edge, also after a Mission Control return; band restored; menu used; click beside the housing |

Before the fix, the same accessory configuration (v0.1.0 core) left the band
black after a top-edge reveal, Mission Control and a Space switch until
fullscreen was left; without the accessory it was correct. Not re-run for
0.1.1 (the change is limited to reveal sensing): the 100-return
`mccampaign.sh`, display-mode round trip, Split View, the bridges' suites.
The lifecycle scenario must be launched from the terminal (as above): opened
with `open`, a newly signed build has no Screen Recording permission for its
own band captures (`capture failed`).

### MIT release candidate (current mechanism), 2026-10-19

The code in this repository: whole-display geometry from AppKit's menu-bar
reservation ([ARCHITECTURE.md](ARCHITECTURE.md)). MacBook Pro 14-inch (2021,
M1 Pro, MacBookPro18,3), built-in display 1800 × 1169 pt (housing band
38 pt), macOS 27.0.1 (26A434). Software checks and builds ran on an exact
export of the release tree. Extracts: [evidence/mit-rc1](evidence/mit-rc1/README.md).

| Check | Result |
| --- | --- |
| `swift build`, `swift build --build-tests` | no warnings |
| `swift build -Xswiftc -warnings-as-errors -Xcc -Werror` | clean |
| `-Xcc -Wall -Xcc -Wextra` | 4 `unused parameter 'note'` warnings (notification handlers), nothing else |
| `swift test` | 103 executed: 99 passed, 4 skipped (no display without a housing), 0 failed |
| `swift test --sanitize=address` | 103 executed: 99 passed, 4 skipped, 0 failed, no sanitizer reports |
| `Tools/ConsumerCheck/check.sh HEAD` | pass: public API and README examples compile from a clean clone; decision SPI hidden |
| Public declarations | identical to the earlier release candidate's (headers and Swift files differ in comments only) |
| Runtime method replacement in `Sources/` | exactly one (`method_setImplementation` on `-[_NSFullScreenContentController reservesSpaceForMenuBarInFullScreen]`); no window class is modified (unit-tested: method tables before and after attach, enable, entry preparation and detach) |
| `Tools/BehaviorProbes/ReservationProbe` | macOS 27.0.1: `-reservesSpaceForMenuBarInFullScreen` `B16@0:8` and `-window` `@16@0:8`, one implementer |
| Examples, SpacesHarness, AdoptionProbe, other probes | build; SpacesLab has one Swift 6 concurrency warning (a test tool) |
| FullPanelAttachDemo autotest (Mission Control off) | **82/82** |
| autotest, AppKit subclass (Mission Control off) | **49/49** |
| lifecycle; lifecycle under `NSZombieEnabled`/`MallocScribble` | **28/28**; **28/28**, no zombie messages |
| Mission Control: `mccampaign.sh` (100 thumbnail returns, `FullPanelWindow`, defaults) | **100/100 PASS**, 0 FAIL, no stop. Every return: Space shown, Mission Control closed, app active, window key, band beside the housing filled (1.00/1.00), FullPanel active. Click to Space shown: Space thumbnail from inside the Space, mean 517 ms (486–556); from another app's Space, mean 641 ms (612–703). One unexplained modifier press/release (no click, 3 s before the click) during one return, which passed; 99/99 without it |
| winit 0.30.13: `cargo build --locked --offline`; `--autotest` | no warnings; **140/140** |
| Tauri 2.12.3: `cargo build --locked --offline`; `--autotest` | no warnings; **101/101** |
| Electron 44.7.0: `npm ci`, `npm run build`; `npm run autotest` | no warnings; **63/63**, informational 2/2 |

What 100 clean returns mean: at 95 % confidence the per-return failure rate
on this Mac and route is below about 3 %. They cannot show that it is zero,
or that Mission Control behaves exactly like native fullscreen. Earlier
development builds had 3 ignored thumbnail clicks in 99 attempts under an
older, less controlled harness, which is not conclusive either way.

Not re-run on this code (evidence from earlier runs of the same mechanism):
Dock and Command-Tab, Space keys and the large-preview return (10/10 each
for `FullPanelWindow` and `FullPanelSession`, `abc.sh`, on SDK code identical
to this release's), SwiftUI `WindowGroup` smoke test (6/6, same code),
display-mode round trip (6/6), Split View fallback (9/9), lock and sleep
(5/5 each, attended), these four with the reservation mechanism as the
default geometry, on an earlier revision that still contained the
since-removed frame code (including an observe-only frame override on
attached classes); not repeated on the release code.
Not run at all: physical external display, the 4 external-display unit
tests, macOS other than 27.0.1, other notched models, trackpad gestures
([MANUAL_ACCEPTANCE.md](MANUAL_ACCEPTANCE.md)).

### Release candidate (earlier mechanism)

> The rest of this section is for the release candidate, whose whole-display
> mechanism was a private fullscreen-frame override with frame guards. It is
> kept as a record. Lines that mention frame guards describe the release
> candidate.

Release candidate, 2026-10-17. MacBook Pro 14-inch (2021, M1 Pro,
MacBookPro18,3), built-in display 1800 × 1169 pt (housing band 38 pt),
macOS 27.0.1 (26A434), Xcode 27.1, Swift 6.4. Full logs stay with the
maintainer; the public extracts (summaries, check lists, real screen
captures) are in [evidence/0.1.0-rc](evidence/0.1.0-rc/README.md).

Final acceptance run on SDK code as of `601d06a`. Later commits change only
comments, documentation, package metadata and one harness line; no
non-comment line in `Sources/` or `Package.swift` differs, so these results
apply to the release candidate `30fa67b`.

| Check | Result |
| --- | --- |
| `swift build -Xswiftc -warnings-as-errors -Xcc -Werror` | clean |
| `swift test` | 96 executed: 92 passed, 4 skipped (no display without a housing), 0 failed |
| `swift test --sanitize=address` | 96 executed: 92 passed, 4 skipped, 0 failed, no sanitizer reports |
| `Tools/ConsumerCheck/check.sh` | pass: API surface and all README examples compile from a clean clone; decision SPI hidden (and correctly fails on `9dde660`) |
| `run-scenarios.sh … 5` | **77/77**: A 11, B 10, R1 13, R2 12, R3 8, R4 8, R5 15; recovery path 5/5 per return in A, R1, R5; frame guard active (18 rejections), never stood aside |
| lifecycle | **28/28** under `NSZombieEnabled`/`MallocScribble`/`MallocGuardEdges`; no zombie, allocator or presentation warnings |
| lifecycle under `leaks --atExit` (`1e28592`) | 28/28; 406 leaked blocks (25.8 KB), all system (XPC `LNDaemonApplicationInterface`, libdispatch); none of a FullPanelKit class |
| autotest | **82/82** |
| autotest, AppKit subclass | **48/48** |
| `missioncontrol.sh 3` | control, session, fpwindow: shown on entry and on all 18 returns each (6 paths × 3); FullPanel rendered at the 0.4 s sample on all 36 FullPanel returns (an earlier run: 35/36 at 0.4 s, all by 1.2 s); control band black throughout |
| `activation.sh` (setting on) | session and fpwindow identical to native fullscreen; all four steps switch |
| `activation.sh NO` (`616f593`) | identical to native fullscreen (all switch: the system setting governs) |
| `displaymode.sh 54 60` | control/session/fpwindow: other scale with housing — FullPanel follows (1512 × 982, active); no housing — stays fullscreen, `.fallback`/`noCameraHousing`; revert — FullPanel resumes; display mode restored |
| Examples, SpacesHarness | build without warnings |
| Bridges | built only in this run; re-run in full on the release candidate (below) |

### Release candidate `30fa67b` (2026-10-17)

Run on the release-candidate commit itself, same Mac and macOS.

| Check | Result |
| --- | --- |
| `Examples/FullPanelDemo/build-demo.sh`, `Examples/FullPanelAttachDemo/build-demo.sh` | build without warnings |
| FullPanelDemo, AppKit and SwiftUI: native fullscreen, screen capture of the strip | strip filled by the window in both variants; exit restores the window |
| FullPanelDemo: synthetic clicks on the controls beside the housing | counters 2 (left) and 1 (right) after 2 + 1 clicks, both variants |
| FullPanelDemo: pointer to the top edge, then away | menu bar revealed at the top edge (strip covered); strip restored after moving away, both variants |
| Electron 44.7.0: `npm ci`, `npm run build` | no warnings |
| Electron: `npm run autotest` | **63/63**, informational 2/2 |
| Tauri 2.12.3: `cargo build --locked` | no warnings |
| Tauri: `--autotest` | **101/101** |
| winit 0.30.13: `cargo build --locked` | no warnings |
| winit: `--autotest` | **140/140** |
| Each bridge: window A (session) and window B (control) in native fullscreen, screen capture of the strip | A: strip filled with the app's colours (99–100 % non-black); B: black |

Fullscreen was entered through the window's Accessibility `AXFullScreen`
attribute (AppKit's own native fullscreen); clicks and pointer moves were
synthetic `CGEvent`s. Not run on the release candidate: Mission Control
returns and physical clicks for the bridges, and anything in
[MANUAL_ACCEPTANCE.md](MANUAL_ACCEPTANCE.md).

Invocation errors during the run, re-run after correction (not counted as
results): zsh does not split an unquoted `$VAR` of launch arguments; a
missing `-FullPanelAttachShotDir` directory made `screencapture` fail (the
harness now creates it).

### Demo UI update after `96d3006` (2026-10-17)

The two example apps' windows were redesigned; the SDK, bridges and
harnesses did not change. Focused re-checks, same Mac and macOS:

| Check | Result |
| --- | --- |
| `swift test` | 96 tests, 0 failures, 4 skipped (need a display without a housing) |
| Both `build-demo.sh` scripts | build without warnings |
| FullPanelDemo, AppKit and SwiftUI: Control-Command-F (menu item), screen capture of the strip, synthetic clicks, pointer to the top edge and away, exit | strip filled (non-black 1.00) in both variants; counters 2 (left) and 1 (right) after 2 + 1 clicks; menu bar over the strip at the top edge, strip back after moving away; exit restores the exact windowed frame |
| FullPanelDemo with "Use FullPanel" off | ordinary fullscreen: strip black (0.00) |
| FullPanelAttachDemo autotest; AppKit-subclass autotest; lifecycle | **82/82**; **48/48**; **28/28** |
| FullPanelAttachDemo scenario A with Mission Control returns | entry active, strip pixels 0.99; returns where Mission Control closed: recovered, strip pixels 0.99. The other returns failed because the scenario's in-process Escape did not close Mission Control in that session, with the pre-change build as well (a harness input problem, not counted). Re-run from Terminal.app with `run-scenarios.sh` before release |

Input was synthetic. MANUAL_ACCEPTANCE M1 and M2 were not performed.

### Defects found and fixed during this run

| Defect | Evidence | Fix |
| --- | --- | --- |
| Switching the built-in display to a mode without the housing band made FullPanel windows **leave fullscreen** (native fullscreen stays) | `displaymode.sh`: window back at its windowed frame, `.inactive`, still windowed after revert; trace showed the frame guard rejecting AppKit's re-layout while `NSScreen` still had the old mode | `4f3b527`: guard stands aside while `NSScreen` and `CGDisplayBounds` disagree |
| `NSLog` "presentation restore not applied" on **every** normal exit | 1 per exit in every run; final options correct (0) | `8bc2799`: traced, not logged, during AppKit's exit transition |

### Harness defects (not SDK defects)

| Symptom | Cause | Fix |
| --- | --- | --- |
| R1–R3 failed every pixel and Mission Control check while the session reported `.active` (2026-10-16 and on unchanged `9dde660` today) | the relaunched demo was never activated (`appActive=0` throughout), so macOS never showed its restored Space | `5269b99`: activate before checking; R5 reproduces the background case deterministically |
| activation via `open -b` started a different build | another copy shares the bundle identifier | activate by bundle path; `run-scenarios.sh` refuses to start with another copy running |
| R4 / B "band black" passed without a capture | a sample taken while the Space was not shown counted as black | require an actual black capture |
| Command-Tab rows tested the terminal, not the fullscreen app | the desktop's app sits between the two in Command-Tab order | `616f593` |
| lifecycle L3/L4 reused a still-open window | `close()` during a fullscreen transition leaves the window open — for ordinary windows too (AppKit) | pick only newly opened windows; compare against an ordinary window |

### Not run (hardware or a person required)

| Item | Why |
| --- | --- |
| Physical external display: migration, external as main, unplug/replug | none connected (Sidecar results from 2026-10-16 in [WINDOW_LIFECYCLE.md](WINDOW_LIFECYCLE.md)) |
| The 4 screen-release unit tests | need a display without a housing |
| Display sleep/wake | screen lock is immediate on the test Mac; an unattended run would stop at the lock screen |
| Clicks with a trackpad, swipe gestures | need a person (the reveal and clicks were checked with synthetic events on the release candidate) |
| Hot Corners | no Hot Corner configured on the test Mac; configuring one would change the user's settings |
| Dock/Command-Tab with the system setting off | would require changing the user's Desktop & Dock setting; covered on 2026-10-16 with identical results for all modes |
| macOS 15, other notched models | not available |

## Manual acceptance checklist

[MANUAL_ACCEPTANCE.md](MANUAL_ACCEPTANCE.md): everyday use with real
gestures, lock and display sleep, Hot Corners, bridges after Mission Control,
and external displays. Steps, pass and fail criteria, and how to restore the
desktop.

## Diagnostics

- `FullPanelTrace=YES` (launch argument `-FullPanelTrace YES`): timestamped
  engine events and a `window-state` line per lifecycle event, via `NSLog`.
- `FullPanelTraceSampler=YES` with the trace: 30 Hz state samples for 4 s
  after events (Mission Control investigations).
- `diagnostics()` / `fullPanelDiagnostics()`: snapshot including
  `entryPreparedBy`, `adoption`, `screenReleased`, `lastPresentationRestore`,
  `spacesSwitchOnActivate`.
- Sanitizers: `swift test --sanitize=address`; for the demo,
  `NSZombieEnabled=YES MallocScribble=1 MallocGuardEdges=1` and
  `MallocStackLogging=1 leaks --atExit -- <binary> …`.


### Final owner acceptance — 2026-10-19

Owner-reported results for FullPanelKit 0.1.0 on a MacBook Pro 14-inch
(M1 Pro), macOS 27.0.1, using the public-release checkout:

- **M1 — Everyday use:** 8/8 PASS, personally performed. Includes physical
  clicks beside the camera housing, top-edge menu-bar reveal, Mission Control
  returns, Space swipes, clicks after returns, and fullscreen exit.
- **M2 — Lock and display sleep:** 3/3 PASS, personally performed. Includes
  lock/unlock, display sleep/wake, and fullscreen exit/desktop restoration.
- **Restoration scenarios:** 77/77 PASS, 0 FAIL, from `run-scenarios.sh` on
  the public-release checkout: A (11), B (10), R1 (13), R2 (12), R3 (8),
  R4 (8), R5 (15). Expected five rearm events reported for A, R1, R5.
- **Evidence:** Harness output and screenshots retained locally at
  `~/Downloads/FullPanelKit-0.1.0-final-scenarios/`; screenshots were not
  independently reviewed for this acceptance record.

These results supplement the existing automated test evidence and do not
establish support for untested macOS versions, hardware, or external displays.
