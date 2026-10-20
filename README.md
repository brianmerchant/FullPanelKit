# FullPanelKit

**Developer Preview (0.1.0, unreleased).** A Swift package that lets your
app's own native fullscreen windows use the whole MacBook display —
including the areas left and right of the camera housing ("notch") — while
staying real macOS fullscreen Spaces.

![The top 38 points of a MacBook Pro display in native fullscreen: green content left of the camera housing, blue content right of it](docs/evidence/0.1.0-rc/demos/fullpaneldemo-appkit-band.png)

*A real screen capture of the strip beside the camera housing:
`Examples/FullPanelDemo` in native fullscreen on a MacBook Pro 14-inch
(macOS 27.0.1, captured with an earlier development build). The hatched middle section lies behind the camera housing.
More captures: [docs/INTEGRATION_EVIDENCE.md](docs/INTEGRATION_EVIDENCE.md).*

> [!WARNING]
> FullPanelKit relies on **private AppKit and SkyLight interfaces**. A macOS
> update can break it; when it can detect that, it falls back to ordinary
> fullscreen and tells you why. It is **not suitable for the Mac App Store**.
> Verified on one Mac (MacBook Pro 14-inch, M1 Pro) running macOS 27.0.1 —
> see [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## What it does

- Your window enters AppKit's own fullscreen Space (green button, View ▸
  Enter Full Screen, Control-Command-F, `toggleFullScreen(_:)`, or AppKit
  restoring it at launch). FullPanelKit makes that Space's window cover the
  whole display and hides the fullscreen menu bar over the housing band, so
  your content is drawn and clickable beside the housing.
- Mission Control, Spaces, Split View, the menu bar (revealed at the very top
  edge), the Dock and fullscreen exit keep working as for any fullscreen app.
- Works with windows you create (`FullPanelWindow`) and windows you don't
  (`FullPanelSession`, e.g. SwiftUI `WindowGroup` windows).
- Falls back to ordinary fullscreen, with a reported reason, on displays
  without a housing, in Split View, when "Always show menu bar in full
  screen" is on, or when the private interfaces are missing or changed.
- Reports the housing geometry so you can keep content away from the camera.

## What it does not do

- It never enters or leaves fullscreen for you, and never adds overlay or
  mirror windows.
- It does not lay out your content: you decide what goes beside the housing
  (`FullPanelLayout` tells you where that is).
- It cannot change other applications, plain `NSWindow`/`NSPanel` instances,
  or non-native ("borderless") fullscreen.
- It does not adopt a window that is *already* fullscreen; FullPanel applies
  from that window's next entry.
- It does not make Mission Control transitions seamless.
- It does not make web content notch-aware. A browser or web view gets a
  window that covers the strip; laying out or scrolling page content around
  the housing is up to the host application.

### Native fullscreen vs. a borderless window

Many apps reach the pixels beside the notch with an "old-style" borderless
window sized to the screen. That window stays on the desktop Space: there is
no fullscreen Space in Mission Control, no swipe between Spaces, and the green
button does not apply. FullPanelKit keeps the native fullscreen Space and
changes only its frame and menu bar. Other approaches and prior work (UTM,
WezTerm, MacNotchKiller, …): [docs/PRIOR_ART.md](docs/PRIOR_ART.md).

## Requirements

- macOS 13 or later to build (`platforms: [.macOS(.v13)]`); **verified only
  on macOS 27.0.1**, MacBook Pro 14-inch (M1 Pro). For macOS 15.8.1 the
  private AppKit method FullPanelKit relies on was only inspected statically
  (present by name); nothing was run there with the current code. No runtime
  claim is made for macOS 13, 14, 15 or 26.
- A MacBook with a camera housing for FullPanel; elsewhere you get ordinary
  fullscreen.
- Swift 5.9 or newer. No dependencies.
- Your window must be a `FullPanelWindow`, or an instance of a class that is
  not one of AppKit's own (your `NSWindow` subclass, SwiftUI's windows).

## Installation

