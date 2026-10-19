# Architecture

```
FullPanelKit (Swift)                 FullPanelKitCore (Objective-C)
├─ Exports.swift  ──@_exported──▶    ├─ include/  public headers + module.modulemap
├─ FullPanelLayout.swift             │    FullPanelWindow.h, FullPanelSession.h,
└─ SwiftUISupport.swift              │    FullPanelDisplayGeometry.h, FullPanelTypes.h
                                     │    FPKDecisions.h (submodule .Decisions, tests only)
                                     ├─ FPKEngine.m            the engine (one per window)
                                     ├─ FullPanelWindow.m      subclass host of the engine
                                     ├─ FullPanelSession.m     attachment host of the engine
                                     ├─ FPKAppKitHooks.m       the menu-bar reservation hook (private AppKit)
                                     ├─ FPKMenuBarOverlay.m    SkyLight menu-bar backdrop override
                                     ├─ FPKFullScreenTitlebar.m reveal sensing (titlebar window)
                                     ├─ FPKSupport.m           WindowServer queries, options, trace
                                     ├─ FPKDecisions.c         pure decision logic
                                     └─ FullPanelDisplayGeometry.m
```

Two targets exist only because SwiftPM cannot mix Objective-C and Swift in one
target. Applications import `FullPanelKit` and get both. The Electron, Tauri
and winit bridges compile the same `FullPanelKitCore` sources directly.

## One engine, two hosts

There is exactly one fullscreen engine, `FPKEngine`: one object per window,
holding all of that window's FullPanel state and holding the window weakly.

| Host | For | How the engine is found |
| --- | --- | --- |
| `FullPanelWindow` | windows the application creates as FullPanelKit's class | the window's own engine (an instance variable); the class overrides no `NSWindow` method besides its initializers and `-dealloc` |
| `FullPanelSession` | an existing window: a SwiftUI `WindowGroup` window or an app's own `NSWindow` subclass | an associated object of the window; the window's class, runtime class and method implementations are not changed |

Neither host modifies a window class. Both hosts' engines are reached from
the one private hook (below) through `FPKEngineForWindow`.

The host publishes state (KVO keys, notification) through the
`FPKEngineHost` protocol. The SwiftUI layer (`FullPanelStatus`,
`\.fullPanel`, `FullPanelRootView`) only reads state; it has no fullscreen
logic of its own.

## What changes in fullscreen

FullPanel never adds overlay windows and never starts or ends fullscreen. The
application's window enters AppKit's own fullscreen Space, and three things
change for that window only:

1. **Layout.** For each fullscreen window AppKit creates a private content
   controller (`_NSFullScreenContentController`) and asks it
   `-reservesSpaceForMenuBarInFullScreen`; beside a camera housing the answer
   is YES, and AppKit lays the window out below the band. FullPanelKit
   replaces that one method: it asks AppKit first and turns YES into NO only
   for a window whose engine claims the band (enabled, armed, in its entry or
   session, not rejected, beside a housing). AppKit then lays the window out
   over the whole display itself, and keeps doing so through Mission
   Control, Space switches and display-mode changes (measured on macOS
   27.0.1 only). FullPanelKit sets no
   frame and rejects none of AppKit's frame changes.
   - **Accepting an entry (P1).** The entry is accepted when the fullscreen
     window is seen covering its screen beside the housing: during the entry
     animation as soon as it covers, and definitively at didEnterFullScreen.
     An entry that does not cover the display there (a Split View tile) is
     rejected: the hook stops claiming the band, AppKit re-lays the tile out
     camera-safe, and the session reports `.fallback` / `.frameNotAccepted`.
2. **Menu bar.** The fullscreen Space's menu-bar layer covers the band beside
   the housing. FullPanelKit finds the window's own fullscreen Space with
   SkyLight (Space type 4) and submits a per-Space menu-bar alpha of 0 in a
   SkyLight transaction. "Submitted" is all the code can know; the pixel
   result is verified only by the hardware harnesses.
