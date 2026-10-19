# FullPanelKit for Electron (experimental)

Native macOS fullscreen for an Electron `BrowserWindow` that covers the whole
display, including the areas beside the MacBook camera housing. It is the same
FullPanelKit engine and the same `FullPanelSession` API that AppKit
applications use, reached through a Node-API addon.

- Prebuilt Electron **44.7.0** (Node 24.21.0, Node-API 10, Chromium 152).
- No Electron or Chromium source changes, and no FullPanelKit engine changes:
  `binding.gyp` compiles `Sources/FullPanelKitCore` as it is.
- Main process only. Every call runs on the macOS main thread.


## Status

**Experimental.** On this release's code (MacBook Pro 14-inch, macOS 27.0.1,
2026-10-19) the bridge builds without warnings and `npm run autotest` passes 63/63.
Older records below are from an earlier development build.

On the earlier, unpublished FullPanelKit 0.1.0 candidate, which used the
previous fullscreen-frame geometry mechanism (MacBook Pro
14-inch, macOS 27.0.1):
- `npm run build` succeeds without warnings against Electron 44.7.0;
- `npm run autotest` passes 63/63;
- a real screen capture shows window A drawing beside the camera housing in
  native fullscreen (the control window stays black).

Mission Control returns and physical clicks were last verified on an earlier
SDK revision (2026-10-12, see "Verification record"); they have not been
re-run on the release candidate.

Details, evidence and gaps: [docs/INTEGRATION_EVIDENCE.md](../../docs/INTEGRATION_EVIDENCE.md).
Manual checks: [docs/MANUAL_ACCEPTANCE.md](../../docs/MANUAL_ACCEPTANCE.md), M4.

## Use in your app

- Requirements: macOS 13 or later, Xcode Command Line Tools, Node.js with
  npm, and Electron **44.7.0**. Other Electron versions are untested; the
  addon is built against one Electron version's headers and must be rebuilt
  for another.
- `binding.gyp` compiles `FullPanelKitCore` from this repository by relative
  path (`../../Sources/FullPanelKitCore`). Build the addon inside a checkout
  of the FullPanelKit release (for example a git submodule pinned to the
  release tag), then `require()` that checkout's `Integrations/Electron`
  from your main process. The package is not published to npm.
- Use it from the main process only (see API).

## Layout

| Path | Purpose |
|---|---|
| `binding.gyp` | Builds `fullpanel_electron.node` from the addon and the unchanged FullPanelKitCore sources (ARC, macOS 13). |
| `src/fullpanel_electron.mm` | Node-API bridge: resolves window handles and forwards to `FullPanelSession`. |
| `index.js` | JavaScript API (main process). |
| `test-app/` | Test app: window A (FullPanel), window B (control). `autotest.js` holds the automated suite. |

## Build

```sh
cd Integrations/Electron
npm install            # electron@44.7.0 (exact pin); nothing global
npx --no install-electron   # Electron 44 downloads its binary on first use
npm run build          # node-gyp (bundled with npm) against Electron 44.7.0 headers
```

## API

```js
const fullPanel = require('./Integrations/Electron');

const win = new BrowserWindow({ titleBarStyle: 'hidden' /* ... */ });
fullPanel.attach(win);            // { ok, ... } or { ok: false, code, message }
fullPanel.setEnabled(win, true);  // before entering fullscreen
win.setFullScreen(true);          // native fullscreen (not simpleFullScreen, not kiosk)

fullPanel.getState(win);          // { attached, enabled, stateName: 'Active' | ... }
fullPanel.getGeometry(win);       // notch-side rects, screen and content (top-left) coords
fullPanel.getDiagnostics(win);    // native window facts + FullPanelSession diagnostics
fullPanel.detach(win);            // also done automatically when the window closes
```

Every function accepts a `BrowserWindow` or the Buffer from
`getNativeWindowHandle()`.

## How the bridge works

- `getNativeWindowHandle()` returns a pointer to the window's **content view**
  (`BridgedContentView`), not to the `NSWindow`. The addon never sends a
  message to that address. It compares it with the views of
  `NSApp.windows`, which yields the owning `ElectronNSWindow`. A malformed,
  null, unknown or closed-window handle throws (`ERR_FULLPANEL_HANDLE`,
  `ERR_FULLPANEL_NO_WINDOW`).
- `FullPanelSession` attaches to `ElectronNSWindow`, which lives in Electron
  Framework, not AppKit. Its runtime class is KVO's
  `NSKVONotifying_ElectronNSWindow`, and the session uses `-class`. The
  window's class, delegate (`ElectronNSWindowDelegate`) and content view are
  never changed, and no `NSWindow`-wide hook is installed.
- Sessions stay owned by their windows. The addon keeps only weak references.
  `attach(browserWindow)` detaches the session on the window's `closed` event.
  An `NSWindowWillClose` observer is the backstop for callers that pass raw
  handles. Electron emits `closed` before AppKit closes the `NSWindow` (about
  14 ms later on hardware). When the app quits, AppKit does not close it before
  the process exits, so without the `closed` hook a session would stay attached
  through `will-quit`.