Swift Package Manager. Until the first tag exists, use a local path:

```swift
// Package.swift
dependencies: [
    .package(path: "../FullPanelKit"),
    // after release: .package(url: "<repository URL>", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "FullPanelKit", package: "FullPanelKit"),
    ]),
]
```

In Xcode: File ▸ Add Package Dependencies… ▸ Add Local…, then add the
`FullPanelKit` library to your app target.

## AppKit quick start

```swift
import FullPanelKit

let window = FullPanelWindow(
    contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false)
window.contentView = MyView()
window.fullPanelEnabled = true   // also sets .fullSizeContentView, a transparent titlebar, .fullScreenPrimary
window.makeKeyAndOrderFront(nil)
// The user (or your code) enters fullscreen as usual: window.toggleFullScreen(nil)
```

Already have your own `NSWindow` subclass, window controller and delegate?
Keep them and attach a session instead:

```swift
final class MainWindow: NSWindow {}          // your class (not plain NSWindow)

let session = try FullPanelSession.attach(to: window)   // idempotent
session.isEnabled = true                                // before fullscreen is entered
```

Lay out content with the geometry, in top-left content coordinates:

```swift
let layout = window.fullPanelLayout            // or session.layout
if layout.isActive, let left = layout.leftArea, let right = layout.rightArea {
    // put content in `left` and `right`; keep `layout.cameraHousing` clear
}
```

Observe changes with `FullPanelWindow.stateDidChangeNotification` /
`FullPanelSession.stateDidChangeNotification`, or KVO on `fullPanelState` /
`state`:

```swift
switch session.state {
case .disabled, .inactive: break
case .active:   break                                   // content beside the housing
case .fallback: print(session.fallbackReason.summary)   // ordinary fullscreen, and why
@unknown default: break
}
```

## SwiftUI quick start

SwiftUI `WindowGroup` windows are attached where they are created:

```swift
import Combine
import FullPanelKit
import SwiftUI

struct WindowAttacher: NSViewRepresentable {        // hands you the hosting NSWindow
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { let v = V(); v.onWindow = onWindow; return v }
    func updateNSView(_ v: NSView, context: Context) { onWindow(v.window) }
    final class V: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }
}

@MainActor final class PanelModel: ObservableObject {
    @Published private(set) var layout = FullPanelLayout()
    private var status: FullPanelStatus?
    private var sink: AnyCancellable?

    func attach(_ window: NSWindow?) {                  // synchronous: see below
        guard let window, status == nil,
              let session = try? FullPanelSession.attach(to: window) else { return }
        session.isEnabled = true
        let status = FullPanelStatus(session: session)
        self.status = status
        sink = status.$layout.receive(on: DispatchQueue.main).sink { [weak self] in self?.layout = $0 }
    }
}

struct ContentView: View {
    @StateObject private var panel = PanelModel()
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let left = panel.layout.leftArea {
                Text("Left of the camera").frame(width: left.width, height: left.height)
                    .offset(x: left.minX, y: left.minY)
            }
        }
        .ignoresSafeArea()                               // let content reach the band
        .background(WindowAttacher(onWindow: panel.attach))
    }
}
```

Attach synchronously from `viewDidMoveToWindow` (as above) so that a window
AppKit restores straight into fullscreen is attached before its entry.
`Examples/FullPanelAttachDemo` is a complete app.

If you create the window yourself, host SwiftUI in a `FullPanelWindow` and
read `@Environment(\.fullPanel)`:

```swift
let window = FullPanelWindow(contentRect: rect) { ContentView() }   // reads \.fullPanel
window.fullPanelEnabled = true
```

## Window requirements and lifecycle

- **Main thread only**, like `NSWindow`.
- **Enable before the entry.** A window enabled or attached after its
  fullscreen entry began stays in ordinary fullscreen for that entry and
  reports `.fallback` with `diagnostics()["adoption"]`.
- **Plain `NSWindow`/`NSPanel` are refused** (`FullPanelSessionError.unsupportedWindowClass`):
  attaching to AppKit's own window classes is not supported. Use
  `FullPanelWindow` or a one-line subclass.
