# FullPanelAttachDemo

A technical example of `FullPanelSession`: FullPanel attached to windows the
app did not create as `FullPanelWindow`. SwiftUI creates every `WindowGroup`
window here; `FullPanelSession.attach(to:)` adds FullPanel to the existing
`NSWindow` without replacing or subclassing it. The same app also hosts the
hardware scenarios and autotests described in
[docs/TESTING.md](../../docs/TESTING.md).

## Build and run

```sh
cd Examples/FullPanelAttachDemo
./build-demo.sh                 # builds build/FullPanelAttachDemo.app (ad-hoc signed, not installed)
open build/FullPanelAttachDemo.app
```

The first window attaches on appearance. Enter fullscreen (Control-Command-F,
the green window button or **Enter Full Screen**) and click the green and blue
strips beside the camera. **Detach** and **Attach** remove and re-add the
session; **FullPanel enabled** switches it without detaching.

**Open another window** compares integrations in one process:

| Button | Window | FullPanel |
| --- | --- | --- |
| SwiftUI + session | another `WindowGroup` window | attached |
| Ordinary SwiftUI | same window class | never attached: ordinary fullscreen |
| FullPanelWindow | app-created `FullPanelWindow` | built in |
| Plain NSWindow (rejected) | a plain `NSWindow` plus an untouched control window | refused with an error; the window is left unchanged |

For AppKit apps, the supported path is your own `NSWindow` subclass, created
as that class, with `FullPanelSession` attached (`FullPanelAppKitDemoWindow`
in `AppKitWindows.swift`, exercised by the AppKit-subclass autotest in
docs/TESTING.md). `-FullPanelAttachOpenAppKit YES` opens the plain-window pair
at launch. See [docs/ATTACHMENT.md](../../docs/ATTACHMENT.md) for the session
contract.

The Diagnostics section shows the window's class and controller, the
attachment state and the housing geometry. Toggle the KVO probe to log frame,
style and content-view changes. `-FullPanelTrace YES` logs the engine trace.
