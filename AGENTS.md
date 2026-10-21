# FullPanelKit development guide

This is the canonical guide for developers and coding agents working on the
public, MIT-licensed FullPanelKit SDK. Use this checkout's current source and
documentation as authority. Do not substitute unpublished implementations.
FullPanelKit 0.1.0 and 0.1.1 are published Developer Preview releases; preserve them.

Read [README.md](README.md), [ARCHITECTURE.md](docs/ARCHITECTURE.md),
[ATTACHMENT.md](docs/ATTACHMENT.md), [COMPATIBILITY.md](docs/COMPATIBILITY.md),
[TESTING.md](docs/TESTING.md), [RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md)
and [Package.swift](Package.swift) before changing behavior. Historical test
records and stale comments about frame guards do not describe the current
mechanism. Resolve discrepancies against the implementation and report them.

## Architecture and native fullscreen

- Keep real AppKit fullscreen Spaces. The host application or user enters
  and exits fullscreen through AppKit, including restoration at launch.
  FullPanelKit never initiates either transition. Do not bypass native Spaces
  with borderless desktop windows, overlays, mirrors or simulated fullscreen.
- There is one `FPKEngine` per window, shared by two hosts:
  `FullPanelWindow` owns its engine; `FullPanelSession` attaches an engine to
  an existing supported window through an associated owner object. Engines
  hold windows weakly. SwiftUI only observes and presents engine state.
- The current layout mechanism is the menu-bar reservation hook in
  `FPKAppKitHooks.m`. It replaces
  `-[_NSFullScreenContentController reservesSpaceForMenuBarInFullScreen]`,
  calls AppKit first, and changes YES to NO only for a window whose engine
  claims the housing band. Every other window and off-main-thread call keeps
  AppKit's answer. AppKit itself lays out the fullscreen window.
- This is one process-wide replacement, installed at first enable and never
  removed. Preserve runtime class, selector, type-encoding, method ownership
  and implementation-image checks, including detection of replacement by
  another library before or after installation. Unavailable or conflicting
  interfaces must yield ordinary fullscreen with a reported fallback.
- Entry preparation occurs at `willEnterFullScreen`; the reservation request
  also prepares a host attached and enabled inside that notification. An
  entry must cover the display beside the housing to be accepted; a Split
  View tile is rejected with `.frameNotAccepted`.
- `FPKMenuBarOverlay` submits a SkyLight menu-bar alpha override only for the
  window's own fullscreen Space (type 4). The reconciler combines this with
  presentation options and fullscreen titlebar click-through. Reveal sensing
  uses titlebar-window observation, with `NSMenu.menuBarVisible` as fallback.
  Top-edge menu-bar reveal must remain available.
- Mission Control recovery uses observed return signals and bounded
  compositor checks to reapply menu-bar/presentation state. It never forces
  frames. `NSApp.presentationOptions` is application-wide: preserve ownership
  across multiple fullscreen windows and restore the appropriate fullscreen
  or windowed policy when an engine stops forcing it.

**Do not silently reintroduce the old fullscreen frame-override approach, frame
guards or frame forcing.** Treat a proposed geometry-mechanism change as an
explicit architectural change requiring review and new evidence. Do not
change or expand process-wide private AppKit hooks without targeted hook,
isolation and lifecycle tests plus native-Space hardware validation. Do not
modify window classes, change an instance's runtime class, wrap delegates,
or add window frame/fullscreen overrides as an attachment shortcut.

## Window lifecycle contract

- All window/session operations run on the main thread. Both hosts start
  disabled; enable before fullscreen entry. Already-fullscreen or late-enabled
  windows are not adopted in place: report fallback/adoption diagnostics and
  apply FullPanel on the next entry. For restored SwiftUI windows, attach
  synchronously from `viewDidMoveToWindow`, before an asynchronous hop.
- Sessions support the application's own `NSWindow` subclass and SwiftUI
  windows. Plain `NSWindow`, `NSPanel` and other AppKit-owned classes are
  refused with `.unsupportedWindowClass`. Non-KVO isa-swizzling is unsupported.
  Keep window identity, class, delegate, controller and scene intact.
