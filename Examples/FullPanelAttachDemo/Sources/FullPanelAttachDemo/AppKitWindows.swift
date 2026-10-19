// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// Ordinary AppKit windows for the compatibility baseline: a plain NSWindow
// (no subclass), a plain NSWindowController and an ordinary NSWindowDelegate,
// with the demo's SwiftUI content hosted in an NSHostingView. The `.appkit`
// window is offered to FullPanelSession (which must reject it); the
// `.appkitControl` window is never touched. The `.appkitSubclass` window is
// the supported AppKit integration: the application's own NSWindow subclass,
// created as that class, with FullPanelSession attached.

import AppKit
import SwiftUI

/// The application's own window class. It needs no overrides: FullPanelSession
/// installs its pass-through overrides on this class (never on NSWindow).
final class FullPanelAppKitDemoWindow: NSWindow {}

/// An ordinary delegate that only counts what AppKit sends it.
final class AppKitWindowDelegate: NSObject, NSWindowDelegate {
    private(set) var counts: [String: Int] = [:]
    var onClose: ((NSWindow) -> Void)?

    private func bump(_ name: String) { counts[name, default: 0] += 1 }

    func windowShouldClose(_ sender: NSWindow) -> Bool { bump("shouldClose"); return true }
    func windowWillClose(_ notification: Notification) {
        bump("willClose")
        if let window = notification.object as? NSWindow { onClose?(window) }
    }
    func windowDidResize(_ notification: Notification) { bump("didResize") }
    func windowWillEnterFullScreen(_ notification: Notification) { bump("willEnterFS") }
    func windowDidEnterFullScreen(_ notification: Notification) { bump("didEnterFS") }
    func windowWillExitFullScreen(_ notification: Notification) { bump("willExitFS") }
    func windowDidExitFullScreen(_ notification: Notification) { bump("didExitFS") }

    var summary: String {
        counts.isEmpty ? "none"
            : counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

@MainActor
enum AppKitWindows {
    struct Entry {
        let controller: NSWindowController
        let delegate: AppKitWindowDelegate
        let role: WindowModel.Role
    }

    private(set) static var entries: [Entry] = []

    static func entry(for window: NSWindow?) -> Entry? {
        entries.first { $0.controller.window === window }
    }

    static func delegateSummary(for window: NSWindow) -> String? { entry(for: window)?.delegate.summary }

    /// Creates and shows one ordinary NSWindow with its own controller and delegate.
    @discardableResult
    static func open(role: WindowModel.Role) -> Entry {
        precondition(role == .appkit || role == .appkitControl || role == .appkitSubclass)
        let screen = (NSScreen.main ?? NSScreen.screens[0])
        let size = NSSize(width: 800, height: 560)
        let offset = CGFloat(entries.count % 6) * 24
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2 + offset,
                             y: screen.visibleFrame.midY - size.height / 2 - offset)
        // `.appkitSubclass` is created as the subclass from the start; the class
        // is never changed afterwards.
        let windowClass: NSWindow.Type = role == .appkitSubclass ? FullPanelAppKitDemoWindow.self : NSWindow.self
        let window = windowClass.init(contentRect: NSRect(origin: origin, size: size),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
        window.title = role == .appkit ? "AppKit NSWindow (FullPanelSession must reject)"
            : role == .appkitSubclass ? "AppKit NSWindow subclass + FullPanelSession"
            : "AppKit NSWindow — untouched control"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]   // ordinary opt-in to native fullscreen
        window.contentView = NSHostingView(rootView: ContentView(role: role))

        let delegate = AppKitWindowDelegate()
        window.delegate = delegate
        let controller = NSWindowController(window: window)
        let entry = Entry(controller: controller, delegate: delegate, role: role)
        delegate.onClose = { closed in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { entries.removeAll { $0.controller.window === closed } }
            }
        }
        entries.append(entry)
        controller.showWindow(nil)
        return entry
    }

    /// The test window and, if none is open, an untouched control window.
    static func openPair() {
        open(role: .appkit)
        if !entries.contains(where: { $0.role == .appkitControl }) { open(role: .appkitControl) }
    }

    static func closeAll() {
        for entry in entries { entry.controller.close() }
    }
}