3. **Presentation options.** `FullScreen | HideMenuBar | HideDock` (0x40A) is
   forced while the window is key and no reveal is wanted. When the pointer
   reaches the very top edge, or a reveal is on screen, AppKit's own
   fullscreen policy is put back so the menu bar can be revealed on purpose.

One reconciler applies all three kinds of system state: observed facts (key,
active Space, reveal requested, reveal visible, …) go through the pure
function `FPKIntentForFacts`, and one apply step sets the menu-bar overlay,
the presentation options and the titlebar window's click-through. A reveal
is seen through AppKit's fullscreen titlebar window, whose `alphaValue`
AppKit animates with the reveal (KVO, public API apart from the class name
`NSToolbarFullScreenWindow`); `+[NSMenu menuBarVisible]` is the fallback when
no titlebar window exists. Nothing in AppKit is swizzled for this; the
reservation method is the only AppKit method FullPanelKit replaces.

## Lifecycle

```
enable / attach (windowed)
   ▼
entry prepared ── willEnterFullScreen          (every native entry, including restoration)
              ── reservation request          (host attached inside willEnterFullScreen)
   arming: housing? reservation method + encodings, not replaced by other code? SkyLight?
           menu bar not always shown?
   ▼ armed                                   ▼ not armed → ordinary fullscreen, .fallback + reason
reservesSpaceForMenuBarInFullScreen ─▶ NO for this window: AppKit lays it out over the display
   ▼
covers the display ─▶ accepted (P1); didEnterFullScreen confirms or rejects (.fallback / frameNotAccepted)
   ▼
didEnterFullScreen ─▶ menu-bar alpha 0, reveal integration, forced presentation
   ▼
key / active / occlusion / Space / move / resize ─▶ return handling (below)
screen change / display parameters ─▶ release beside no housing, resume beside one
   ▼
willExitFullScreen / close / terminate / disable / detach / window freed
   ─▶ alpha 1, presentation restored, titlebar click-through restored, monitors, KVO and timers removed
```

Rules that make the lifecycle predictable:

- **Prepare at the entry's start.** Every native entry posts
  willEnterFullScreen first, which prepares it. A host that attaches inside
  that notification is not told about it, so AppKit's reservation question
  for the entry prepares it instead (P2): only when FullPanel was enabled
  while the window was windowed and nothing prepared an entry since. AppKit
  asks once before the style mask has `FullScreen` (not prepared), then
  again with it. A session enabled in a fullscreen session that is already
  under way is reported (`.fallback`, `diagnostics()["adoption"]`), not
  adopted, and the next entry is a FullPanel entry. Details:
  [RESTORED_FULLSCREEN.md](RESTORED_FULLSCREEN.md).
- **Detach in fullscreen** makes the hook answer AppKit's YES again; AppKit
  re-lays the window out camera-safe at once (ordinary fullscreen).
- **Close is not detach.** On close, system state is restored but the session
  stays attached (an AppKit window can be shown again). When the window is
  freed, its owner object detaches the session; the engine reads the window
  through a weak reference, so nothing messages a deallocating window.
- **Detach inside fullscreen** restores system state at once and the window
  style after the exit (a one-shot observer that also ends with the window).
- **Main thread only**, like `NSWindow`.

Memory and lifetime (audited 2026-10-17, see [TESTING.md](TESTING.md)):

