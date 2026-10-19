// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Thin SwiftUI layer. It hosts SwiftUI content inside a FullPanelWindow, or
// follows a SwiftUI-created window attached with FullPanelSession; the
// fullscreen behavior is entirely the AppKit engine's. There is no second
// fullscreen mechanism here.

import AppKit
import Combine
import SwiftUI

/// Observable FullPanel status for one window: a FullPanelWindow, or an
/// existing window through its FullPanelSession.
@MainActor
public final class FullPanelStatus: ObservableObject {
    @Published public private(set) var layout = FullPanelLayout()
    /// The FullPanelWindow, when created with `init(window:)`.
    public private(set) weak var window: FullPanelWindow?
    /// The session, when created with `init(session:)`.
    public private(set) weak var session: FullPanelSession?
    private var tokens: [NSObjectProtocol] = []

    public init(window: FullPanelWindow) {
        self.window = window
        observe(window: window, stateNotification: FullPanelWindow.stateDidChangeNotification,
                stateObject: window)
    }

    /// Follows an attached window. The status holds the session weakly.
    public init(session: FullPanelSession) {
        self.session = session
        observe(window: session.window, stateNotification: FullPanelSession.stateDidChangeNotification,
                stateObject: session)
    }

    private func observe(window: NSWindow?, stateNotification: Notification.Name, stateObject: AnyObject) {
        let center = NotificationCenter.default
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        tokens.append(center.addObserver(forName: stateNotification, object: stateObject,
                                         queue: .main, using: handler))
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification
        ]
        if let window {
            for name in names {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main,
                                                 using: handler))
            }
        }
        refresh()
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    public func refresh() {
        let next: FullPanelLayout
        if let window {
            next = window.fullPanelLayout
        } else if let session {
            next = session.layout
        } else {
            return
        }
        if next != layout { layout = next }
    }
}

private struct FullPanelLayoutKey: EnvironmentKey {
    static let defaultValue = FullPanelLayout()
}

extension EnvironmentValues {
    /// Camera-housing layout of the enclosing FullPanel window, in the root
    /// view's coordinate space (top-left origin).
    public var fullPanel: FullPanelLayout {
        get { self[FullPanelLayoutKey.self] }
        set { self[FullPanelLayoutKey.self] = newValue }
    }
}

/// Root wrapper: lets content extend into the camera-housing band and
/// publishes the layout through `\.fullPanel`.
public struct FullPanelRootView<Content: View>: View {
    @ObservedObject private var status: FullPanelStatus
    private let content: Content

    public init(status: FullPanelStatus, @ViewBuilder content: () -> Content) {
        self.status = status
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.fullPanel, status.layout)
            // The engine gives the window the whole display; SwiftUI must not
            // push content back below the housing.
            .ignoresSafeArea()
    }
}

extension FullPanelWindow {
    /// Creates a FullPanel window hosting SwiftUI content.
    ///
    ///     let window = FullPanelWindow(contentRect: rect) { ContentView() }
    ///     window.fullPanelEnabled = true
    ///     window.makeKeyAndOrderFront(nil)
    @MainActor
    public convenience init<Content: View>(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable],
        @ViewBuilder rootView: () -> Content
    ) {
        self.init(contentRect: contentRect, styleMask: styleMask,
                  backing: .buffered, defer: false)
        setFullPanelRootView(rootView())
    }

    /// Replaces the content view with SwiftUI content wrapped in
    /// `FullPanelRootView`. Returns the hosting view.
    @MainActor
    @discardableResult
    public func setFullPanelRootView<Content: View>(_ view: Content) -> NSView {
        let status = FullPanelStatus(window: self)
        let hosting = NSHostingView(rootView: FullPanelRootView(status: status) { view })
        // Do not let SwiftUI's ideal size drive the window frame; the engine's
        // frame guard owns the fullscreen frame.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        contentView = hosting
        return hosting
    }
}