- Attach is idempotent while attached. The window owns the session; the
  session holds the window weakly. Close restores system state but keeps the
  session for reuse. Window deallocation detaches it without messaging a
  deallocating window. Explicit detach is idempotent and makes that session
  inert; attaching again creates a new session.
- Exit, close, termination, disable and detach must restore menu-bar alpha,
  presentation state and titlebar click-through and stop relevant observers,
  monitors, KVO and pending work. Detach in fullscreen restores system state
  immediately and lets AppKit return to camera-safe fullscreen; saved window
  style is restored after exit when necessary.
- Enable applies `.fullSizeContentView`, a transparent titlebar and
  `.fullScreenPrimary`; disable restores saved values, deferring style changes
  during fullscreen. Adding full-size content preserves the content rect and
  can grow a framed window by its titlebar height. Preserve this documented
  behavior; create windows with that style initially to avoid the shift.
- An armed session moved to a display without a housing releases FullPanel
  system state and reports `.noCameraHousing`, remaining native fullscreen.
  It may resume beside a housing in the same entry. A temporarily nil screen
  during reconfiguration is a distinct condition.

## Public API and source layout

Applications import `FullPanelKit`. Public API is the exported declarations,
not diagnostics dictionary contents, trace text, diagnostic user defaults,
internal headers or the test-only `FullPanelKitCore.Decisions` submodule.
Keep that decision SPI out of the public import.

| Surface | Purpose |
| --- | --- |
| `FullPanelWindow` | App-created window; `fullPanelEnabled`, state/fallback/active properties, geometry, conversion, support check, restoration and diagnostics methods |
| `FullPanelSession` | `attach(to:)`, `session(for:)`, `isEnabled`, state/fallback/active, geometry/conversion, `isAttached`, weak `window`, `detach()`, support check, restoration and diagnostics |
| `FullPanelState`, `FullPanelFallbackReason` | Disabled, inactive, active or fallback state; reasons for ordinary fullscreen and human-readable summaries |
| `FullPanelDisplayGeometry`, `FullPanelLayout` | Public `NSScreen` geometry in global bottom-left coordinates; layout in top-left content coordinates, including left/right areas and camera exclusion |
| SwiftUI support | `FullPanelStatus`, `FullPanelRootView`, `EnvironmentValues.fullPanel` and `FullPanelWindow` hosting helpers |
| Notifications and KVO | Host state-change notifications and documented observable properties |

Keep required visible/clickable content out of the camera housing. The SDK
reports geometry; the host lays out content, including web content.

| Location | Responsibility |
| --- | --- |
| `Sources/FullPanelKitCore/` | Objective-C engine and hosts, private AppKit/SkyLight interactions, display geometry; pure C decisions in `FPKDecisions.c` |
| `Sources/FullPanelKitCore/include/` | Public headers, umbrella header and module map; explicit test-only Decisions submodule |
| `Sources/FullPanelKit/` | Swift core re-export, layout conversion and SwiftUI support |
| `Tests/FullPanelKitTests/` | Decisions, reservation hooks, entry/return handling, sessions, class isolation, geometry and lifetime tests |
| `Examples/FullPanelDemo/`, `Examples/FullPanelAttachDemo/` | Window-host and attachment demos and acceptance scenarios |
| `Tools/` | Clean consumer check, SpacesHarness and behavior/adoption probes |
| `Integrations/Electron/`, `Integrations/Tauri/`, `Integrations/Winit/` | Optional experimental bridges compiling the same core sources |
| `docs/`, `.github/workflows/ci.yml` | Contracts, evidence, acceptance/release guidance and manual CI |

The two SwiftPM targets separate Swift from Objective-C. The package has no
dependencies, requires Swift tools 5.9 or newer, and links AppKit and
CoreGraphics; SkyLight resolves at runtime. Compile Objective-C core sources
with ARC, including when building bridges directly.

## Compatibility and evidence

The macOS 13 deployment target is a compilation floor, not verified runtime
support. Current-mechanism hardware evidence is limited to macOS 27.0.1
(26A434), MacBook Pro 14-inch (2021, M1 Pro), built-in display. Do not claim
other macOS versions, Intel Macs, other notched models or physical external
display configurations work without recorded runs. macOS 15.8.1 has static
symbol inspection only for this mechanism. Sidecar and earlier-mechanism
results do not establish current physical-display compatibility.