- FullPanelKitCore's classes are checked to be registered by this addon. A
  second copy in the process makes loading fail with
  `ERR_FULLPANEL_DUPLICATE_CLASSES`.

### Electron-specific behavior

- **Fullscreen entry.** `setFullScreen(true)` on a *visible* window sends
  `-toggleFullScreen:` to the window, so FullPanelKit arms. On a hidden window
  Electron calls `[super toggleFullScreen:]`, which bypasses the per-class
  hook, so the window gets ordinary fullscreen. Show the window first. The green
  button, View ▸ Toggle Full Screen and Control-Command-F all work.
- **Frame preservation.** Disabling or detaching restores the window's
  original style, which removes `NSWindowStyleMaskFullSizeContentView`. AppKit
  keeps the content rect across that style change. It asks the window for
  `-contentRectForFrameRect:`, which `ElectronNSWindow` overrides to return the
  whole frame for a `titleBarStyle: 'hidden'` window. It then derives the new
  frame with its own `-frameRectForContentRect:`, which adds the titlebar. The
  frame grows upward by the titlebar height (32 pt on macOS 27) with the bottom
  edge fixed. Electron avoids this for its own style changes with
  `ScopedDisableResize`. The addon undoes the growth: when windowed,
  immediately; when disabled or detached inside fullscreen, right after
  fullscreen exits, where FullPanelKit restores the style.
  - It acts only if the current frame is exactly what that conversion produces
    from the pre-change size at the same bottom-left origin. It shrinks the
    window in place and never moves it or reuses old coordinates.
  - The size recorded at fullscreen entry is used only to recognise the growth.
    A session attached while the window is already in fullscreen has no such
    size and never applied the style, so nothing is corrected.
  - Every decision is listed in `addonInfo().frameCorrections`.
- Enabling adds `fullSizeContentView` (already effectively the case for hidden
  titlebars) and `fullScreenPrimary`. Window A's frame, content bounds,
  viewport and traffic lights are unchanged (checks W1–W4).
- Standard framed windows (`titleBarStyle: 'default'`) are untested. Enabling
  would put web content under the titlebar while windowed.

## Tests

```sh
npm run bridge-check   # Phase 1: load, main thread, handle → NSWindow, class eligibility
npm run autotest       # Phase 1 plus the regression suite (enters fullscreen on the built-in display, ~20 s)
npm start              # interactive hardware test
```

Leave the Mac idle while `npm run autotest` runs. It enters fullscreen
repeatedly, and a Space switch or Mission Control during the run fails the
`ENV` precondition or a later transition.

Reports are written to `test-app/reports/*.json` (git-ignored). The
autotest never simulates Mission Control or clicks. Those tests are listed as
`NOT RUN (manual hardware test)`.

Automated coverage (`test-app/autotest.js`):
- **Bridge.** Load, main thread, handle → `NSWindow`, class eligibility,
  malformed handles.
- **Root cause.** The frame/content conversion grows the frame by 32 pt without
  `fullSizeContentView`, and not at all with it.
- **Windowed.** Enable → disable → enable keeps the frame, WindowServer bounds,
  viewport and traffic lights. Disable undoes exactly the 32 pt growth, once.
- **Fullscreen through `setFullScreen`.** Native frame and WindowServer bounds
  versus the display, the renderer viewport recorded separately, and
  `capturePage` pixels in both notch-side regions.
- **Move and resize before fullscreen.** Three moved/resized layouts, each
  through a full cycle (repeated cycles). Native frame and WindowServer bounds
  are checked before and after.
- **Inside fullscreen.** Disable or detach inside fullscreen, after
  moving/resizing. Attach while already in fullscreen, with and without detach.
- **Window B (unattached).** Untouched throughout; ordinary fullscreen
  1800×1130.
- **Cleanup.**
  - Close, plus stale-handle rejection.
  - Two windows closed independently.
  - Five create/destroy cycles.
  - Quit with an attached windowed or fullscreen window, in a child Electron
    process.

## Hardware test (manual)

Use the built-in display and close Split View. In System Settings, "Automatically
hide and show the menu bar in full screen" must not be set to *Never*.

Each step in window A has **Start**, **Pass** and **Fail**. Press **Start**, do
the step, then judge it. The report stores your verdict with the evidence
gathered since Start:
- every pointer event, with the FullPanel state and the window and WindowServer
  geometry at that moment;
- the window-state timeline;
- an automatic evaluation (`evidence.satisfied`).

Pointer steps count only *trusted* `pointerdown` events in the named region
while FullPanel is Active and covers the display. Mission Control steps need an
observed away and return: the window off the active Space, not visible, not
key or blurred, or WindowServer showing it at thumbnail size, followed by Active
again.

1. `npm start`. Window A (dark grid) and window B (grey) open on the built-in
   display. The terminal prints `Window A: attached (ElectronNSWindow), enabled`.
