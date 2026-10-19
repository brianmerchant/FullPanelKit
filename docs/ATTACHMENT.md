# Attaching FullPanel to an existing window

`FullPanelSession` gives an `NSWindow` that FullPanelKit did not create, such
as a SwiftUI `WindowGroup` window or an AppKit application's own `NSWindow`
subclass, the same FullPanel fullscreen as `FullPanelWindow`. The window keeps its identity, class, delegate, window
controller and scene. Attaching modifies no class: neither the window's
class nor any of its superclasses gains or changes a method.

```swift
import FullPanelKit

let session = try FullPanelSession.attach(to: window)
session.isEnabled = true
```

`FullPanelWindow` is unchanged and still the simplest choice when the
application creates the window itself.

## API

| | |
| --- | --- |
| `FullPanelSession.attach(to:) throws -> FullPanelSession` | Attach, or return the window's existing session. Starts disabled. |
| `FullPanelSession.session(for:)` | The window's attached session, or nil. |
| `FullPanelSession.systemSupportAvailable()` | AppKit's private fullscreen layout method (the fullscreen content controller's menu-bar reservation) and SkyLight resolve in this process, and no other code has replaced the reservation method. |
| `isEnabled` | Opt in. Same semantics as `FullPanelWindow.fullPanelEnabled` (style applied/restored, menu bar restored on disable). Ignored once detached. |
| `state`, `fallbackReason`, `isActive` | As on `FullPanelWindow` (`.disabled/.inactive/.active/.fallback`). |
| `geometry`, `layout`, `convertScreenRect(_:to:)` | Camera-housing geometry of the window's screen; `layout` is in top-left content coordinates. |
| `window` (weak), `isAttached` | |
| `detach()` | Disable, restore system state and window style, remove every observer. Idempotent. |
| `restoreSystemState()`, `diagnostics()` | As on `FullPanelWindow`. Diagnostics add `attached`, `windowClass`, `windowRuntimeClass`, `windowPointer`, `delegateClass`. |
| `FullPanelSession.stateDidChangeNotification` | Posted (object = session) on state, reason, enable, attach and screen changes. |
| KVO | `state`, `fallbackReason`, `isActive`, `isEnabled`, `isAttached`. |
| `FullPanelStatus(session:)` | `ObservableObject` publishing `layout` for SwiftUI. |

Errors (`FullPanelSessionError`, domain `FullPanelSessionErrorDomain`):