Private AppKit/SkyLight use makes this unsuitable for the Mac App Store and
can break on OS updates. Missing/changed interfaces, no housing, Split View
and the always-show-fullscreen-menu-bar setting fall back to ordinary native
fullscreen. Matching symbol names/signatures and `.active` state do not prove
the band renders: SkyLight alpha is submitted, not observed. Validate pixels
on hardware. Mission Control returns can briefly show black or the backdrop;
a crash can leave the Space's menu bar transparent until that Space closes.

Electron, Tauri and winit are **experimental**, with bounded automated
evidence and gaps described in [INTEGRATION_EVIDENCE.md](docs/INTEGRATION_EVIDENCE.md).
Do not present them as production-verified; their bridge Mission Control
behavior is not verified. Preserve the distinction between current-code,
earlier-revision, automated, owner-reported manual and unperformed checks.

## Build and validation

Run from the repository root on macOS, selecting checks appropriate to the
change. Documentation-only edits need link/content and diff checks; do not
report SDK tests as run unless executed.

```sh
swift build
swift build --build-tests
swift build -Xswiftc -warnings-as-errors -Xcc -Werror
swift test
swift test --sanitize=address
Tools/ConsumerCheck/check.sh HEAD
Examples/FullPanelDemo/build-demo.sh
Examples/FullPanelAttachDemo/build-demo.sh
Tools/SpacesHarness/build.sh
```

The consumer check uses a committed ref from a clean local clone; it does
not validate uncommitted SDK edits. Do not commit merely to run it without
authorization. Four display-release tests skip without a display lacking a
housing; report skips separately from passes. CI is manual-only
(`workflow_dispatch`) and cannot establish hardware acceptance.

For fullscreen, hook, lifecycle or presentation changes, follow
[TESTING.md](docs/TESTING.md) and [MANUAL_ACCEPTANCE.md](docs/MANUAL_ACCEPTANCE.md):
run attachment autotests (SwiftUI and AppKit subclass), lifecycle checks
(including Zombies where relevant), restoration scenarios A/B/R1–R5, and
SpacesHarness native-fullscreen comparisons for affected return, activation
and display paths. Use the integration README commands when changing a bridge.
The restoration runner is `./run-scenarios.sh <outdir> 5` from
`Examples/FullPanelAttachDemo/`, run from Terminal.app.

Hardware scripts need a notched built-in display, Accessibility and Screen
Recording permissions, no competing test-app copies, and an idle Mac while
they drive input and Spaces. Inspect saved band captures as well as logs.
Record revision, OS, hardware, settings, commands, outcomes and gaps; compare
against ordinary native fullscreen. Unavailable hardware or permissions mean
unverified, never simulated success. Use `-FullPanelTrace YES` and diagnostic
snapshots when investigating; diagnostic defaults are not alternate supported
geometry modes.

## Licensing and release safeguards

- Preserve the MIT [LICENSE](LICENSE), copyright/permission notices and
  existing source headers. New code should carry the project's MIT header.
  Keep [NOTICE](NOTICE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
  [PROVENANCE.md](docs/PROVENANCE.md) accurate when adding material or dependencies.
  Do not copy third-party code and relabel it MIT. Optional bridge builds
  bring their own dependency obligations; the SDK's MIT license does not
  replace them. Keep acknowledgments distinct from included source and endorsement.
- Keep public files free of workstation paths, secrets, unpublished worktree
  references and internal documents. Use repository-relative documentation
  links and evidence suitable for public distribution.
- Check scope and `git status` before editing. Preserve unrelated work and
  review the final diff. Keep behavior, public documentation and evidence in
  agreement; report validation that could not be performed.
- `v0.1.0` and `v0.1.1` are already published. Do not move, replace or delete their tags, rewrite
  release history, or replay historical publication steps from the checklist.
  Future releases follow [RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md),
  with maintainer approval and recorded evidence before publication.
- Do not commit, push, tag, open pull requests or publish unless explicitly
  requested. Do not change CI triggers or release automation incidentally.
  Versioning policy: 0.x minor releases may change public API; patches fix
  bugs without API changes. Document private-interface behavior changes in
  the changelog even when declarations stay the same.
