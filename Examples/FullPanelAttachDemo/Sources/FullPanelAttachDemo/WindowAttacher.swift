// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// Hands the SwiftUI-created NSWindow to a callback, synchronously from
// viewDidMoveToWindow.

import AppKit
import SwiftUI

struct WindowAttacher: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AttachmentView(frame: .zero)
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AttachmentView)?.onWindow = onWindow
        onWindow(nsView.window)
    }

    private final class AttachmentView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