| Code | When |
| --- | --- |
| `.notMainThread` | Called off the main thread. |
| `.fullPanelWindow` | The window is a `FullPanelWindow`; use `fullPanelEnabled`. |
| `.unsupportedWindowClass` | The window's class is AppKit's own (`NSWindow`, `NSPanel`, …). Attaching to them is not supported (see [Plain `NSWindow`](#plain-nswindow-why-it-is-refused)). Create such windows as `FullPanelWindow` or your own subclass (see [AppKit applications](#appkit-applications)). |
| `.hookInstallationFailed` | Not returned: attaching installs nothing on the window's class. The code remains so that code handling it still compiles. |

## Lifecycle contract

- **Ownership.** The window owns its session, through an associated object.
  The session holds the window weakly. Applications may keep a reference, but
  they don't need to, and there is no retain cycle.
- **One session per window.** Attaching again returns the same session while it
  is attached. After `detach()` the session is inert. Attaching again creates a
  new session.
- **Enable before the fullscreen entry begins.** Every native entry is armed
  at `willEnterFullScreen`, exactly as for `FullPanelWindow`: the green button,
  `-toggleFullScreen:`, and AppKit restoring a window straight into
  fullscreen at launch. A host that attaches and enables inside the entry's
  own `willEnterFullScreen` is still in time: AppKit's reservation question
  for that entry prepares it. A window that is already in a fullscreen
  session is not adopted in place. The session reports `.fallback` with
  `diagnostics()["adoption"]`, stays in the same Space, and FullPanel applies
  from the next entry. See [RESTORED_FULLSCREEN.md](RESTORED_FULLSCREEN.md).
- **Fullscreen exit, close, application termination, disable, detach.** The menu-bar alpha, presentation
  options, fullscreen titlebar window, event monitor and KVO are all restored
  or removed (`fullPanelWillExitFullScreen`, unchanged from the tested engine).
- **Close.** System state is restored. The session stays attached, because an
  AppKit window can be shown again.
- **Window deallocation.** The session detaches (`isAttached` becomes NO, with
  KVO and a notification). It is released unless the application still
  holds it.
- **Detach during fullscreen.** System state is restored at once, and AppKit
  re-lays the window out as ordinary (camera-safe) fullscreen at once. Its
  style is restored after the exit, by a one-shot observer.
- **Threading.** Main thread only, like `NSWindow`.

## How it works

```
FullPanelWindow ──hosts──▶ FPKEngine ◀──hosts── FullPanelSession
 (the window's own engine)  (one per window)     (associated object of the window)
                               ▲
          menu-bar reservation hook (FPKAppKitHooks.m)
```

`FPKEngine.m` is the `FullPanelWindow` engine moved into its own object. A
`FullPanelWindow` and an attached window run the same engine code.

The engine needs no override on the window. In native fullscreen AppKit asks
each window's private fullscreen content controller whether to reserve the
menu-bar band; FullPanelKit's one replacement of that method finds the
window's engine (`FPKEngineForWindow`: the `FullPanelWindow`'s own, or the
attached session's through the window's associated object) and answers NO
while the engine claims the band. AppKit then lays the window out over the
whole display itself.

Scoping rules:

- Attaching adds an associated object and notification observers to the
  window, nothing else. The window's class, runtime class (including
  SwiftUI's `NSKVONotifying_` subclass) and method implementations are not
  changed (unit-tested: method tables of the class and every superclass up to
  `NSWindow` before and after attach, enable, entry preparation and detach).
- The reservation replacement is on AppKit's fullscreen content controller
  class, process-wide, installed once at the first enable and never removed.
  For every window whose engine does not claim the band, including every
  window without FullPanel, it returns AppKit's own answer.
- `NSWindow`, `NSPanel` and every other class from AppKit's image are refused.
- The window's delegate is **not** wrapped. A SwiftUI window's delegate is
  SwiftUI's `AppKitWindowController`, and replacing it would break the scene.
  `FullPanelWindow` does not wrap its delegate either.
- The menu-bar reveal is observed through AppKit's fullscreen titlebar window
  (KVO), without hooks.

Private API: identical to `FullPanelWindow` (see
[COMPATIBILITY.md](COMPATIBILITY.md)). Attachment adds no private symbol. If
the reservation method is missing, its type encoding changed or other code
replaced it, the window is still attached, but every entry is ordinary
fullscreen with `.appKitUnavailable`.

## SwiftUI WindowGroup example

```swift
struct WindowAttacher: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { let v = V(); v.onWindow = onWindow; return v }
    func updateNSView(_ v: NSView, context: Context) { onWindow(v.window) }
    final class V: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }
}

ContentView()
    .ignoresSafeArea()   // let content reach the band beside the housing
    .background(WindowAttacher { window in
        guard let window, let session = try? FullPanelSession.attach(to: window) else { return }
        session.isEnabled = true   // idempotent; safe on every SwiftUI update
    })
```

`Examples/FullPanelAttachDemo` is the complete version.

## AppKit applications

An AppKit application creates its windows as **its own `NSWindow`
subclass** and attaches a session. The subclass needs no overrides. It gives
FullPanelKit a class it may add overrides to, so `NSWindow` itself stays
untouched.

```swift
import AppKit
import FullPanelKit

final class MainWindow: NSWindow {}   // was: NSWindow

let window = MainWindow(contentRect: rect,
                        styleMask: [.titled, .closable, .miniaturizable, .resizable],
                        backing: .buffered, defer: false)
window.collectionBehavior.insert(.fullScreenPrimary)
window.contentView = rootView
window.delegate = windowDelegate                      // unchanged
let controller = NSWindowController(window: window)   // unchanged

do {
    let session = try FullPanelSession.attach(to: window)   // idempotent
    session.isEnabled = true          // before the user enters fullscreen
} catch {
    // .unsupportedWindowClass, ...: the window keeps
    // ordinary fullscreen.
}
controller.showWindow(nil)

// Later, if needed:
FullPanelSession.session(for: window)?.isEnabled = false   // ordinary fullscreen from the next entry
FullPanelSession.session(for: window)?.detach()            // remove FullPanel completely
```

- **When to subclass.** Subclass wherever the window is created, so the
  window is that class from the start. Only the class named at creation
  changes; the delegate, `NSWindowController`, content view and nib/storyboard
  setup stay as they are. For a storyboard or nib window, set the window's
  custom class to the subclass. If the application already has an `NSWindow`
  subclass, attach to that class instead. Applications such as Chromium and
  Gecko already create their windows from their own `NSWindow` subclasses.
  Your subclass's own overrides (frame setters, `toggleFullScreen(_:)`) run
  as usual: FullPanelKit adds nothing to the class. Each such integration
  still needs its own validation.
- **When to attach.** Attach at any time after the window is created, on the
  main thread, and enable before the window enters fullscreen. For windows
  that AppKit may restore into fullscreen, attach synchronously when the window
  first appears (SwiftUI: `viewDidMoveToWindow` of an `NSViewRepresentable`), not
  after an asynchronous hop. Enabling during fullscreen takes effect at the
  next entry.
- **Enable and disable.** `isEnabled` turns FullPanel on and off. Disabling
  restores the window style and menu bar. Fullscreen itself is never started
  or stopped by FullPanelKit.
- **Detach and clean up.** `detach()` restores everything and removes every
  observer. Without it, the session goes away with the window. There is
  nothing else to clean up, and the session does not retain the window.
- **Native fullscreen.** Fullscreen is still AppKit's own: the green button,
  View ▸ Enter Full Screen, Control-Command-F and `toggleFullScreen(_:)` all
  work, in a real fullscreen Space with Mission Control. With FullPanel the
  window gets the whole display, including the areas beside the camera
  housing. Displays without a housing, Split View and an unavailable private
  API fall back to ordinary fullscreen.
- **Alternative.** If the application can create the window as a
  `FullPanelWindow`, set `fullPanelEnabled = true` and no session is needed.
  `FullPanelWindow` keeps your delegate as is.

`FullPanelAttachDemo -FullPanelAttachAppKitSubclassOnly YES` runs this path on
hardware: an `NSWindow` subclass with an ordinary `NSWindowController` and
delegate, two fullscreen cycles with Mission Control returns, detach and
re-attach, and an untouched plain `NSWindow` alongside it.

## Plain `NSWindow`: why it is refused

`FullPanelSession` refuses windows created as plain `NSWindow` (or `NSPanel`).
Attaching no longer modifies any class, so the original technical reason (a
class hook on `NSWindow` would sit under every window in the process) is
gone. Attaching to AppKit's own classes has not been validated, though
(dynamic KVO subclasses, AppKit-owned delegates, AppKit's own windows of
those classes, restoration), so the refusal stays until it is.

Two earlier ways of giving such a window FullPanel were investigated on
macOS 27 and rejected:

- **Changing the instance's class** (a per-window subclass via
  `object_setClass`). AppKit registers key-value observers on every window
  during `-init` (for example for `_windowLayerContext`), and more when a
  content view such as `NSHostingView` or a style such as
  `.fullSizeContentView` is set. KVO keys each registration to the
  instance's class at the time. Changing the class and then deallocating the
  window makes `-[NSWindow dealloc]` throw "Cannot remove an observer".
  Restoring the original class after AppKit registered more observers throws
  the same way. No class satisfies both sets of registrations.
