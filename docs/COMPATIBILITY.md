# Compatibility

Evidence-based: "verified" means an automated or recorded hardware run,
listed in [TESTING.md](TESTING.md). Everything else is labelled. Nothing is
claimed for configurations that were not run.

> **References.** Commit hashes in this document identify revisions in
> FullPanelKit's private development history, which is not published
> ([PROVENANCE.md](PROVENANCE.md#scope-of-this-release)). "Release candidate" means
> the earlier, unpublished 0.1.0 candidate, which used the previous
> fullscreen-frame geometry mechanism.

**Geometry mechanism.** This release uses the fullscreen content
controller's menu-bar reservation (ARCHITECTURE.md). On macOS 27.0.1 its
release tree passed the unit, sanitizer, consumer, autotest, lifecycle and
bridge suites and 100 Mission Control thumbnail returns (TESTING.md, "MIT
release candidate"); entry and exit, Space returns, Dock and Command-Tab,
state restoration, display-mode changes, Split View, lock and sleep were
hardware-tested in bounded runs of the same mechanism. The release-candidate
results in TESTING.md were recorded with the earlier mechanism (a private
fullscreen-frame override plus frame guards). Rows below that depend on the
mechanism say which one their evidence used.

**Deployment target versus verified behaviour.** The package builds for
macOS 13 and later. That is a compilation floor, not a support claim:
FullPanel behaviour is verified only where the table says so. Elsewhere, if
the private method is missing, has a different signature or was replaced by
other code, FullPanelKit uses ordinary native fullscreen and reports
`.fallback` / `.appKitUnavailable`; a system where the method exists but
behaves differently is not detected in advance (each entry is still verified
before it is accepted).

## macOS and hardware

| Configuration | Status | Evidence |
| --- | --- | --- |
| macOS 27.0.1 (26A434), MacBook Pro 14-inch 2021, M1 Pro, built-in notched display | **Verified** | Menu-bar reservation mechanism (this release), 2026-10-19: release suite and 100 Mission Control returns on the release tree (TESTING.md, "MIT release candidate"), plus earlier bounded runs. Release candidate (frame-override mechanism): full hardware suite on SDK code of `601d06a`, 2026-10-17 |
| macOS 27.0 (earlier build), same Mac | Verified 2026-10-11 to 10-14 on earlier SDK commits (frame-override mechanism) | ATTACHMENT.md, RESTORED_FULLSCREEN.md |
| macOS 15.8.1 | **Not verified.** Static inspection only (2026-10-18, repeated 2026-10-19 on the same image): in the AppKit of a non-booted 15.8.1 installation, the fullscreen content controller class has `-reservesSpaceForMenuBarInFullScreen` (its only implementer) and `-window` by symbol name. Their type encodings could not be read statically and the runtime behaviour was not checked; nothing ran on macOS 15 with the current mechanism | A hand check on 2026-10-14 (FullPanel fullscreen, Mission Control returns, two windows restored into fullscreen) exercised the earlier frame-override mechanism and does not apply to the current code |
| Other macOS releases (13, 14, 26, later 27.x) | Untested. No runtime claim | Compiles for a macOS 13 deployment target; that is not a support claim. Where the reservation method is missing, differs or was replaced by other code, entries are ordinary fullscreen (`.appKitUnavailable`) |
| Other notched Macs (MacBook Air, 16-inch MacBook Pro, other housing sizes) | Untested | Geometry comes from `NSScreen` at runtime; nothing is hard-coded, but nothing was run |
| Intel Macs | Untested (no notched Intel Mac exists) | — |

## Displays

| Display situation | Behavior | Status |
| --- | --- | --- |
| Built-in notched display | FullPanel (`.active`) | Verified |
| Built-in display, other scaled mode with housing (1800 × 1169 → 1512 × 982 and back, in fullscreen) | FullPanel follows the new size | Verified (`displaymode.sh`) |
| Built-in display switched to a mode without the housing band, in fullscreen | Stays fullscreen as ordinary fullscreen, `.fallback` / `.noCameraHousing`; FullPanel resumes when the mode returns | Verified after fix `4f3b527` |
| Display without a housing (external, Sidecar) at entry | Ordinary fullscreen, `.fallback` / `.noCameraHousing` | Verified with Sidecar (2026-10-11, 10-16) |
| FullPanel Space dragged to a display without a housing in Mission Control, and back | Ordinary fullscreen there; FullPanel again on return | Verified with **Sidecar** only (2026-10-16) |
| Physical external display: migration, as main display, unplug/replug while in FullPanel | Designed to release/resume as above | **Not verified** (no wired display available) |
| Display sleep and wake, lock screen | FullPanel again after unlock or wake | **Verified on release code**: owner-performed manual M2 3/3 PASS, 2026-10-20 ([TESTING.md](TESTING.md)); earlier attended runs also passed |
| Split View on the notched display | Ordinary tile, `.fallback` / `.frameNotAccepted` | Decision unit-tested; one hardware run with the menu-bar reservation mechanism (macOS 27.0.1): the tile matched native Split View, and FullPanel worked again on the next entry |
| "Always show menu bar in full screen" on | Ordinary fullscreen, `.menuBarAlwaysShown` | Decision unit-tested; not re-run on hardware for 0.1.0 |
| "Displays have separate Spaces" off | — | Untested |

Known macOS behavior that is not FullPanel's (identical with native
fullscreen and Preview): a display can stay black after a fullscreen Space is
dragged between displays in Mission Control (macOS 27.0.1); recovery and
avoidance are in [WINDOW_LIFECYCLE.md](WINDOW_LIFECYCLE.md).

## Window types and entry paths

| | Status |
| --- | --- |
| `FullPanelWindow` (AppKit, created by the app) | Verified |
| `FullPanelSession` on a SwiftUI `WindowGroup` window | Verified |
| `FullPanelSession` on an app's own `NSWindow` subclass (with `NSWindowController`, own delegate) | Verified (autotest, AppKit-subclass mode) |
| Plain `NSWindow` / `NSPanel` instances | **Unsupported**: refused with `.unsupportedWindowClass` (verified) |
| Windows whose class is changed by isa-swizzling libraries other than KVO | Unsupported |
| Window classes swizzled by other libraries | FullPanelKit adds no method to any window class, so there is nothing to compose with; untested |
| Another library replacing `-[_NSFullScreenContentController reservesSpaceForMenuBarInFullScreen]` | Before FullPanelKit: FullPanelKit does not install, entries are ordinary fullscreen (`.appKitUnavailable`; verified without hardware). After: later entries are ordinary fullscreen (unit-tested) |
| Entry with the green button, View ▸ Enter Full Screen, Control-Command-F, `toggleFullScreen(_:)` | Verified |
| Windows AppKit restores into fullscreen at launch (attached before or inside the entry's `willEnterFullScreen`) | Verified (R1–R3, R5; R1 and R3 also with the menu-bar reservation mechanism) |
| Attached or enabled after the entry began / already fullscreen | Reported (`.fallback`, `adoption`), FullPanel from the next entry — verified (B, R4) |
| Several FullPanel windows of one app, each in its own fullscreen Space | Verified (lifecycle L5, R2) |
| Closing a window in fullscreen, or during its entry/exit animation | Verified; during a transition macOS keeps the window open (ordinary windows too) |
| Non-native ("old-style") fullscreen | Not affected: FullPanel only changes native fullscreen |

## Mission Control, Spaces and activation (macOS 27.0.1)

| | Status |
| --- | --- |
| Escape (originating Space), large preview, small thumbnail, large preview then small thumbnail, from another Space via the thumbnail, Control-arrow Space switches | Release candidate (frame-override mechanism): verified, 3 cycles each for session and fpwindow, band rendered at the 0.4 s sample on all 36 returns in the final run (35 of 36 in an earlier run, all by 1.2 s). Menu-bar reservation mechanism, `FullPanelWindow`: bounded runs of 10 returns per configuration (small thumbnail in the Space, thumbnail from another Space, large preview), every return completed with native-fullscreen latencies; that earlier six-path comparison suite was not repeated with the reservation mechanism; separate release-code restoration scenarios A, B and R1–R5 passed 77/77 |
| Repeated returns | **Release code verified:** 5 expected Mission Control returns each in A, R1 and R5; restoration suite 77/77 PASS ([TESTING.md](TESTING.md)) |
| Trackpad swipe gestures | **Manually verified** in owner-performed M1 8/8 PASS on release code, 2026-10-20 ([TESTING.md](TESTING.md)); not automated |
| Dock click / Command-Tab with "switch to a Space with open windows" on | Same as native fullscreen: switches (verified) |
| Same with the setting off | Same as native fullscreen: activates the menu bar only (verified 2026-10-16) |
| Menu-bar hover reveal at the top edge | Verified on the release candidate with synthetic pointer moves: no reveal inside the strip, reveal at the top edge, strip restored after moving away (screen captures) |
| Hot Corners while in FullPanel fullscreen | Untested (no Hot Corner configured on the test Mac); FullPanelKit forces its own presentation options while the strip is shown, so behaviour may differ from native fullscreen. Manual check: MANUAL_ACCEPTANCE.md, M3 |

Mission Control is not seamless: the band can show black or Mission
Control's backdrop for a fraction of a second after a return.

## Frameworks and integrations

Per-integration evidence, revisions and gaps: [INTEGRATION_EVIDENCE.md](INTEGRATION_EVIDENCE.md).

| Integration | Uses | Status on the release candidate |
| --- | --- | --- |
| AppKit (`Examples/FullPanelDemo`) | `FullPanelWindow` | Hardware verified |
| SwiftUI `WindowGroup` (`Examples/FullPanelAttachDemo`) | `FullPanelSession`, `FullPanelStatus` | Hardware verified |
| Electron 44.7.0 (`Integrations/Electron`) | core sources via a Node-API addon | Experimental: automated suite and real strip capture; Mission Control not re-verified |
| Tauri 2.12.3 (`Integrations/Tauri`) | core sources via `cc` | Experimental: automated suite and real strip capture; Mission Control not re-verified |
| winit 0.30 (`Integrations/Winit`) | core sources via `cc` | Experimental: automated suite and real strip capture; Mission Control not re-verified |

Other frameworks (Qt, Flutter, Java/AWT, Catalyst and so on) are untested.
They need a window whose class is not one of AppKit's own (see
[ATTACHMENT.md](ATTACHMENT.md)).

## Build requirements

- Swift 5.9 tools or newer; tested with Xcode 27.1 / Swift 6.4.
- `platforms: [.macOS(.v13)]` is the compile floor.
- No package dependencies. Links AppKit and CoreGraphics; SkyLight is
  loaded with `dlopen` at runtime.

## Private API

FullPanelKit depends on undocumented AppKit and SkyLight interfaces; the
list, the runtime checks and what cannot be detected are in
[ARCHITECTURE.md](ARCHITECTURE.md), "Public, implementation-dependent and
private". Private API use is grounds for Mac App Store rejection (App Review
Guideline 2.5.1): treat FullPanelKit as unsuitable for the Mac App Store.

## Known limitations

- Already-fullscreen windows are not adopted in place; FullPanel applies from
  the next entry.
- FullPanelKit never forces a frame. If AppKit does not lay a claimed entry
  out over the display, the entry is rejected at didEnterFullScreen and is
  ordinary fullscreen.
- A crash or `kill -9` while in FullPanel fullscreen can leave that Space's
  menu bar transparent until the Space closes.
- Menu-bar transparency is "submitted", not observed, by the code.
- Windows that change `.fullSizeContentView` themselves: enabling FullPanel
  adds it, and macOS keeps the content rect when the flag changes, so a
  framed window's frame grows or shrinks by the titlebar height on enable and
  disable. Create windows with a full-size content view and transparent
  titlebar to avoid the shift.
- One method of AppKit's private fullscreen content controller class stays
  replaced for the life of the process once FullPanel is first enabled (it
  returns AppKit's own answer for windows without a FullPanel entry). No
  window class is modified, and delegates are never wrapped.
