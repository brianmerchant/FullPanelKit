# Hardware baseline

Historical record: the hardware-tested probe configuration FullPanelKit was
extracted from (2026-10-10), and every intentional difference from it.
FullPanelKit itself has since been tested on hardware; current results are in
[TESTING.md](TESTING.md) and [COMPATIBILITY.md](COMPATIBILITY.md). The
"Confirm before hardware testing" note below is kept as it was written.

> **References.** Commit hashes in this document identify revisions in
> FullPanelKit's private development history, which is not published
> ([PROVENANCE.md](PROVENANCE.md#public-history)). "Release candidate" means
> the earlier, unpublished 0.1.0 candidate, which used the previous
> fullscreen-frame geometry mechanism.

## Source of truth

| | |
| --- | --- |
| Project | FullPanel Notch Probe v0.4 (maintainer's local repository, not published) |
| Commit | `4660e212551c84211de6af7db6f04b8dac4013e3` (`4660e21`) |
| Tag | `fullpanel-reveal-hardware-tested` |
| Secondary reference | OmacVM `fullpanel` @ `9d8b7443`, `app/runtime/patches/apply-camera-housing-fullscreen.py` |
| Hardware | MacBook Pro 14-inch (2021), Apple M1 Pro, built-in notched Liquid Retina XDR display |
| macOS | macOS 27 |

### Tested preferences (probe defaults domain `dev.fullpanel.NotchProbe`)

| Key | Tested value | FullPanelKit default |
| --- | --- | --- |
| `FullPanelEarlyApply` | YES | YES (built in) |
| `FullPanelOmacVMRevealIntegration` | YES | YES (built in; override key renamed `FullPanelRevealIntegration`) |
| `FullPanelHideTitlebarWindow` | NO | experiment removed (equivalent to NO) |
| `FullPanelLegacyModes` | **not recorded** | NO (common run-loop modes) |
| `FullPanelTrace` | not recorded (diagnostics only) | NO |

**Resolved 2026-10-17:** `defaults read dev.fullpanel.NotchProbe` on the test
Mac shows `FullPanelLegacyModes = 0`, `FullPanelEarlyApply = 1`,
`FullPanelOmacVMRevealIntegration = 1`, `FullPanelHideTitlebarWindow = 0`
(and `FullPanelTrace = 1`), so FullPanelKit's defaults match the tested
configuration. Original note:

`FullPanelLegacyModes` could not be read during extraction (the macOS
preferences domain is not reachable from the extraction environment). NO is
the probe's default when the key is unset. **Confirm before hardware testing:**

```sh
defaults read dev.fullpanel.NotchProbe
```

If it prints `FullPanelLegacyModes = 1`, test the demo with
`open build/FullPanelDemo.app --args -FullPanelLegacyModes YES` as well, and
update the default in `Sources/FullPanelKitCore/FPKSupport.m`.

### Results reported for the probe

- One continuous `NSWindow` and content view spanning the entire display.
- Rendering beside both sides of the camera housing; mouse input in both.
- Genuine native fullscreen Space.
- Mission Control return through the small top Space thumbnail and through the
  large application-window thumbnail.
- Functional menu-bar reveal.
- Acceptable recovery with some remaining visual imperfections. Mission Control
  transitions are **not** seamless.

## Mechanism map

| Mechanism | Probe (`FPWindow.m` / `main.swift`) | FullPanelKit |
| --- | --- | --- |
| `_frameForFullScreenMode` override, ABI guard | `fullPanelFrameHook`, `installPrivateFrameHook` | **Removed.** Replaced by the menu-bar reservation hook (`FPKAppKitHooks.m`, `FPKInstallMenuBarReservationHook`): AppKit lays the window out over the display itself |
| Whole-display frame + camera-safe re-ask | same | **Removed** with it; entry acceptance is `FPKVerifyReservationEntry` |
| Frame guards (5 setters) | `fullPanelShouldGuardFrame`, setter overrides | **Removed**: AppKit's layout under the reservation answer needs no guard |
| SkyLight Space detection + menu-bar alpha | `loadSkyLight`, `fullscreenSpaceID`, `transactionSetAlpha` | `FPKSupport.m` |
| Menu-bar reveal hooks | `fpInstallRevealHooks` | `FPKInstallRevealHooks` (`FPKAppKitHooks.m`) |
| Presentation options | `fpRevealUpdatePresentation`, `fpTryMenuAlpha` | same methods in `FullPanelWindow.m` |
| Top-edge pointer | `fpRevealPointerDidMove` | same; rule in `FPKRevealAllowedAfterPointerMove` |
| Fullscreen toolbar hide/reveal | `fpHideTitlebarNow`, `fpRestoreTitlebar`, `fpRevealApplyToolbar` | same |
| Mission Control / Space return | `fpCheckSpaceReturn`, `fullPanelReapplyMenuIfNeeded`, `fpEarlyApplyIfEligible`, `fullPanelNoteEvent` | same; readiness in `FPKReturnIsReady`; post-0.1 additions: one budget restart at the actual return (`FPKReturnCheckShouldRearm`) and one presentation re-assert per return (`fpReassertPresentationAfterReturn`, `FPKReturnNeedsPresentationReassert`) |
| Compositor readiness | `fpCompositorState` | `FPKCompositorState`; math in `FPKCompositorMatchesFrame` |
| Exit / restore | `fullPanelWillExitFullScreen`, `applicationWillTerminate`, `windowWillClose` | same method + window-owned observers |
| Fallback to ordinary fullscreen | arming checks in `toggleFullScreen:` | same checks; precedence in `FPKArmingDecision` |
| `window:willUseFullScreenContentSize:` → display size | app delegate | **Removed** (`FPKDelegateProxy` and the content-size answer): AppKit already proposes the whole display under the reservation answer |

Since 0.2 the engine methods live in `FPKEngine.m`. They moved from
`FullPanelWindow.m` unchanged except `self` → `window`. In the table above,
`FullPanelWindow.m` now means `FPKEngine.m`. The frame-guard setter overrides
and `toggleFullScreen:` were later removed from `FullPanelWindow.m`. Several
names in the table (`FPKDecideFullScreenFrame`, `FPKInstallRevealHooks`,
`FPKArmingDecision`, …) are from before the independent rewrite and no longer
exist; the table records the mapping as it was.

Engine methods and instance variables keep their probe names (`fpTryMenuAlpha`,
`_fpArmed`, …) so the two files can be diffed side by side.

## Intentional differences from the probe

None of these change the fullscreen code path under the tested configuration
unless noted.

1. **Tested options are the defaults.** `FullPanelEarlyApply` and the reveal
   integration default to YES (the probe read them as opt-in preferences that
   were set to YES for the test). They can still be turned off with user
   defaults for on-hardware A/B checks.
2. **Titlebar-hiding experiment removed** (`FullPanelHideTitlebarWindow`). It was
   NO in the tested configuration and a no-op whenever the reveal integration
   was active. The titlebar hide/restore used by the reveal integration is kept.
3. **Probe-only code removed:** modes 1/2/3, keyboard mode selection, probe
   drawing and labels, the probe report writer, bundle identifier references.
4. **Event forwarding moved into the window.** The probe's app delegate forwarded
   key, active, occlusion, Space, resize, move, screen, enter/exit, close and
   terminate events. `FullPanelWindow` now observes those same notifications
   itself, with the same gating (`mode == .expand` → `fullPanelEnabled`).
   Ordering relative to the application's own delegate may differ slightly.
5. **`willUseFullScreenContentSize:`** was answered by an internal forwarding
   delegate while the session was armed (the probe: whenever FullPanel mode
   was selected). Removed with the frame override: FullPanelKit no longer
   answers it, and the application's delegate is used as is.
6. **Window style set on enable.** The probe's FullPanel mode set
   `.fullSizeContentView` and a transparent titlebar, and always set
   `.fullScreenPrimary`. `fullPanelEnabled = YES` applies the same; NO restores
   prior values.
7. **Logging.** Routine `NSLog` lines are now emitted only with
   `FullPanelTrace=YES`; fallback and API-unavailable messages are still logged.
8. **Occlusion observer for titlebar windows** is registered only for windows with
   FullPanel enabled (it did nothing for others).
9. **State reporting added** (`fullPanelState`, `fullPanelFallbackReason`,
   notification, KVO). Read-only; no effect on behavior.
10. **Decision logic factored into pure functions** (`FPKDecisions.c`) that the
    engine calls. Semantics were preserved; the order of checks in the frame
    guard is unchanged (state checks before calling AppKit).