2. In A, click **Enter fullscreen**. The readout should show:
   - `session: Active (enabled)`
   - `NSWindow frame: 0,0 1800×1169 covers screen: YES`
   - `WindowServer bounds: 0,0 1800×1169 covers display: YES`
   - `viewport (renderer): 1800×1169`
3. **Pixels.** Start, check the magenta strip left of the notch and the cyan strip
   right of it, then Pass.
4. **Click left / click right.** Start, click inside the strip, then Pass. Keep
   off the very top edge, which reveals the menu bar.
5. **Mission Control: small Space thumbnail.** Start, open Mission Control (F3 or
   Control-↑), click A's Space thumbnail at the top, then Pass if it is Active
   and covers the display. Repeat for the **large window thumbnail** and the
   **swipe** (swipe up with three or four fingers, then down).
6. **After a Mission Control return: click left AND right.** Start. Go to
   Mission Control and back by any route. Then click inside the magenta strip
   and inside the cyan strip. The status line shows `away ✓ return ✓ left ✓
   right ✓` before you Pass.
7. **Exit.** Start, click **Exit fullscreen**, then check three things before you
   Pass:
   - the window is back at its original position and size;
   - the traffic lights are back in their windowed position;
   - the hidden-titlebar look is unchanged: content reaches the top edge, and no
     title text or titlebar strip appears. Window A uses
     `titleBarStyle: 'hidden'`, so there is no visible titlebar to restore.
8. **Optional checks.** None needs an external display to pass the main suite.
   - Resize, then fullscreen and exit.
   - Move, then fullscreen and exit.
   - **Disable**, then fullscreen (ordinary, 1130). Exit, **Enable**, then
     fullscreen (whole display).
   - Three cycles in a row.
   - With an external display: move A there; fullscreen reports Fallback (no
     camera housing); move it back; Active.
9. **Window B.** **Enter fullscreen** in B: 1800×1130, no markers, no session.
   Exit.
10. Quit, or click **Save report**. The report is
    `test-app/reports/interactive-*.json`. `liveSessionsBeforeQuit` still shows
    A attached, because Electron has not closed it yet.
    `liveSessionsAfterWindowsClosed` shows it detached.

## Verification record (2026-10-12)

Historical: recorded on an earlier FullPanelKit revision, before the
release candidate. The report files named below were not retained, so this
record cannot be re-inspected. For the release candidate, see "Status".

MacBook Pro 14-inch (built-in display 1800×1169 pt, 38 pt camera housing),
macOS 27.0.1, Electron 44.7.0 (Chromium 152, Node 24.21.0). FullPanelKit
engine unchanged.

**Automated:** `npm run autotest` passed 63/63, plus 2/2 informational
(`autotest-2026-10-12T18-08-31-109Z.json`). Two earlier back-to-back runs of
the same suite, before the `ENV` precondition was added, passed 62/62.

**Hardware (manual):** `interactive-2026-10-12T18-15-03-993Z.json`, recorded
18:15–18:25. The tester reports that all manual tests passed. The report
contains the following.

| Step | Recorded verdict | Evidence in the report |
|---|---|---|
| Notch-side pixels visible | Pass | At verdict: Active, frame 0,0 1800×1169, WindowServer covers display |
| Click left of notch | Pass | Trusted left-side clicks while Active at 18:15:21 and 18:15:48, but neither inside the step's Start→verdict window, so `satisfied: false` |
| Click right of notch | No verdict recorded | Trusted right-side clicks while Active at 18:15:29 and 18:15:51 |
| Mission Control → small Space thumbnail | Pass | `satisfied: true`: away, then back to Active, covering |
| Mission Control → large window thumbnail | Pass | `satisfied: true` |
| Mission Control → swipe | Pass | `satisfied: true` |
| After Mission Control: click left and right | Pass | `satisfied: true`: trusted mouse `pointerdown` at (509, 10) left and (1144, 19) right, after the observed return, Active, frame and WindowServer covering the display |
| Exit restores the window | Fail at 18:17:43, then Pass ×2 (18:20) | At the Fail the frame was already the original 60,390 1000×680; no reason recorded. Recorded under the earlier wording "…restores the windowed frame and titlebar", since corrected |
| Optional: resize, move, disable/re-enable, repeated cycles | Pass | Most of these actions happened outside the steps' Start windows; the event log shows them |
| Optional: display switch | Pass | Fallback fullscreen on a 1539×1070 external display (18:25:01–05). An Active entry on the built-in display after switching back is not in the report |

Observations:
- In each Mission Control step, the first away signal was the WindowServer
  thumbnail size (`windowServerMatchesFrame` false). Over those steps the
  timeline also shows the window off the active Space, occluded, not key, and
  `blur`/`focus` events.
- This report was written with **Save report** while the app was still
  running. Session cleanup at quit is covered by the automated `S1` checks.

## License

MIT License, like the rest of FullPanelKit: see [LICENSE](../../LICENSE) and
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md). The
dependencies fetched at build time keep their own licenses.
