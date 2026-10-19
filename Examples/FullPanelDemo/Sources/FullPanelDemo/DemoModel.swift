// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// State shared by the AppKit and SwiftUI demo content: the window's
// fullscreen / FullPanel status and the click counters beside the housing.
// It only observes the window; FullPanelWindow needs nothing from it.

import AppKit
import Combine
import FullPanelKit

@MainActor
final class DemoModel: ObservableObject {
    private(set) weak var window: FullPanelWindow?
    @Published var leftClicks = 0
    @Published var rightClicks = 0
    private var tokens: [NSObjectProtocol] = []

    func attach(to window: FullPanelWindow) {
        self.window = window
        let names: [Notification.Name] = [
            FullPanelWindow.stateDidChangeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification
        ]
        for name in names {
            tokens.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            })
        }
        objectWillChange.send()
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    var layout: FullPanelLayout { window?.fullPanelLayout ?? FullPanelLayout() }
    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    var isFullPanelEnabled: Bool {
        get { window?.fullPanelEnabled ?? false }
        set {
            window?.fullPanelEnabled = newValue
            objectWillChange.send()
        }
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    func resetClicks() { leftClicks = 0; rightClicks = 0 }

    /// One-line status for the window, in the terms the demo explains.
    var statusTitle: String {
        let layout = self.layout
        switch layout.state {
        case .disabled:
            return isFullScreen ? "Ordinary macOS fullscreen" : "FullPanel off"
        case .inactive:
            return "Ready: enter fullscreen"
        case .active:
            return "FullPanel active"
        case .fallback:
            return "Ordinary fullscreen (fallback)"
        @unknown default:
            return "Unknown state"
        }
    }

    var statusDetail: String {
        let layout = self.layout
        switch layout.state {
        case .disabled:
            return isFullScreen
                ? "FullPanel is off, so macOS keeps the window below the camera housing."
                : "Fullscreen will be ordinary macOS fullscreen, for comparison."
        case .inactive:
            if layout.fallbackReason != .none {
                return "Last fullscreen fell back: \(layout.fallbackReason.summary)."
            }
            return displayDescription
        case .active:
            return "The window covers the whole display, including the strips beside the camera."
        case .fallback:
            return layout.fallbackReason.summary
        @unknown default:
            return ""
        }
    }

    var statusColor: NSColor {
        switch layout.state {
        case .active: return .systemGreen
        case .inactive: return .systemBlue
        case .fallback: return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    private var displayDescription: String {
        guard let geometry = window?.fullPanelGeometry else { return "No display." }
        return geometry.hasCameraHousing
            ? "This display has a camera housing (\(Int(geometry.topInset)) pt band)."
            : "This display has no camera housing; fullscreen will be ordinary."
    }
}
