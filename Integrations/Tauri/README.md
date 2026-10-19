# FullPanelKit for Tauri (experimental)

Native macOS fullscreen for a Tauri 2 window that covers the whole display,
including the areas beside the MacBook camera housing. It is the same
FullPanelKit engine and the same `FullPanelSession` API that AppKit and Electron
applications use, reached through a small C-ABI bridge.

- Tauri **2.12.3** (tauri-runtime-wry 2.12.1, Tao 0.37.1, Wry 0.57.0), system WKWebView.
- No Tauri, Tao, Wry or WebKit changes, and no FullPanelKit engine changes:
  `build.rs` compiles `Sources/FullPanelKitCore` as it is.
- macOS only (`#![cfg(target_os = "macos")]`).


## Status

**Experimental.** On this release's code (MacBook Pro 14-inch, macOS 27.0.1,
2026-10-19) the bridge builds without warnings and `--autotest` passes 101/101.
Older records below are from an earlier development build.

On the earlier, unpublished FullPanelKit 0.1.0 candidate, which used the
previous fullscreen-frame geometry mechanism (MacBook Pro
14-inch, macOS 27.0.1):
- `cargo build --locked` succeeds without warnings;
- `--autotest` passes 101/101;
- a real screen capture shows window A drawing beside the camera housing in
  native fullscreen (window B stays black).

Mission Control returns and physical clicks were reported as verified on an
earlier SDK revision (2026-10-12), without a retained report; they have not
been re-run on the release candidate.

Details, evidence and gaps: [docs/INTEGRATION_EVIDENCE.md](../../docs/INTEGRATION_EVIDENCE.md).
Manual checks: [docs/MANUAL_ACCEPTANCE.md](../../docs/MANUAL_ACCEPTANCE.md), M4.

## Use in your app

- Requirements: macOS 13 or later, Xcode Command Line Tools, Rust (tested
  with 1.99.0), and **Tauri 2.12.3**. The workspace pins `tauri = "=2.12.3"`,
  so your app must use the same Tauri version.
- The crate is not published to crates.io (`publish = false`). Depend on the
  release tag with a git dependency; Cargo checks out the whole repository,
  and `build.rs` compiles `FullPanelKitCore` from it:

  ```toml
  [dependencies]
  fullpanelkit-tauri = { git = "<FullPanelKit repository URL>", tag = "<release tag>" }
  ```

  This route has not been exercised from a separate project yet; the test
  app uses a path dependency.

## Layout

| Path | Purpose |
|---|---|
| `fullpanelkit-tauri/build.rs` | Compiles the unchanged FullPanelKitCore sources and the bridge with `cc` (ARC, macOS 13). |
| `fullpanelkit-tauri/src/fullpanel_tauri.m` | C-ABI bridge: resolves the `NSWindow` and forwards to `FullPanelSession`. Returns JSON. |
| `fullpanelkit-tauri/src/lib.rs` | Rust API. |
| `test-app/` | Development app: window A (FullPanel), window B (control). `src/autotest.rs` holds the automated suite. |

## API

```rust
use fullpanelkit_tauri as fullpanel;

let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
    .title_bar_style(TitleBarStyle::Overlay)
    .build()?;
fullpanel::attach(&window)?;            // Ok(json) or Err(Error { code, message, details })
fullpanel::set_enabled(&window, true)?; // before entering fullscreen
window.set_fullscreen(true)?;           // Tao's native fullscreen (toggleFullScreen:)

fullpanel::state(&window)?;        // { state: { stateName: "Active" | ... }, geometry: { leftInWindow, rightInWindow, ... } }
fullpanel::diagnostics(&window)?;  // + native window facts and FullPanelSession diagnostics
fullpanel::detach(&window)?;       // also done automatically when the window closes
fullpanel::bridge_info(&app_handle)?;
```

Every function accepts a `tauri::WebviewWindow` or a `tauri::Window` (the
`NativeWindow` trait) and can be called from any thread. It runs on the main
thread inline when already there, and otherwise through `run_on_main_thread`,
waiting up to 10 s. Tauri runs getters inline on the main thread, so this does
not deadlock. The functions are free functions over a window, so a Tauri plugin
can wrap them in commands without changing them.

`geometry.leftInWindow` and `rightInWindow` are the notch-side areas in the
window's top-left coordinates. Once FullPanel is active the webview fills the
window, so these are also CSS pixels.

## How the bridge works

- `WebviewWindow::ns_window()` returns the `NSWindow` pointer itself. Electron
  hands over a content view instead. The bridge never messages the pointer until
  it has found it among `NSApp.windows`. A closed window is rejected
  (`ERR_FULLPANEL_NO_WINDOW`).
- **TaoWindow.** Tao registers `TaoWindow : NSWindow` at run time through
  `objc_allocateClassPair` (objc2 `ClassBuilder`), with only
  `canBecomeMainWindow`, `canBecomeKeyWindow`, `sendEvent:` and one ivar.
  - `class_getImageName` returns NULL for it, so `FullPanelSession`'s check
    for AppKit-owned classes passes, and correctly so: it is not an AppKit class.
  - Every selector FullPanelKit hooks is inherited, so the session adds the
    pass-through overrides to `TaoWindow` with `class_addMethod`. That works on
    a registered runtime class, because only ivars are frozen.
  - The instance's runtime class is KVO's `NSKVONotifying_TaoWindow`, already
    before attachment. The session uses `-class` (`TaoWindow`), so the hooks
    go on `TaoWindow` and the KVO subclass inherits them. Tao's `sendEvent:`
    resolves `super` through `-superclass`, which stays correct under KVO.
  - Window B is also a `TaoWindow` and gets the same pass-through overrides. It
    is verified unaffected.
