# FullPanelKit for winit (experimental)

Native macOS fullscreen for a winit window that covers the whole display,
including the areas beside the MacBook camera housing. It is the same
FullPanelKit engine and the same `FullPanelSession` API that AppKit, Electron
and Tauri applications use, reached through a small C-ABI bridge.

- winit **0.30.13** (objc2 0.5), softbuffer **0.4.8** for the test app's pixels.
  No GPU, WebKit or browser renderer.
- No winit changes and no FullPanelKit engine changes: `build.rs` compiles
  `Sources/FullPanelKitCore` as it is.
- macOS only (`#![cfg(target_os = "macos")]`).


## Status

**Experimental.** On this release's code (MacBook Pro 14-inch, macOS 27.0.1,
2026-10-19) the bridge builds without warnings and `--autotest` passes 140/140.
Older records below are from an earlier development build.

On the earlier, unpublished FullPanelKit 0.1.0 candidate, which used the
previous fullscreen-frame geometry mechanism (MacBook Pro
14-inch, macOS 27.0.1):
- `cargo build --locked` succeeds without warnings;
- `--autotest` passes 140/140;
- a real screen capture shows window A drawing beside the camera housing in
  native fullscreen (window B stays black).

Mission Control returns, physical clicks and menu-bar reveal were reported as
verified on an earlier SDK revision (2026-10-12), without a retained report;
they have not been re-run on the release candidate.

Details, evidence and gaps: [docs/INTEGRATION_EVIDENCE.md](../../docs/INTEGRATION_EVIDENCE.md).
Manual checks: [docs/MANUAL_ACCEPTANCE.md](../../docs/MANUAL_ACCEPTANCE.md), M4.

## Use in your app

- Requirements: macOS 13 or later, Xcode Command Line Tools, Rust (tested
  with 1.99.0), winit **0.30** (tested 0.30.13) and raw-window-handle 0.6.
- The crate is not published to crates.io (`publish = false`). Depend on the
  release tag with a git dependency; Cargo checks out the whole repository,
  and `build.rs` compiles `FullPanelKitCore` from it:

  ```toml
  [dependencies]
  fullpanelkit-winit = { git = "<FullPanelKit repository URL>", tag = "<release tag>" }
  ```

  This route has not been exercised from a separate project yet; the test
  app uses a path dependency.

## Layout

| Path | Purpose |
|---|---|
| `fullpanelkit-winit/build.rs` | Compiles the unchanged FullPanelKitCore sources and the bridge with `cc` (ARC, macOS 13). |
| `fullpanelkit-winit/src/fullpanel_winit.m` | C-ABI bridge: resolves the handle's `NSView` to its `NSWindow` and forwards to `FullPanelSession`. Returns JSON. |
| `fullpanelkit-winit/src/lib.rs` | Rust API. Depends on `raw-window-handle` 0.6, not on winit. |
| `test-app/` | Development app: window A (FullPanel), window B (control). `src/autotest.rs` holds the automated suite. |

## API

```rust
use fullpanelkit_winit as fullpanel;
use winit::platform::macos::WindowAttributesExtMacOS;
use winit::window::Fullscreen;

// In an ApplicationHandler method (main thread):
let window = event_loop.create_window(
    Window::default_attributes()
        .with_fullsize_content_view(true)   // see "Frame and titlebar"
        .with_titlebar_transparent(true)
        .with_title_hidden(true),
)?;
fullpanel::attach(&window)?;            // Ok(json) or Err(Error { code, message, details })
fullpanel::set_enabled(&window, true)?; // before entering fullscreen
window.set_fullscreen(Some(Fullscreen::Borderless(None)));  // winit's native fullscreen (toggleFullScreen:)

fullpanel::notch_regions(&window)?;  // Option<NotchRegions { left, right, housing, scale_factor, active }>
fullpanel::state(&window)?;          // { state: { stateName: "Active" | ... }, geometry: { leftInWindow, rightInWindow, ... } }
fullpanel::diagnostics(&window)?;    // + native window facts, layer frames, FullPanelSession diagnostics
fullpanel::detach(&window)?;         // also done automatically when the Window is dropped
fullpanel::bridge_info()?;
```

- Every function takes any `raw_window_handle::HasWindowHandle` with an AppKit
  handle. `winit::window::Window` 0.30 qualifies, and so does an `Arc<Window>`.
- **Main thread only.** Call from `ApplicationHandler` methods, which winit runs
  on the macOS main thread. Elsewhere every call returns `ERR_FULLPANEL_THREAD`
  without touching AppKit. winit 0.30 has no public way to run a closure on
  the main thread, so the crate does not marshal calls.