| Resource | Owner | Ends at |
| --- | --- | --- |
| Engine → window | `__weak` | — (reads nil once the window deallocates) |
| Session | the window, via an associated owner object | window deallocation or `detach()` |
| Notification observers | engine (block observers with a weak engine) | teardown, detach, window freed |
| NSApp KVO (`currentSystemPresentationOptions`), local event monitor | engine | tracking stop, also from engine `-dealloc` |
| Titlebar-window KVO (`alphaValue`), occlusion observer, saved `ignoresMouseEvents` | `FPKFullScreenTitlebar` (held by the engine) | tracking stop, also from its `-dealloc` |
| Return checks, trace sampler (`performSelector:afterDelay:`) | retain the engine while pending | cancelled at every exit, release and teardown |
| Presentation re-assert (`dispatch_async`) | weak engine | bails out once the session ended |
| Post-exit style restore after a detach | one-shot observers | exit, close or window freed |
| Menu-bar reservation replacement on AppKit's content controller class | process | never removed; AppKit's answer for every window without a claiming engine |

## Presentation restoration

`NSApp.presentationOptions` is application-wide, so FullPanelKit tracks which
engines currently force them (`fpForcingEngines`). When an engine stops
forcing (exit, close, disable, detach, display without housing):

- inside native fullscreen it restores AppKit's own fullscreen policy recorded
  at entry (with the application's `window:willUseFullScreenPresentationOptions:`),
  not the pre-fullscreen value, which AppKit reads back as a hidden menu bar
  and Dock;
- outside fullscreen it restores the windowed value saved at entry;
- it restores nothing while another FullPanel window that is key in
  fullscreen still forces the options (two fullscreen windows of one app).

The result is read back and logged when AppKit did not apply it
(`diagnostics()["lastPresentationRestore"]`).

## Mission Control and Space returns

Mission Control animates the window's WindowServer presentation without
changing `NSWindow.frame`, and AppKit restores its revealable options while
the Space is still animating in. On every return signal (key, active,
occlusion visible, active Space, move, resize):

1. **Away tracking.** Leaving the Space, key or visible state since the last
   commit marks the window "away".
2. **Early commit.** Once per return, as soon as the window is the visible key
   window on the active Space, the menu-bar alpha is committed again
   (`FullPanelEarlyApply`, default on).
3. **Compositor-verified commit.** A bounded check (120 polls at 60 Hz,
   restarted once at the actual return, so ≤ ~4 s) waits until WindowServer's
   bounds for the window match its AppKit frame, then commits.
4. **Presentation re-assert.** After a return from away, the forced options
   are released and re-forced on the next run-loop turns and the alpha is
   committed again — the order a top-edge reveal ends with. Once per return;
   never at fullscreen entry. Without it, macOS 15 kept the fullscreen menu
   bar opaque over the band.

No step forces a frame. While the entry is accepted, AppKit's own layout under
the reservation answer keeps the window over the display.

Three main-queue turns and a 60 Hz poll are the only timing used; there are
no arbitrary animation delays. The polling is the justification for the
budget: it ends when WindowServer agrees, not after a fixed time.

## Displays

Arming requires a screen with `safeAreaInsets.top > 0`. A fullscreen Space
that moves to a display without a housing (Mission Control drag, arrangement
change, display removal) releases menu-bar alpha, presentation, reveal and
titlebar there and reports `.fallback` / `.noCameraHousing`; the entry stays
armed, and back beside the housing in the same Space it resumes (AppKit
lays the window out over the display again; display-mode round trip,
macOS 27.0.1). A window
that briefly has no screen during reconfiguration is neither. See
[WINDOW_LIFECYCLE.md](WINDOW_LIFECYCLE.md).

## Geometry

`FullPanelDisplayGeometry` uses only public `NSScreen` API:
`safeAreaInsets.top` (band height), `auxiliaryTopLeftArea` and
`auxiliaryTopRightArea` (the usable areas), from which the housing rectangle
is derived. `FullPanelLayout` converts them to top-left content coordinates
for a window whose content view fills its frame (true for an enabled window:
enabling applies `.fullSizeContentView` and a transparent titlebar).

## Public, implementation-dependent and private

| Layer | Examples | Stability |
| --- | --- | --- |
| Public Apple API | `NSWindow` fullscreen notifications, `toggleFullScreen:`, presentation options, `NSScreen.safeAreaInsets` / auxiliary areas, `CGWindowListCopyWindowInfo` | Documented; used as documented |
| Public API relied on for undocumented behavior | the order "willEnterFullScreen before AppKit lays out the fullscreen window"; Mission Control not changing `NSWindow.frame`; AppKit re-reading presentation options on Space activation | Observed on macOS 27.0.1; may change without notice |
| Private AppKit | `_NSFullScreenContentController` with `-reservesSpaceForMenuBarInFullScreen` (`B16@0:8`) and `-window` (`@16@0:8`): the one replaced method; `NSToolbarFullScreenWindow` (class name only: its window is observed and given click-through with public API) | Resolved at runtime with type-encoding checks; the class must implement the method itself, and its implementation must lie in AppKit's image before installation and still be FullPanelKit's afterwards |
| Private SkyLight (`dlopen`) | `SLSMainConnectionID`, `SLSCopySpacesForWindows`, `SLSSpaceGetType`, `SLSTransactionCreate`, `SLSTransactionSetMenuBarSystemOverrideAlpha`, `SLSTransactionCommit` | Resolved at runtime; missing symbols fall back |

### Private API risks

- **Detected:** a missing selector, class or symbol, a changed Objective-C
  type encoding, a reservation method inherited rather than implemented by
  the controller class, or another library's replacement of it (before
  FullPanelKit installs: not installed; after: later entries ordinary
  fullscreen). The session then uses ordinary fullscreen with
  `.appKitUnavailable` / `.skyLightUnavailable`; there is no other
  whole-display mechanism to fall back to. Without a titlebar window, reveal
  sensing falls back to `+[NSMenu menuBarVisible]`.