- **Fullscreen entry.** `set_fullscreen(true)` calls Tao's
  `Fullscreen::Borderless`, which sends `-toggleFullScreen:` to the window on
  the main queue, so FullPanelKit arms. The green button and Control-Command-F
  take the same path. Tao first sets `Titled | Resizable` only if the style
  lacks them, which a FullPanel window never does.
- **Delegate.** `TaoWindowDelegate` stays in place. For borderless fullscreen
  its `window:willUseFullScreenPresentationOptions:` returns AppKit's proposal
  unchanged. On `windowDidExitFullScreen:` Tao reapplies the style it reads at
  that moment, asynchronously. The suite checks the style after it has run,
  including after a disable or detach inside fullscreen.
- **Frame.** `TaoWindow` does not override `contentRectForFrameRect:`, so the
  32 pt titlebar growth the Electron integration corrects does not occur here
  (`frameConversionGrowth` = 0). The bridge needs no frame correction.
- **Lifecycle.**
  - Sessions stay owned by their windows. The bridge keeps weak references,
    plus one `NSWindowWillClose` observer per attached window that detaches
    the session, since Tauri never reopens a closed window.
  - Tao's own `windowWillClose:` clears the delegate, and FullPanelKit does
    not depend on the delegate.
  - FullPanelKitCore is linked statically into the executable, so there is one
    copy of its classes (`bridge_info().fullPanelSessionImage`).

## Build and run

```sh
cd Integrations/Tauri
cargo run -p fullpanel-tauri-test                 # interactive hardware test
cargo run -p fullpanel-tauri-test -- --autotest   # automated suite, ~30 s
```

No Tauri CLI or Node is needed. The page is static (`test-app/ui`, `withGlobalTauri`).
Leave the Mac idle while `--autotest` runs, because it enters fullscreen
repeatedly on the built-in display. Reports go to `test-app/reports/*.json`,
which is git-ignored.

## Automated coverage (`test-app/src/autotest.rs`)

- **ENV.** Built-in display with a camera housing, system support available.
- **T1.** `TaoWindow : NSWindow`, registered at run time, eligible;
  `TaoWindowDelegate`; WKWebView present (Wry's runtime subclass `wry::wkwebview::class::wry_web_view::WryWebView0.57.0`).
- **T2.** Attach leaves the window's class, runtime class, delegate, content
  view, frame and style untouched. A second attach returns the same session.
  One live session. Window B unaffected.
- **T3–T5, T7.** Native fullscreen through `set_fullscreen`. The session is
  Active, the frame equals the screen (1800×1169) and WindowServer bounds
  cover the display. The WKWebView frame covers the window and the web viewport
  equals the screen. `elementFromPoint` at the centre of each notch-side area
  hits the coloured region. Exit restores the frame, style, class, WindowServer
  bounds and presentation options.
- **T6.** Window B: ordinary fullscreen leaves the camera-housing band out
  (1800×1130). B is restored afterwards and A is untouched.
- **T8.** Windowed enable → disable → enable. Disable inside fullscreen
  (presentation options restored at once, style at exit). Detach inside
  fullscreen. Reattach (new session) with a full cycle. Windowed detach and
  reattach.
- **T9.** Repeated cycles, with a move and resize in between.
- **T10.** Three create/attach/close cycles: detached on close, session
  released, stale handle rejected. Closing a window while it is in FullPanel
  fullscreen restores presentation options.

Not automated: physical clicks, visible pixels, Mission Control and Spaces.

## Hardware test (manual)

Use the built-in display. In System Settings, "Automatically hide and show the
menu bar in full screen" must not be set to *Never*.

1. `cargo run -p fullpanel-tauri-test`. Window A starts attached and enabled
   (`session: Inactive`).
2. In window A, press **Enter fullscreen**, or use the green button or
   Control-Command-F. Expect orange (left) and teal (right) to fill the band
   beside the camera housing, with no black bars.
3. Click in both coloured regions. The pointer panel and the terminal
   (`[pointer a] pointerdown …`) should show `target=#notch-left` and
   `#notch-right`.
4. Move the pointer to the top edge. The menu bar should reveal and hide again.
5. Mission Control: swipe between the fullscreen Space and the desktop, and
   select the Space from Mission Control. Recheck steps 2–3 after each return.
6. **Exit fullscreen**. Window A should come back at its original frame.
7. Window B: **Enter fullscreen** should leave the band beside the housing
   black (ordinary fullscreen). Exit.
8. Window A: **Disable** or **Detach** inside fullscreen, then exit. Then
   **Attach** and **Enable** again and repeat step 2.

## License

MIT License, like the rest of FullPanelKit: see [LICENSE](../../LICENSE) and
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md). The
dependencies fetched at build time keep their own licenses.