- **Public API only** (`window:willUseFullScreenContentSize:`, AppKit-only
  experiment, MacBook Pro 14-inch M1 Pro). The delegate returned the full
  display size, 1800 × 1169. AppKit asked repeatedly, including during
  Mission Control, but the window always stayed camera-safe at 1800 × 1130.
  The areas beside the housing stayed outside the content view: the
  content size alone does not change AppKit's camera-safe layout.

Create the window as your own subclass instead (one line, above).

## Integrations

The examples (`Examples/FullPanelAttachDemo`) and the Electron, Tauri and
winit bridges in `Integrations/` attach in the way described above. What has
been verified for each is in [INTEGRATION_EVIDENCE.md](INTEGRATION_EVIDENCE.md).

## Verification record (2026-10-11)

This record is for the first attachment implementation, which used a
fullscreen-frame override and frame guards installed on the window's class.
Both were later replaced by the menu-bar reservation hook; the observations
about guards and "hooked" classes below describe that version.

Hardware: MacBook Pro 14-inch (2021) M1 Pro, macOS 27, built-in display
1800 × 1169 pt @2×, housing band 38 pt, housing rect 220 × 38 pt, read at
runtime. An external display (1539 × 1070 pt, no housing) was also connected.

| Level | Result |
| --- | --- |
| Source review | Engine extraction is mechanical. All `FullPanelWindow` public API and overrides are kept. |
| Build | Library, `FullPanelDemo`, `FullPanelAttachDemo`: no warnings. |
| Unit tests | 60/60 (39 existing, unchanged; 21 new session tests). |
| Hardware, automated | `FullPanelAttachDemo -FullPanelAttachAutotest YES`: **51/51 checks** (final run, Mission Control step skipped; see below). |
| Hardware, screenshots | Attached SwiftUI window: content in both regions beside the housing, no menu bar. Ordinary SwiftUI window: AppKit's camera-safe fullscreen. `FullPanelWindow`: regions drawn beside the housing. |