- **Not detectable in advance:** a behavioral change behind unchanged names
  and encodings — for example AppKit no longer laying the window out over the
  display for a NO (entry verification then rejects the entry: ordinary
  fullscreen), the menu bar ignoring the per-Space alpha, or the titlebar
  window no longer fading with the reveal.
  The likely symptom is a black or menu-bar-covered band in a session that
  still reports `.active`. Only hardware runs on each macOS release catch it
  ([TESTING.md](TESTING.md)).
- **Process-wide effects:** one. The reservation method of AppKit's
  fullscreen content controller class is replaced at the first enable in the
  process and never restored (restoring could undo another library's later
  replacement). It returns AppKit's own answer for every window whose engine
  does not claim the band, and for every call off the main thread. No window
  class (`NSWindow`, `NSPanel`, `FullPanelWindow`, an attached window's
  class) is modified.
- **Crash while active:** the Space's menu bar can stay transparent until that
  Space closes; there is no system-level cleanup FullPanelKit can register.
- **Distribution:** private API use is grounds for Mac App Store rejection
  (App Review Guideline 2.5.1).

No forward compatibility is claimed beyond the releases in
[COMPATIBILITY.md](COMPATIBILITY.md).

## Scoping guarantees

| Hook | Scope |
| --- | --- |
| `-[_NSFullScreenContentController reservesSpaceForMenuBarInFullScreen]` | process-wide method, installed once at the first enable; changes the answer only for the controller of a window whose engine claims the band; every other window, and every call off the main thread, gets AppKit's answer |
| titlebar-window observation | the engaged window's own child titlebar window; KVO and click-through undone at tracking stop |
| SkyLight alpha | the window's own fullscreen Space only |
| presentation options / KVO / event monitor | per engine, while it forces them |

## Diagnostics

`diagnostics()` / `fullPanelDiagnostics()` return a snapshot (keys are
informational and may change). With `FullPanelTrace=YES` in the app's
defaults the engine logs timestamped events: entry preparation, reservation
answers (changes only), entry verification, return checks, compositor state,
SkyLight commits, reveal changes, presentation restores and a `window-state`
line per lifecycle event.