- `NotchRegions` rectangles are in the window's top-left coordinates, in points
  (winit logical pixels). `Rect::to_physical(window.scale_factor())` gives
  surface pixels. They lie inside the window only while `active` is true.

## How the bridge works

- **Handle.** winit's `AppKitWindowHandle` carries only `ns_view`, which is the
  window's content view (`WinitView`). The bridge never messages the pointer
  until it has found it among the view trees of `NSApp.windows`. It checks the
  content view first and then descendants, as the Electron bridge does. A
  dropped window's view is rejected (`ERR_FULLPANEL_NO_WINDOW`).
- **WinitWindow.** winit declares `WinitWindow : NSWindow` with objc2's
  `declare_class!`, which registers it at run time (`objc_allocateClassPair`).
  It overrides only `canBecomeMainWindow` and `canBecomeKeyWindow`.
  - `class_getImageName` returns NULL for it, so `FullPanelSession`'s check
    for AppKit-owned classes passes, and correctly so: it is not an AppKit class.
  - The session adds its pass-through overrides to `WinitWindow` with
    `class_addMethod`.
  - The instance's runtime class is `NSKVONotifying_WinitWindow` before
    attachment. The hooks go on `WinitWindow` (`-class`), and the KVO subclass
    inherits them. Nothing replaces the isa.
  - Window B is also a `WinitWindow` and gets the same pass-through overrides. It
    is verified unaffected.
- **Fullscreen entry.** `set_fullscreen(Some(Fullscreen::Borderless(_)))` sends
  `-toggleFullScreen:` to the window synchronously, so FullPanelKit arms. The
  green button takes the same path.
  - winit first sets `Titled | Resizable` only if the style lacks them, which a
    FullPanel window never does.
  - `Fullscreen::Exclusive` (display capture and mode switch) is not a
    FullPanel path and is not supported.
- **Delegate.** `WinitWindowDelegate` stays in place.
  - For borderless fullscreen its `window:willUseFullScreenPresentationOptions:`
    returns AppKit's proposal unchanged.
  - On `windowDidExitFullScreen:` winit synchronously reapplies the style it
    reads at that moment, then its saved maximized state. The suite checks the
    style and frame after exit, including after a disable or detach inside
    fullscreen.
- **Content and rendering.** Once FullPanel is active, `WinitView` fills the
  window (1800×1169 pt). winit reports `Resized` with the full pixel size, and
  softbuffer's sublayer follows the root layer's bounds through its own KVO
  observer. The app only has to resize its surface on `Resized`, as usual.
  Mouse events beside the housing reach `WinitView` and arrive as ordinary
  `CursorMoved` and `MouseInput`.
- **Lifecycle.**
  - Sessions stay owned by their windows. The bridge keeps weak references,
    plus one `NSWindowWillClose` observer per attached window that detaches
    the session.
  - Dropping a winit `Window` closes its NSWindow, and winit never reopens it.
  - FullPanelKitCore is linked statically into the executable, so there is one
    copy of its classes (`bridge_info().fullPanelSessionImage`).

## Frame and titlebar

> **Known compatibility limitation (unresolved).** FullPanel windows with
> winit's default titlebar are not supported without a frame shift. Enable
> and disable move the frame by the titlebar height (32 pt on macOS 27). This
> integration does not correct it and FullPanelKitCore is unchanged. Use the
> full-size content view configuration below. A general solution for ordinary
> titlebar windows, with regression coverage across all integrations, is
> separate future work.

AppKit keeps the **content rect** when a style change adds or removes
`.fullSizeContentView`. Verified on macOS 27 with a plain `NSWindow` subclass,
so this is not winit behaviour. Enabling FullPanel adds that flag, and disabling
or detaching restores the original style.

- **Window with winit's default decorations.** Enable shortens the frame by the
  titlebar height (32 pt on macOS 27), with the bottom edge fixed. Disable
  lengthens it again. A resize in between shifts the restored frame by the same
  32 pt. The suite characterizes this (T12) and does not correct it. The
  Electron bridge has a frame-correction step for its variant of this. No such
  step was added here.
- **Recommended.** Create FullPanel windows with
  `with_fullsize_content_view(true)` and a transparent titlebar, as above. This
  is the winit equivalent of Tauri's `TitleBarStyle::Overlay`. Enabling then
  changes nothing about the frame, and the window comes back exactly (T1–T11).
  The content draws under the traffic lights while windowed.

## Build and run

```sh
cd Integrations/Winit
cargo run -p fullpanel-winit-test                 # interactive hardware test
cargo run -p fullpanel-winit-test -- --autotest   # automated suite, ~50 s
```