Verified on hardware for an attached SwiftUI `WindowGroup` window:

- Two fullscreen entry/exit cycles: `.active`; AppKit frame, WindowServer
  bounds and content view all 1800 × 1169; menu-bar override submitted; both
  side areas in the layout. On exit: `.inactive`, windowed frame restored
  exactly, presentation options 0, override cleared.
- Window identity, delegate (`SwiftUI.AppKitWindowController`) and window
  controller unchanged throughout.
- Synthesized clicks (in-process `NSApp.sendEvent`) reached SwiftUI tap
  targets in both side areas.
- An ordinary window of the same, now hooked, class: no session, frame
  untouched while the attached window was in fullscreen. Its own fullscreen
  frame was AppKit's 1800 × 1130, not FullPanel's.
- `FullPanelWindow` in the same process still reached `.active` at
  1800 × 1169 and restored on exit.
- A second attached window reached `.active` independently. Closing it
  released its session and deallocated the window.
- Detach during fullscreen: session detached and disabled, override cleared,
  FullPanel's forced presentation released (AppKit's own `0x405` remains, as
  expected inside a fullscreen Space). After exit, the windowed frame and
  style were restored. Re-attach gave a new, working session.
- External display: fallback `.noCameraHousing`, ordinary fullscreen, and
  correct restore (first run, where SwiftUI opened the window there).
- Mission Control: in automated runs the attached window went through the
  tested return path. The trace showed away, return to the Space, didBecomeKey,
  early-commit, return-check-rearm, compositor settled, then `return-ready
  committed=1`. The frame guards rejected AppKit's camera-safe `{1800, 1130}`
  re-layout while the window was away. Mission Control cannot be *dismissed*
  reliably without Accessibility permission (launching it again re-opens it),
  and that confused later steps, so the final run skips it.

### Manual checklist (not automatable here)

Run `open Examples/FullPanelAttachDemo/build/FullPanelAttachDemo.app` on the
built-in display:

1. Control-Command-F or the green button. The left and right bars are visible
   beside the housing, and there is no menu bar.
2. Move the pointer to the very top edge. The menu bar reveals, and hides
   again once the pointer goes below the band.
3. Open Mission Control with F3 or a swipe. Return through the small Space
   thumbnail, then through the large window thumbnail. The side bars come
   back within about 2 s.
4. Click both side bars with the trackpad, and type in another app and come
   back.
5. Exit fullscreen. The window returns to its frame, and the menu bar is
   normal in other Spaces.

## Known limitations

- A window attached or enabled in a fullscreen session that is already under
  way (including an already-fullscreen window) uses ordinary fullscreen until
  its next entry. In-place adoption is not attempted; see
  [RESTORED_FULLSCREEN.md](RESTORED_FULLSCREEN.md).
- FullPanelKit does not answer `window:willUseFullScreenContentSize:`, for
  attached windows or `FullPanelWindow`.
- The reservation replacement on AppKit's fullscreen content controller class
  persists for the process (AppKit's answer for windows without a claiming
  engine). Another library that replaces the same method before FullPanelKit
  keeps it, and FullPanel is unavailable; one that replaces it afterwards
  makes later entries ordinary fullscreen, even if it calls FullPanelKit's
  implementation (the two cases cannot be told apart).
- Instances whose class is changed by isa-swizzling libraries other than KVO
  are unsupported.
- Plain `NSWindow`/`NSPanel` instances are refused (see
  [Plain `NSWindow`](#plain-nswindow-why-it-is-refused)). Create them as your
  own subclass.
- Several attached windows in fullscreen at the same time, each in its own
  Space, are verified (2026-10-17, `FullPanelAttachDemo` lifecycle L5 and
  restoration R2): each renders when shown, and closing one keeps the
  presentation options the key window still forces.
