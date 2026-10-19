# Prior art

Technical prior art for using the display area beside a MacBook's camera
housing (the "notch"), checked on 2026-10-17 from each project's own
documentation, pull requests or README. This is a technical comparison, not
legal, patent or trademark advice.

FullPanelKit did not invent rendering beside the camera housing, and it is not
the first implementation that keeps a native fullscreen Space while doing so
(see UTM below). What it adds is narrower: a reusable SDK that coordinates that
behavior for third-party windows.

## Five different things

| | What it is | Native fullscreen Space? | Who draws beside the housing |
| --- | --- | --- | --- |
| 1. Pixels beside the housing | Any app content in the band left and right of the housing: menu-bar utilities, notch HUDs, overlays | n/a | Usually a separate overlay window, above the menu bar |
| 2. Borderless "old-style" fullscreen | A borderless window with the screen's whole frame, menu bar and Dock hidden with presentation options | **No.** The window stays on the current desktop Space; Mission Control, Spaces swiping, the green button and Split View do not treat it as fullscreen | The app's own window |
| 3. Virtual-display capture | The app enters native fullscreen on a virtual display; its frames are captured and redrawn on the built-in panel | On the virtual display; the built-in panel shows a copy | A compositor process that mirrors the app |
| 4. Native fullscreen Space beside the housing | AppKit's own fullscreen Space, with the window laid out over the whole display (a fullscreen-frame override, or AppKit's menu-bar reservation answered NO) and the Space's menu bar made transparent | **Yes** | The app's own window, in its own Space |
| 5. A reusable SDK for 4 | 4 packaged for windows the library does not own, with lifecycle, fallback, restoration, Mission Control recovery and display changes handled once | Yes | The host app's own window |

FullPanelKit is 5. Every item below is 1–4, or an application-specific 4.

## Projects

### UTM — native fullscreen beside the camera housing (closest prior art)

