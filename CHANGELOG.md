# Changelog

All notable changes to FullPanelKit. Versions follow [Semantic Versioning](https://semver.org);
while the major version is 0, a minor release may change public API (see
[docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md), "Versioning").

## 0.1.0 — Developer Preview (2026-10-20)

First public release.

Native macOS fullscreen whose window covers the whole MacBook display,
including the areas beside the camera housing, while remaining a genuine
fullscreen Space (Mission Control, Spaces, menu-bar reveal, normal exit).
Relies on private AppKit and SkyLight interfaces; not for the Mac App Store.

### API

- `FullPanelWindow`: an `NSWindow` subclass; set `fullPanelEnabled`.
- `FullPanelSession`: the same behavior for an existing window that
  FullPanelKit did not create — a SwiftUI `WindowGroup` window or an
  application's own `NSWindow` subclass. The window keeps its identity, class,
  delegate and window controller. Plain `NSWindow`/`NSPanel` instances are
  refused (`FullPanelSessionError.unsupportedWindowClass`).
- State reporting: `FullPanelState` (`disabled`, `inactive`, `active`,
  `fallback`) and `FullPanelFallbackReason`, observable with KVO and a
  notification.
- Geometry: `FullPanelDisplayGeometry` (public `NSScreen` API only) and
  `FullPanelLayout` in top-left content coordinates.
- SwiftUI: `FullPanelStatus`, `\.fullPanel`, `FullPanelRootView`,
  `FullPanelWindow(contentRect:rootView:)`.
- Diagnostics: `diagnostics()` / `fullPanelDiagnostics()` snapshots and the
  `FullPanelTrace` user default. Keys are informational and may change.

### Behavior

- Whole-display geometry comes from AppKit's own layout: FullPanelKit
  answers the private fullscreen content controller's
  `-reservesSpaceForMenuBarInFullScreen` with NO for a window in a FullPanel
  entry (AppKit's answer is kept for every other window), and AppKit lays the
  window out over the display and keeps it there. FullPanelKit sets no frame
  and rejects none of AppKit's frame changes; an application that resizes
  its own fullscreen window is obeyed, as in native fullscreen.
- No window class is modified. One method of AppKit's fullscreen content
  controller class is replaced, process-wide, from the first enable on.
  `FullPanelWindow.delegate` is the application's own delegate object.
- The fullscreen menu bar's backdrop over the housing band is made
  transparent for the window's own Space (private SkyLight); the menu bar is
  revealed at the very top edge as in native fullscreen.
- Any native fullscreen entry gets FullPanel when the window is enabled
  before the entry begins: the green button, View ▸ Enter Full Screen,
  Control-Command-F, `toggleFullScreen(_:)`, and AppKit restoring a window
  into fullscreen at launch. Each entry is accepted only once the window is
  seen covering the display beside the housing.
- A window attached or enabled after its entry began is reported
  (`.fallback`, `diagnostics()["adoption"]`), not adopted in place;
  FullPanel applies from its next entry.
- Automatic fallback to ordinary fullscreen, with the reason reported, on
  displays without a camera housing, in Split View, when the private
  interfaces are missing, changed or replaced by other code, and when
  "Always show menu bar in full screen" is on.
- Mission Control and Space returns: compositor-verified menu-bar commit with
  one early commit and one presentation re-assert per return; bounded
  (≈2–4 s of polling), never forces a frame.
- A fullscreen Space moved to a display without a housing becomes ordinary
  fullscreen there and FullPanel again when it returns; detaching inside
  fullscreen makes the window ordinary (camera-safe) fullscreen at once.
- Presentation options are restored to AppKit's native fullscreen policy
  when FullPanel is disabled or detached inside fullscreen, and are not
  released while another FullPanel window that is key in fullscreen still
  forces them.
- Menu-bar alpha, presentation options, the fullscreen titlebar window's
  click-through, KVO and observers are restored or removed on exit, close,
  disable, detach, window deallocation and application termination.

### Package

- License: MIT (`LICENSE`), Copyright (c) 2026 Brian Merchant. No
  third-party source code; see `THIRD_PARTY_NOTICES.md`.
- No package dependencies. macOS 13 deployment target; hardware-verified on
  macOS 27.0.1 only (see Verification).
- The pure decision functions (`FPKDecisions.h`) are in the explicit
  submodule `FullPanelKitCore.Decisions`, for FullPanelKit's own tests. They
  are not public API.

### Integrations (experimental)

- `Integrations/Electron` (Electron 44.7.0, Node-API addon),
  `Integrations/Tauri` (Tauri 2.12.3) and `Integrations/Winit` (winit 0.30):
  bridges to `FullPanelSession` with test apps and automated suites. They
  compile the `FullPanelKitCore` sources; not published to npm or
  crates.io.

### Verification

Hardware: MacBook Pro 14-inch (2021, M1 Pro), built-in notched display,
macOS 27.0.1. See [docs/TESTING.md](docs/TESTING.md) for the exact runs,
[docs/INTEGRATION_EVIDENCE.md](docs/INTEGRATION_EVIDENCE.md) for each
integration's evidence and [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for
what is not verified: physical external displays, other Macs, other macOS
releases (for macOS 15.8.1 the reservation method was inspected statically
only), and, for the bridges, Mission Control with the current geometry.
Owner acceptance on the release checkout: M1 8/8, M2 3/3; restoration
scenarios A, B and R1–R5 passed 77/77. See [docs/TESTING.md](docs/TESTING.md).
Checks for other hardware remain documented in [docs/MANUAL_ACCEPTANCE.md](docs/MANUAL_ACCEPTANCE.md).
