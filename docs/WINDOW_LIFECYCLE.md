# Window lifecycle: display migration, activation, teardown

Investigation of three reported problems, 2026-10-16. Hardware: MacBook Pro
14-inch (2021) M1 Pro, macOS 27.0.1 (26A434); built-in display 1800 × 1169 pt
@ 120 Hz, housing band 38 pt. The external display available for this work
was a **Sidecar display** (iPad Air 5, 1539 × 1070 pt, no housing); no wired
monitor was connected. "Displays have separate Spaces" is on.

> **References.** Commit hashes in this document identify revisions in
> FullPanelKit's private development history, which is not published
> ([PROVENANCE.md](PROVENANCE.md#public-history)). "Release candidate" means
> the earlier, unpublished 0.1.0 candidate, which used the previous
> fullscreen-frame geometry mechanism.

> **Mechanism note.** These investigations ran with FullPanelKit's earlier
> whole-display mechanism (a private fullscreen-frame override and frame
> guards). The current code uses the fullscreen content controller's menu-bar
> reservation instead and has no frame override or guards
> ([ARCHITECTURE.md](ARCHITECTURE.md)); mentions of them below describe that
> earlier code. The release and resume logic is unchanged; with the current
> mechanism the display-mode round trip (other scaled mode with a housing, a
> mode without the housing, back) passed once on macOS 27.0.1, and display
> migration to another physical or Sidecar display has not been re-run.

| Report | Cause | FullPanel involved? | Change |
| --- | --- | --- | --- |
| A. A display stays black after a fullscreen window moves to the other display and back | macOS: after a fullscreen Space is dragged to another display in Mission Control, the display it left (or, on the way back, the external display) shows only WindowServer's backstop | No: identical with Preview and with a plain native-fullscreen window | none for the black display; FullPanel now releases its menu-bar, presentation and reveal state while its Space is on a display without a housing, and resumes when it comes back |
| B. Dock click / Command-Tab activates the menu bar but does not show the fullscreen window | This Mac has Desktop & Dock › "When switching to an application, switch to a Space with open windows for the application" **off** (`AppleSpacesSwitchOnActivate = 0`) | No: identical with Preview and with a plain native-fullscreen window | diagnostics report the setting (`spacesSwitchOnActivate`) |
| C. OmacVM #402 use-after-free | OmacVM's FullPanel state kept an unretained window pointer and asked the half-freed window `-isKeyWindow` | FullPanelKit already holds windows weakly and is told when a window is freed | one lifetime leak fixed (post-exit style restore after a detach in fullscreen); regression tests for the window-gone path |

## A. Black display after display migration

### How a fullscreen window moves to another display

- Window menu and the green-button menu: for a fullscreen window, "Move to
  iPad Air 5" (`-_toggleIPad:`) is **disabled**. `-[NSWindow _moveToScreen:]`
  does nothing in fullscreen. A wired monitor's "Move to …" item could not be
  checked here.
- Mission Control: dragging the fullscreen Space's thumbnail from one
  display's Spaces bar to the other's moves the Space and its window. This is
  the path reproduced below (real HID mouse events, `Tools/SpacesHarness`).

### Evidence

Fullscreen on the built-in display → drag to Sidecar → leave Mission Control →
drag back → leave Mission Control. "Black" means WindowServer had only
`Display N Backstop` on screen there (`CGWindowListCopyWindowInfo`), the
capture was 0.00 non-black, while `SLSCopyManagedDisplaySpaces` still named
the display's Desktop as its current Space.

| Window | Leave Mission Control by | After the move to Sidecar | After the move back |
| --- | --- | --- | --- |
| native fullscreen (control) | Escape (originating Space) | built-in **black** | window on built-in; built-in black again once the app quits |
| FullPanelSession | Escape | built-in **black** | same as control |
| native fullscreen (control) | clicking the moved Space | built-in **black** | Sidecar **black** |
| FullPanelSession | clicking the moved Space | built-in **black** | Sidecar **black** |
| Preview (Apple) | clicking the moved Space | built-in **black** | Sidecar **black** |
| control / FullPanelSession | clicking the Desktop left behind | normal | normal |

Not the cause, by elimination:

- **Orphan fullscreen Space**: none. The Space lists were clean (the moved
  Space appears once, on its new display); the black display's current Space
  is its ordinary Desktop.
- **Surviving or hidden window or overlay**: none. Only the backstop is on
  screen there. FullPanel adds no windows; the app's own windows were on the
  other display. Quitting the application does not bring the display back.
- **Stale AppKit fullscreen state** or **presentation options**: no. The
  window reported the right screen, Space and frame on both sides, and the
  same happens with Preview.
- **Frame guards**: not involved. On the move to Sidecar the frame override
  stood aside (`frame-hook not engaged … inset=0`); on the move back the guard
  kept the whole display against AppKit's camera-safe `{1800, 1130}`, so the
  strip beside the housing survives the round trip.

It is a WindowServer / Mission Control state on macOS 27.0.1: the display's
current Space is not shown after the Space it was showing left. Recovery
without restarting anything: enter and leave fullscreen with any window on
that display (Control-Command-F twice). Clicking the black display, Control-
Arrow and selecting its Desktop in Mission Control did not help. Avoidance:
after dragging, click the Desktop left behind before leaving Mission Control.

### What FullPanel did wrong there, and the fix

After its Space moved to Sidecar, the engine still treated the window as a
FullPanel window: the return check committed the menu-bar alpha for the Space
on Sidecar, the presentation options were forced to `FullScreen | HideMenuBar
| HideDock` (0x40A; the Dock could not be revealed in that Space), the reveal
monitor stayed on, and the session reported `.active`.

Now (`FPKScreenReleasesSession`, `FPKScreenResumesSession`,
`-[FPKEngine fpkScreenChanged]`) a fullscreen Space on a display without a
housing is ordinary fullscreen: menu-bar alpha 1, AppKit's own fullscreen
presentation (0x405), titlebar and reveal monitor restored, no return checks,
no claim on the band, `.fallback` with `.noCameraHousing`. The entry stays armed:
back on the built-in display in the same Space the window still has the whole
display, and the menu bar is committed again once the window is key on the
active Space (`.active`, 0x40A). A window that briefly has no screen during a
display reconfiguration is neither. Verified on hardware for
`FullPanelSession` and `FullPanelWindow` (built-in → Sidecar → built-in,
Command-Tab on each side, exit).

## B. Dock click and Command-Tab

`defaults read -g AppleSpacesSwitchOnActivate` is `0` on this Mac. AppKit
reads the key in the application's own process: with
`-AppleSpacesSwitchOnActivate YES` in a test application's argument domain
(no system setting changed) the same application switches Spaces on
activation.

`Tools/SpacesHarness/activation.sh`, real Command-Tab and Dock presses
(Accessibility), another application (SpacesOther) active before each step:

| Step | This Mac's setting (off) | Setting on (app argument domain) |
| --- | --- | --- |
| Dock click, other app on the desktop | menu bar only | switches to the fullscreen Space |
| Command-Tab, other app on the desktop | menu bar only | switches |
| Command-Tab, other app in its own fullscreen Space | menu bar only | switches |
| Dock click, other app in its own fullscreen Space | menu bar only | switches |

The results are identical for native fullscreen (control),
`FullPanelSession` and `FullPanelWindow`, and Preview behaved the same with
the setting off. When the previously active application was itself a
fullscreen window in another Space, macOS sometimes switched even with the
setting off; again identical for all three.

FullPanel's window attributes were audited: it adds only
`NSWindowCollectionBehaviorFullScreenPrimary` (restored on disable), never
`managed`/`moveToActiveSpace`/`canJoinAllSpaces`/`transient`/`stationary`/
`ignoresCycle`/`fullScreenAuxiliary`, and does not change key/main eligibility,
level, hiding or Windows-menu membership (unit test). Presentation options and
the menu-bar alpha are per application / per Space and played no part.

To get native navigation back, turn the setting on (System Settings › Desktop
& Dock › Mission Control). FullPanelKit does not change it, and uses no
synthetic shortcuts or private Space selection. `diagnostics()` reports it as
`spacesSwitchOnActivate`.

## C. Window lifetime (OmacVM #402 / #414)

OmacVM's crash: during a display unplug, macOS took a window out of
fullscreen, the application closed it, and when AppKit released it the
window's FullPanel state (an associated object) was freed with it; the
state's `-dealloc` asked the half-freed window `-isKeyWindow`. #414 hangs the
state on the window through an owner that tells it `windowGone` first.

FullPanelKit audit:

| Area | Finding | Status |
| --- | --- | --- |
| Engine → window reference | `__weak` (ARC). A weak load of a deallocating object returns nil, so teardown under `-[NSWindow dealloc]` never messages the window. | Safe. `WindowLifetimeTests` fail deterministically when the reference is made `__unsafe_unretained` (the #402 pattern): the engine then sends the deallocating window `setAcceptsMouseMovedEvents:` and `styleMask`. |
| Session owner | `FPKSessionOwner` (associated object) calls `-fpkWindowDidDeallocate` → engine teardown, as #414 does. | Already the #414 design. |
| `FullPanelWindow` | `-dealloc` → engine teardown; engine is an ivar. | Safe (test). |
| Notification observers | Block observers with a weak engine; removed at teardown, detach and window deallocation. | Safe. |
| NSApp KVO, event monitor | Removed in reveal teardown (also from engine `-dealloc`). | Safe. |
| Return checks, sampler (`performSelector:afterDelay:`) | Retain the engine; cancelled at every exit/teardown; read the window weakly. | Safe. |
| Presentation re-assert (`dispatch_async`) | Weak engine; bails out once the session ended. | Safe (existing test). |
| Reveal hook (`dispatch_async` off-main) | Retains the engine briefly; acts only while reveal is active. | Safe. |
| Detach during fullscreen (`-restoreStyleAfterFullScreen:`) | One-shot observers, filtered on the window's address, held the engine until the window exited fullscreen or closed. A window freed without either kept them (and the engine) forever, registered for an address a later window may reuse. | **Fixed**: they end when the window is freed (a window-gone handler, keyed per pending restore so a second detach does not cancel the first). |
| Teardown presentation restore with the window gone | Restores the value captured inside fullscreen (may contain the FullScreen bit). macOS 27 ignores the bit outside fullscreen (no exception; read back 0). | Harmless; logs "restore not applied". |
| `FullPanelStatus` | Window-filtered observers outlive a freed window until the status is released; handler holds the status weakly. | Harmless; noted. |
| Electron / Tauri / Winit bridges | Weak references; raw handles validated against `NSApp.windows` before use. Electron's `FPEUndoStyleGrowthAfterFullScreen` has the same one-shot observer pattern as above. | Follow-up (not changed: no runnable tests here). |

## Changes

- `FPKEngine`: screen release/resume (above); `-fpkReleaseSystemState:endingEntry:`
  split from the exit reset (exit path unchanged in order and effect); opt-in
  `window-state` trace; diagnostics `screenReleased`, `screenDisplayID`,
  `screenHasCameraHousing`, `windowNumber`, `collectionBehaviorRaw`,
  `isKeyWindow`, `isMainWindow`, `isVisible`, `appActive`,
  `spacesSwitchOnActivate`.
- `FPKDecisions`: `FPKScreenReleasesSession`, `FPKScreenResumesSession`,
  `FPKFullScreenFallbackReason`.
- `FullPanelSession`: post-exit style restore ends with the window.
- `FPKSupport`: `FPKSpacesSwitchOnActivate()`.
- `Tools/SpacesHarness`: hardware harness for activation and migration.

### Trace

With `FullPanelTrace=YES`, one `window-state` line per lifecycle notification
(enter/exit, screen change, display parameters, close, teardown), logged only
when the state changed: window number, display ID and housing, frame,
fullscreen, key/main/visible/occlusion, on active Space, Space ID, collection
behavior, application active, presentation options, and the engine's
enabled/armed/accepted/screen-released/submitted/state. A freed window logs
`window=gone`. About 40 lines for a fullscreen entry, five Mission Control
returns and the exit.

## Tests

`swift test`: 95 tests (80 before). New: `WindowLifetimeTests` (5),
`DisplayAndActivationTests` (10).

Against the baseline (17a34d5), the new behavioral tests fail as expected:
no screen release and a return check started on a display without a housing,
state not updated, diagnostics missing, and the engine kept alive by the
post-exit style restore. The deallocating-window, double-detach and
activation-attribute tests pass on both (they guard existing behavior).

Hardware (this Mac, after the change):

- `run-scenarios.sh`: A fresh entry 11/11 with 5 Mission Control returns
  (away/rearm/ready/reassert 5/5/5/5); B attach inside fullscreen 10/10;
  R4 late attach 6/6. R1–R3 (restored into fullscreen) failed the pixel and
  Mission Control-return checks, and fail the same way on unchanged `main`
  (17a34d5), so they are not a regression from this change. The restore
  path of the harness never activates the relaunched application before it
  checks window visibility (`appActive=0` in the new trace), so its Space is
  never shown while another application is in use. Another copy of the demo
  with the same bundle identifier was also running and may have contributed.
  R4's pass is weaker than it looks: its existing visibility check does not
  by itself establish that the window was shown in its fullscreen Space.
  Fixing the restore harness is a separate follow-up (Remaining risks).
- `Tools/SpacesHarness`: migration (both directions, three ways of leaving
  Mission Control) and activation matrix as above.
- Builds: FullPanelDemo, FullPanelAttachDemo, Winit and Tauri crates, Electron
  addon (Electron 44.7.0 headers): no warnings. The test target was not
  warning-free at first: `DisplayAndActivationTests.swift` had six Swift
  concurrency warnings (main-actor `NSWindow` properties read from the
  nonisolated `Attributes` initializer). The initializer is now
  `@MainActor`; the test target recompiles without warnings.

## Manual checklist

Use `FullPanelAttachDemo` (or the integration under test) with
`-FullPanelTrace YES`, and repeat each step with an **ordinary fullscreen
window as control** (FullPanelAttachDemo › Ordinary Window, or Preview). For
each, note whether the control behaves the same.

1. **Built-in → external → built-in.** Fullscreen on the built-in display.
   Mission Control: drag the window's Space to the external display; click the
   Desktop left behind. Expect: window on the external display, ordinary
   fullscreen menu bar and Dock there, `state` `.fallback` / `.noCameraHousing`.
   Drag it back; click the external Desktop; Command-Tab to the app. Expect:
   content beside the housing again, `.active`. Repeat leaving Mission Control
   with Escape and by clicking the moved Space: a black display is expected
   (macOS); recover with Control-Command-F twice on that display. If a wired
   monitor offers "Move to …" for a fullscreen window, try that path too.
2. **Dock click.** From another app on the desktop, click the app's Dock icon.
   With "switch to a Space with open windows" off: menu bar only (same as the
   control). On: its fullscreen Space is shown.
3. **Command-Tab.** Same as 2, from the desktop and from another app's
   fullscreen Space.
4. **Mission Control exit/return.** Open Mission Control in the FullPanel
   Space; return through the small Space thumbnail, the large window
   thumbnail, and Escape. The band beside the housing comes back within ~2 s.
5. **Fullscreen exit.** Control-Command-F: windowed frame restored; menu bar
   normal in every Space; `presentation-restore` in the trace.
6. **Unplug / replug the external display** (wired), with the FullPanel
   window in fullscreen on the built-in display, and again with an ordinary
   fullscreen window on the external display. Expect no crash, no stray
   Spaces, FullPanel still `.active` on the built-in display.
7. **External display as main** (it has the menu bar): unplug and reconnect
   it with the FullPanel window in fullscreen on the built-in display. Expect
   the same as 6; `screen-release` must not appear for the built-in display.

## Remaining risks

- Display migration was verified with Sidecar only (built-in ↔ Sidecar,
  `FullPanelSession` and `FullPanelWindow`). Unverified on hardware: migration
  to and from a physical external display (different display IDs, a
  "Move to …" path that may work in fullscreen), disconnect/reconnect
  (checklist 6), and an external display as main (checklist 7).
- The black display after a Mission Control drag is not fixed (macOS); only
  the recovery and avoidance are known.
- ~~Restoration scenarios R1–R3 remain unverified~~ — resolved 2026-10-17
  (see the update below): a harness defect; all pass with the harness fixed.
- `FullPanelStatus` and the Electron bridge keep window-filtered observers
  after a window is freed (harmless today; noted for a follow-up).

## OmacVM follow-ups

OmacVM's FullPanel (`ui/cocoa.m` patches) is a separate implementation. These
FullPanelKit findings may apply:

1. Bugs A and B are macOS behavior and will look the same in OmacVM
   (document the recovery and the Desktop & Dock setting in its
   troubleshooting).
2. Display migration: `-usable` checks the housing on each refresh and
   `-updateMenuBarHidden` shows the menu bar when unusable, but
   `omacvm_fp_strip_lost` may latch `area_lost` and keep the session in
   normal fullscreen after the Space comes back to the built-in display.
   FullPanelKit's evidence: the whole-display frame survives the round trip;
   consider resuming instead of latching. Check with a Mission Control drag.
3. `-showMenuBar` (also run from `-windowGone` and `-dealloc`) sets the
   app-global presentation options from this window's state only. With one
   window per display, check that a closing window cannot release options
   another FullPanel window still forces (FullPanelKit skips the restore
   while another engine owns them).
4. One-shot observers keyed on a window address (the pattern fixed here in
   `-restoreStyleAfterFullScreen:`): check that every observer added for a
   window is removed in `-windowGone`, not only at fullscreen exit or close.
5. `-scheduleRefresh:` / `-finishReturn:` blocks retain the state under MRC
   for up to 2 s; they are safe after #414 only because `-windowGone`
   clears `window`. Keep that invariant if the owner pattern changes.

## Update 2026-10-17 (0.1.0 release candidate)

Same Mac, macOS 27.0.1. Details and logs: [TESTING.md](TESTING.md).

- **R1–R3 were harness failures.** Reproduced on unchanged `9dde660`: the
  relaunched demo was never active (`appActive=0` throughout), so macOS never
  showed the restored Space, while the session correctly reported `.active`.
  With the harness activating the app first, R1–R3 pass; R5 reproduces the
  background case on purpose and passes (no commit while the Space is not
  shown; commit, pixels and Mission Control returns after a Dock-equivalent
  activation). Activating by bundle identifier (`open -b`) launched a
  different build of the demo; the harness now activates by path.
- **Activation with the setting on** (`AppleSpacesSwitchOnActivate = 1`, the
  macOS default): Dock click and Command-Tab switch to the fullscreen Space
  in all four steps, identically for native fullscreen, `FullPanelSession`
  and `FullPanelWindow`. With `-AppleSpacesSwitchOnActivate NO` in SpacesLab's
  argument domain only, all three still switch, so the per-application value
  does not override the system setting in that direction (the earlier "YES in
  the argument domain switches with the system setting off" result stands).
  The 2026-10-16 Command-Tab rows were re-checked after a harness fix (the
  desktop's application was between SpacesOther and SpacesLab in Command-Tab
  order). No FullPanel difference; no workaround.
- **Display-mode change (new, fixed).** Switching the built-in display to a
  mode without the housing band while in FullPanel fullscreen made AppKit
  *leave fullscreen* (native fullscreen stays): AppKit re-lays out the
  window for the new mode while its `NSScreen` still describes the old one,
  and the frame guard rejected that layout. The guard then stood aside while
  `NSScreen` and `CGDisplayBounds` disagreed (`FPKScreenGeometryCurrent`);
  the guards and that check were later removed with the frame override, and
  AppKit's own layout handles the mode change.
  `Tools/SpacesHarness/displaymode.sh`: FullPanel stays fullscreen there as
  `.fallback`/`noCameraHousing` and resumes when the mode returns; a change
  to another scaled mode with a housing keeps FullPanel. This is the first
  hardware run of the release/resume path without a second display.
- **Close during a fullscreen transition**: `close()` 150 ms into an entry or
  exit leaves the window open and windowed on macOS 27.0.1, for ordinary
  windows too. FullPanel leaves no menu-bar override or forced presentation
  behind.
- Still not run: a physical external display (checklist items 1, 6, 7),
  display sleep/wake (the test Mac locks immediately).