- [UTM PR #7885](https://github.com/utmapp/UTM/pull/7885) (osy, merged
  2026-09-20, UTM 5.0 milestone): an opt-in setting that lets a fullscreen VM
  window use the strip beside the camera housing. Per the PR, the window keeps
  native fullscreen ("Mission Control, Spaces and Split View behave as
  before"); a window subclass answers fullscreen frame queries with the whole
  screen and ignores later resize requests; the menu bar is kept transparent
  until the pointer reaches the top edge; it relies on private AppKit and
  SkyLight API looked up at runtime, and stands down when tiled, on a display
  without a housing, or when the menu bar is always shown in fullscreen.
  Tested on macOS 27.0 (MacBook Air M3).
- [UTM PR #7910](https://github.com/utmapp/UTM/pull/7910) (osy, merged
  2026-10-14): extends it to macOS 12 and later by observing
  `_NSFullScreenMenuBarCompanionController setMenuBarReveal:` /
  `setToolbarWindowReveal:`, with type-encoding checks and fallback to normal
  fullscreen. The PR was merged while still marked as awaiting a human test on
  pre-27 hardware.
- Relation to FullPanelKit: this is the same category (4) and the same family
  of private interfaces. FullPanelKit's engine descends from Brian Merchant's
  OmacVM FullPanel work, which began as an Objective-C port of UTM's
  `VMDisplayWindow.swift`. In earlier, unpublished versions the frame hook,
  SkyLight wrapper, reveal observer and reveal/presentation logic were
  adapted from it; the current code replaced those parts with a redesign and
  later removed the frame hook altogether ([PROVENANCE.md](PROVENANCE.md)).
  UTM's implementation lives inside UTM's VM window; it is not a library for
  other applications.

### Try Omarchy — the menu-bar reservation answer

- [Try Omarchy pull request #361](https://github.com/omacom/try-omarchy/pull/361),
  "Full macOS notch support" (themartiano, MIT; read on 2026-10-18 at
  `f34e179b` while open, merged 2026-10-19) patches
  QEMU's Cocoa display so that, process-wide, AppKit's fullscreen content
  controller is told the window does not reserve space for the menu bar;
  AppKit then lays the fullscreen window out over the whole display itself.
  It raises the window's level instead of using SkyLight for the menu bar.
- Relation: FullPanelKit's current geometry uses the same AppKit answer,
  learned from that pull request's description and patch, scoped to
  FullPanel entries and verified per entry; it keeps the SkyLight backdrop
  override and native window levels. No code was copied.

### OmacVM

- [OmacVM issue #339](https://github.com/gillesgoetsch/OmacVM/issues/339)
  (Brian Merchant, 2026-10-10) proposed FullPanel upstream with a working
  branch. Gilles Goetsch's own implementation, derived from that branch,
  shipped in OmacVM 3.0.16 (off by default). [OmacVM PR #121](https://github.com/gillesgoetsch/omacvm/pull/121)
  (Gilles Goetsch, merged 2026-10-06) makes OmacVM's fullscreen macOS's own
  Space on every display and removes its earlier level-26 notch-cover
  window. In that PR the strip beside the housing stays black in native
  fullscreen unless OmacVM's own "Omanotch" fills it. OmacVM's production
  FullPanel (`omacvm-cocoa-fullpanel*.patch`) is a separate implementation
  from FullPanelKit; the two share an ancestor (Brian Merchant's branch), but
  neither consumes the other.

### Alin Panaitiu — "Fullscreen apps above the MacBook notch" (OverNotch)

- [Notes, 2023-04-12](https://notes.alinpanaitiu.com/Fullscreen%20apps%20above%20the%20MacBook%20notch):
  native fullscreen leaves the band black, so the author applies "old-style"
  fullscreen (category 2: borderless style mask, frame = screen frame,
  hidden menu bar and Dock via presentation options) to *other* apps' windows
  by injecting a Frida script (`OverNotch.js`). It needs SIP disabled, or
  re-signing target apps with `get-task-allow`; it does not work for every
  window, and some apps crash. The same author's Lunar can instead switch the
  built-in panel to a resolution without the notch area.
- Relation: demonstrates the demand and category 2 for arbitrary apps; it
  does not keep a native fullscreen Space and requires code injection.
  FullPanelKit needs no injection, but only works in apps that adopt it.

### WezTerm

- [`macos_fullscreen_extend_behind_notch`](https://wezterm.org/config/lua/config/macos_fullscreen_extend_behind_notch.html)
  (nightly builds only): extends the window behind the notch in fullscreen,
  and *must* be used with `native_macos_fullscreen_mode = false`; the green
  button and window-manager fullscreen commands then have no effect.
  Category 2.

### Glimmer

- [Se7enbrc/glimmer](https://github.com/Se7enbrc/glimmer) is a macOS game-
  streaming client (Sunshine / GeForce Experience). Its "cover the notch"
  presentation fills the whole display including the notch; turning it off
  uses a native fullscreen Space instead ([issue #84](https://github.com/Se7enbrc/glimmer/issues/84)),
  and a 2026-10-10 commit defaults to a borderless cover on every display.
  Its native-fullscreen option reserves the notch area
  ([PR #140](https://github.com/Se7enbrc/glimmer/pull/140)). Category 2, with
  native fullscreen as the camera-safe alternative.

### MacNotchKiller

- [DTW7607/MacNotchKiller](https://github.com/DTW7607/MacNotchKiller): creates
  a `CGVirtualDisplay` matching the built-in panel, moves the target window
  there and asks it to enter native fullscreen, then streams that display
  with `CGDisplayStream` and draws it on the built-in panel with Metal.
  Category 3. Needs Accessibility and possibly Screen Recording; its README
  says Space switching and Dock behavior depend on the WindowServer version.
  No license is declared.
- Relation: works with unmodified apps, at the cost of a mirrored copy and a
  compositor process. FullPanelKit draws the app's own window directly.

### Notch overlay frameworks

- No project named exactly "NotchKit" was found. The closest reusable
  framework is [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit)
  (SwiftUI views presented in a "Dynamic Island"-style window at the notch,
  with a floating fallback on displays without one); apps such as MewNotch,
  NotchFlow and Atoll build on the same idea. Category 1: overlay windows
  around the housing, not a fullscreen mode for an app's main window.

### WindowKit

- [naviapps/window-kit](https://github.com/naviapps/window-kit) (tag 2.0.0,
  2026-07): macOS window discovery, querying, hit-testing, placement and live
  control through AppKit, Core Graphics and Accessibility. Window-management
  infrastructure; it does not provide a fullscreen lifecycle or use the area
  beside the housing.

### Other references

- MacVim [PR #1450](https://github.com/macvim-dev/macvim/pull/1450) (2023):
  fixes the menu-bar height for MacVim's *non-native* fullscreen on notched
  displays. Category 2.
- [ByeNotch](https://github.com/ignaciojuarez/ByeNotch): hides the notch for
  "legacy apps & games"; its README does not describe the mechanism.
- Apple's own options: `NSPrefersDisplaySafeAreaCompatibilityMode` (scale a
  legacy app below the housing) and `NSScreen.safeAreaInsets` /
  `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (public geometry, which
  FullPanelKit uses). There is no public API that gives a native fullscreen
  window the band beside the housing; see [ATTACHMENT.md](ATTACHMENT.md),
  "Public API only".

## What this means for FullPanelKit's claims

Claims the prior art does **not** weaken:

- A reusable library: `FullPanelWindow` and `FullPanelSession` give the
  behavior to windows FullPanelKit does not create (SwiftUI `WindowGroup`,
  an app's own `NSWindow` subclass), with no code injection and no overlay or
  mirror window. None of the projects above is such a library.
- Lifecycle coordination tested as a library: entry from any native path
  (including AppKit restoring windows into fullscreen), attach/detach and
  disable at any point, presentation-option ownership across several
  fullscreen windows, Mission Control return recovery, release and resume when
  a fullscreen Space moves to a display without a housing, with the evidence
  in [TESTING.md](TESTING.md).
- Integration with several app architectures (AppKit, SwiftUI, and
  experimental Electron, Tauri and winit bridges).

Claims to **avoid**:

- "First" or "only" way to use the pixels beside the notch (categories 1–3
  are older; Alin Panaitiu's notes are from 2023).
- "First native fullscreen that renders beside the notch" (UTM 5.0 shipped
  it, PR #7885, merged 2026-09-20).
- "Invented" whole-display native fullscreen or the SkyLight menu-bar
  technique: the technique is UTM's (and earlier FullPanelKit revisions
  adapted UTM's code); the menu-bar reservation answer was learned from Try
  Omarchy pull request #361 (THIRD_PARTY_NOTICES.md, PROVENANCE.md).
- "Independent" or "clean-room" implementation of that technique.
- "Seamless" Mission Control, or support beyond the hardware and macOS
  versions in [COMPATIBILITY.md](COMPATIBILITY.md).

Suggested positioning: *"A Swift package that lets your app's own native
fullscreen windows use the whole MacBook display, including the areas beside
the camera housing, while staying real macOS fullscreen Spaces."*

## Not covered

- Name collisions and package registries: an earlier audit (2026-10-16) found
  no software released as FullPanelKit, FullPanelKitCore or FullPanelKitWebKit;
  `PanelKit` is taken by unrelated projects. Not repeated here.
- Patents and trademarks: not searched.
- Source comparison with UTM and OmacVM: done on 2026-10-17, recorded in
  [PROVENANCE.md](PROVENANCE.md). The adapted portions were later replaced
  (PROVENANCE.md, THIRD_PARTY_NOTICES.md).
