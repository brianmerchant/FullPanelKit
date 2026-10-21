# FullPanelDemo

The reference app for `FullPanelWindow`. It shows FullPanel fullscreen next to
ordinary macOS fullscreen on a MacBook display with a camera housing.

In FullPanel fullscreen the window covers the whole display. A green strip
left of the camera and a blue strip right of it are part of the window: they
count every click (with a ring where the click lands), and each has a native
"+1" button. Everything else stays in the ordinary content area below them.
The demo draws nothing in place of the housing itself.

## Build and run

Requires macOS 13 or later and Xcode's Swift toolchain. FullPanel needs a
display with a camera housing; elsewhere the demo uses ordinary fullscreen and
says why.

```sh
cd Examples/FullPanelDemo
./build-demo.sh                 # builds build/FullPanelDemo.app (ad-hoc signed, not installed)
open build/FullPanelDemo.app
```

SwiftUI variant (the same content, written in SwiftUI with `\.fullPanel`):

```sh
open build/FullPanelDemo.app --args -FullPanelDemoSwiftUI YES
```

## Try it

1. Enter fullscreen: Control-Command-F, View ▸ Enter Full Screen, the green
   window button, or the window's button.
2. Click the coloured strips beside the camera.
3. Move the pointer to the very top edge: the menu bar slides in over the
   strips and hides again when you move away.
4. Use Mission Control and switch Spaces as usual.
5. Press Control-Command-F to exit; the window returns to its place.

Turn off **Use FullPanel** (View ▸ Use FullPanel, Command-E) outside
fullscreen to compare with ordinary macOS fullscreen, which leaves the strips
beside the camera black.

## For developers

- `main.swift`: creates the `FullPanelWindow` and sets `fullPanelEnabled`.
  That is the whole integration.
- `DemoView.swift` (AppKit) and `DemoSwiftUIView.swift` (SwiftUI): place
  content with `fullPanelLayout` / `\.fullPanel` (`leftArea`, `rightArea`,
  `topInset`).
- Developer ▸ Write Diagnostics Report (Command-R) writes
  `~/Downloads/FullPanelDemo-report.json` (engine diagnostics and click counts).
- `-FullPanelTrace YES` logs a timestamped engine trace (Console.app, process
  "FullPanelDemo"). `-FullPanelDemoLabel A` tints the window and labels it,
  for tests with several instances. `-FullPanelDemoTitlebarAccessory YES`
  gives the window a hidden titlebar accessory view controller, the
  configuration in which AppKit keeps the fullscreen titlebar window opaque.

A screenshot shows what the app draws, including the strips. It cannot show
the physical camera housing, which hides the middle of the band.