- **No class changes.** Attaching adds no method to the window's class.
  FullPanelKit replaces one method of AppKit's private fullscreen content
  controller, process-wide, from the first enable on; it keeps AppKit's
  answer for every window that is not in a FullPanel entry.
- **Full-size content.** Enabling adds `.fullSizeContentView`; macOS keeps the
  content rect, so a framed window grows by its titlebar. Create windows with
  `.fullSizeContentView` and a transparent titlebar to avoid the shift.
- **Ownership.** The window owns its session; you don't need to keep a
  reference. `detach()` restores everything; otherwise the session ends with
  the window. Closing restores system state but keeps the session (a window
  can be shown again).
- `FullPanelWindow.delegate` is your own delegate object.

Full contract: [docs/ATTACHMENT.md](docs/ATTACHMENT.md).

## Mission Control

Each FullPanel window is an ordinary fullscreen Space in Mission Control.
After a return (Escape, the large preview, a Space thumbnail, a Space switch)
the band beside the housing comes back as WindowServer settles. On this
release's code, 100 of 100 Space-thumbnail returns in Mission Control came
back to the window, active and key, with the band filled (macOS 27.0.1,
`FullPanelWindow`; about 0.5 s from the click inside the Space, 0.65 s from
another app's Space). That bounds the failure rate on this Mac below about
3 % at 95 % confidence; it does not prove it is zero
([docs/TESTING.md](docs/TESTING.md)).
It is not seamless: during the transition the band can briefly show black or
Mission Control's backdrop. Dock clicks and Command-Tab behave exactly as for native
fullscreen, including the Desktop & Dock setting "When switching to an
application, switch to a Space with open windows for the application".

## Known limitations

- Private API: may break with a macOS update; not for the Mac App Store.
- Verified on one Mac and one macOS release; physical external displays,
  display sleep/wake and other Macs are not verified
  ([docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)).
- Already-fullscreen windows are not adopted in place.
- If WindowServer takes the strip away from a fullscreen session, it stays
  away until the next entry; FullPanelKit never forces a frame.
- A crash while in FullPanel fullscreen can leave that Space's menu bar
  transparent until the Space closes.

## Tested integrations

Verified on a MacBook Pro 14-inch (M1 Pro), macOS 27.0.1. "This release"
means this repository's code; "earlier build" means a development build
with the previous geometry mechanism. Evidence for every entry (source,
revision, check lists, real screen captures, gaps):
[docs/INTEGRATION_EVIDENCE.md](docs/INTEGRATION_EVIDENCE.md).

| Integration | Example | Status |
| --- | --- | --- |
| AppKit, `FullPanelWindow` | `Examples/FullPanelDemo`, `Tools/SpacesHarness` | **Hardware verified.** This release: 100 Mission Control returns; Dock, Command-Tab and Space switches. Earlier build: strip rendering, clicks and menu-bar reveal in the demo, display-mode changes |
| SwiftUI `WindowGroup`, `FullPanelSession` | `Examples/FullPanelAttachDemo` | **Hardware verified.** This release: autotest 82/82, lifecycle 28/28 (also under Zombies). Earlier build: 77 scenario checks including windows restored into fullscreen and Mission Control returns |
| Your own `NSWindow` subclass, `FullPanelSession` | `Examples/FullPanelAttachDemo` (AppKit mode), `Tools/SpacesHarness` | **Hardware verified.** This release: autotest 49/49; Mission Control, Dock and Command-Tab via `Tools/SpacesHarness` |
| Electron 44.7.0 | `Integrations/Electron` | **Experimental.** This release: 63/63 automated checks. Earlier build: real strip capture. Mission Control not verified with the bridge |
| Tauri 2.12.3 | `Integrations/Tauri` | **Experimental.** This release: 101/101 automated checks. Earlier build: real strip capture. Mission Control not verified with the bridge |
| winit 0.30 | `Integrations/Winit` | **Experimental.** This release: 140/140 automated checks. Earlier build: real strip capture. Mission Control not verified with the bridge |

The Electron, Tauri and winit bridges are part of this repository, compile
the same `FullPanelKitCore` sources, and are not affiliated with or endorsed
by those projects.

## Examples and tools

- [`Examples/FullPanelDemo`](Examples/FullPanelDemo) — `FullPanelWindow`,
  AppKit and SwiftUI variants; the place to start.
- [`Examples/FullPanelAttachDemo`](Examples/FullPanelAttachDemo) — SwiftUI
  `WindowGroup` + `FullPanelSession`, with the hardware scenarios.
- `Tools/SpacesHarness` — native-fullscreen-vs-FullPanel comparisons (Mission
  Control, activation, display modes, display migration).
- `Tools/ConsumerCheck` — builds a consumer against a clean clone.
- `Integrations/Electron`, `Integrations/Tauri`, `Integrations/Winit` —
  bridges with test apps; each README covers build, API and tests.

## Diagnostics

`diagnostics()` / `fullPanelDiagnostics()` return a snapshot (keys may
change). Launch with `-FullPanelTrace YES` for a timestamped engine log.
Other defaults (`FullPanelEarlyApply`, `FullPanelRevealIntegration`,
`FullPanelLegacyModes`) exist only for diagnosis; the defaults are the tested
configuration.

## Documentation

| | |
| --- | --- |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | engine, lifecycle, Mission Control, private API risks |
| [ATTACHMENT.md](docs/ATTACHMENT.md) | `FullPanelSession` contract |
| [COMPATIBILITY.md](docs/COMPATIBILITY.md) | what is verified, and what is not |
| [TESTING.md](docs/TESTING.md) | test suites, hardware harnesses, results |
| [INTEGRATION_EVIDENCE.md](docs/INTEGRATION_EVIDENCE.md) | per-integration evidence and status |
| [MANUAL_ACCEPTANCE.md](docs/MANUAL_ACCEPTANCE.md) | checks that need a person at the Mac |
| [RESTORED_FULLSCREEN.md](docs/RESTORED_FULLSCREEN.md), [WINDOW_LIFECYCLE.md](docs/WINDOW_LIFECYCLE.md) | investigations |
| [PRIOR_ART.md](docs/PRIOR_ART.md) | related projects and claims to avoid |
| [RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) | what must pass before publication |
| [CHANGELOG.md](CHANGELOG.md) | changes |

## Development

FullPanelKit is an open-source project created and directed by Brian
Merchant, with development assistance from Anthropic Claude Code and OpenAI
Codex.

AI-assisted workflows have been used for implementation, architectural
research, debugging, testing, and documentation. Project decisions,
integration, and release approval remain under human direction. Details,
including what AI assistance does and does not establish:
[docs/PROVENANCE.md](docs/PROVENANCE.md#development-methodology).

## History and acknowledgments


FullPanelKit **0.1.0 is the SDK's first public release**. Its implementation and integration APIs are maintained separately from the projects acknowledged here. This release contains no UTM, Try Omarchy, or OmacVM source code according to the release-source audit.

[UTM](https://github.com/utmapp/UTM) is important prior work on native fullscreen around the MacBook camera housing. [Try Omarchy PR #361](https://github.com/omacom/try-omarchy/pull/361), by [themartiano](https://github.com/themartiano), inspired the AppKit fullscreen menu-bar reservation approach. [OmacVM](https://github.com/gillesgoetsch/OmacVM), maintained by Gilles Goetsch, was the original application context for FullPanel development. [yabai](https://github.com/asmvik/yabai) and CGSInternal were references for platform interfaces.

See [Provenance and acknowledgments](docs/PROVENANCE.md) and [Third-party notices](THIRD_PARTY_NOTICES.md) for the release's scope and license obligations.

## License

**MIT** ([LICENSE](LICENSE)). Copyright (c) 2026 Brian Merchant. This
repository contains no third-party source code; the optional integrations'
build-time dependencies and their license terms are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