Leave the Mac idle while `--autotest` runs. It enters fullscreen repeatedly on
the built-in display, and real pointer movement can interleave with its
synthetic clicks. Reports go to `test-app/reports/*.json`, which is git-ignored.

Interactive keys (focused window): **F** fullscreen, **E** enable/disable,
**A** attach, **D** detach, **S** state, **I** diagnostics, **N** new attached
window, **W** close window, **Q** quit. Window titles show the session state.
The terminal logs every button press and release as
`[pointer a] down Left at (x, y) region=notch-left state=Active`.

## Automated coverage (`test-app/src/autotest.rs`)

The suite runs on its own thread. It sends every AppKit-touching step to the
main thread through the `EventLoopProxy` and uses only the public crate API,
plus winit's `set_fullscreen`.

- **ENV.** Built-in display with a camera housing, system support available.
  Calls from a non-main thread are refused.
- **T1.** `WinitWindow : NSWindow`, registered at run time, eligible.
  `WinitWindowDelegate`. The handle view is the `WinitView` content view,
  layer-backed. Window A uses the overlay titlebar.
- **T2.** Attach leaves the window's class, runtime class, delegate, content
  view, frame and style untouched. A second attach returns the same session.
  One live session. Window B unaffected.
- **T3, T9, T8.reattach, T11.c, T12.framed.** Native fullscreen through
  `set_fullscreen`:
  - The session is Active, the frame equals the screen (1800×1169) and
    WindowServer bounds cover the display.
  - `WinitView`, its layer and softbuffer's sublayer cover the window.
    `inner_size()` and the softbuffer buffer are 3600×2338.
  - The app's buffer holds the region colours at the centre of each
    notch-side area.
  - A synthetic click at each centre hit-tests to `WinitView` and arrives
    through winit as `MouseInput` at the expected logical position, in
    `notch-left` and `notch-right`.
  - Exit restores the frame, style, class, WindowServer bounds, presentation
    options and surface size.
- **T6.** Window B: ordinary fullscreen leaves the camera-housing band out
  (1800×1130), and clicks at the top of its content still arrive. B is
  restored afterwards and A is untouched.
- **T8.** Windowed enable → disable → enable. Disable inside fullscreen
  (ordinary fullscreen options at once, style at exit). Detach inside
  fullscreen. Reattach (new session) with a full cycle. Windowed detach and
  reattach.
- **T9.** Repeated cycles, with a move and resize in between.
- **T10.** Three create/attach/drop cycles: detached on close, session and
  window released, stale view handle rejected. Dropping a window while it is
  in FullPanel fullscreen restores presentation options.
- **T11.** A second attached window has its own session. C Active while A stays
  windowed and Inactive. Disabling A does not affect C.
- **T12.** Standard framed window: records the known limitation above (the
  32 pt frame shift is asserted, not fixed). It still reaches Active with
  rendering and clicks beside the housing.

Not automated: physical clicks (the suite posts AppKit events to the
application queue, which bypasses WindowServer and the menu-bar reveal),
visible pixels on the panel, and Mission Control and Spaces.

## Hardware test (manual)

Use the built-in display. In System Settings, "Automatically hide and show the
menu bar in full screen" must not be set to *Never*.

1. `cargo run -p fullpanel-winit-test`. Window A starts attached and enabled
   (title `· Inactive`).
2. In window A, press **F** or the green button. Expect orange (left) and teal
   (right) to fill the band beside the camera housing, with no black bars.
   The housing area itself is black.
3. Click in both coloured regions. The region flashes white, a marker is left
   at the click, and the terminal shows `region=notch-left` and `notch-right`.
4. Move the pointer to the top edge. The menu bar should reveal and hide again.
   Click in a region afterwards and check that it still registers.
5. Mission Control: swipe between the fullscreen Space and the desktop, and
   select the Space from Mission Control. Recheck steps 2–3 after each return.
6. Press **F** again. Window A should come back at its original frame.
7. Window B: **F** should leave the band beside the housing black (ordinary
   fullscreen, a purple line marks the top of B's content). Exit.
8. Window A: **E** (disable) or **D** (detach) inside fullscreen, then **F** to
   exit. Then **A** and **E** again and repeat step 2.
9. **N** opens window C (attached). Put A and C in fullscreen on separate
   Spaces, switch between them, and click both regions in each. **W** in C closes
   it. A should be unaffected.

## License

MIT License, like the rest of FullPanelKit: see [LICENSE](../../LICENSE) and
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md). The
dependencies fetched at build time keep their own licenses.
