// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE at the repository root).
// Compile-time check of the public API used by the README quick starts and by
// the examples, plus a runtime smoke test
// that needs no display, window server session or notch.
import AppKit
import Combine
import FullPanelKit
import SwiftUI

final class AppWindow: NSWindow {}   // an application's own subclass (FullPanelSession)

@MainActor
func apiSurface() throws {
    let rect = NSRect(x: 0, y: 0, width: 400, height: 300)
    // FullPanelWindow (README AppKit quick start, Examples/FullPanelDemo).
    let window = FullPanelWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.fullPanelEnabled = true
    let state: FullPanelState = window.fullPanelState
    let reason: FullPanelFallbackReason = window.fullPanelFallbackReason
    _ = (state, reason.summary, window.isFullPanelActive, window.fullPanelDiagnostics())
    if let g = window.fullPanelGeometry, let view = window.contentView {
        _ = (g.hasCameraHousing, g.hasAuxiliaryAreas, g.topBandRect, g.belowHousingRect, g.topInset)
        _ = window.fullPanelConvertScreenRect(g.cameraHousingRect, to: view)
        _ = window.fullPanelConvertScreenRect(g.auxiliaryLeftArea, to: view)
        _ = window.fullPanelConvertScreenRect(g.auxiliaryRightArea, to: view)
    }
    let layout: FullPanelLayout = window.fullPanelLayout
    _ = (layout.isActive, layout.leftArea, layout.rightArea, layout.cameraHousing, layout.topInset, layout.contentSize)
    _ = FullPanelWindow.fullPanelSystemSupportAvailable()
    _ = FullPanelWindow.stateDidChangeNotification
    window.fullPanelRestoreSystemState()
    window.setFullPanelRootView(Text("SwiftUI"))
    _ = FullPanelWindow(contentRect: rect) { Text("SwiftUI") }

    // FullPanelSession (README SwiftUI quick start, Examples/FullPanelAttachDemo).
    let own = AppWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    own.isReleasedWhenClosed = false
    let session = try FullPanelSession.attach(to: own)
    precondition(FullPanelSession.session(for: own) === session)
    session.isEnabled = true
    _ = (session.state, session.fallbackReason, session.isActive, session.isAttached, session.window,
         session.geometry, session.layout, session.diagnostics(), FullPanelSession.systemSupportAvailable(),
         FullPanelSession.stateDidChangeNotification)
    if let g = session.geometry, let view = own.contentView { _ = session.convertScreenRect(g.topBandRect, to: view) }
    let status = FullPanelStatus(session: session)
    let sink: AnyCancellable = status.$layout.sink { _ in }
    _ = (status.layout.isActive, status.layout.cameraHousing, FullPanelStatus(window: window).layout)
    sink.cancel()
    session.restoreSystemState()
    session.detach()
    precondition(!session.isAttached && FullPanelSession.session(for: own) == nil)

    // Errors.
    do {
        _ = try FullPanelSession.attach(to: NSWindow(contentRect: rect, styleMask: [.titled],
                                                     backing: .buffered, defer: false))
        preconditionFailure("plain NSWindow must be refused")
    } catch let error as FullPanelSessionError {
        precondition(error.code == .unsupportedWindowClass)
    }
    _ = FullPanelSessionError.Code.fullPanelWindow
    _ = FullPanelDisplayGeometry(screenFrame: rect, topInset: 32, auxiliaryLeftArea: .zero, auxiliaryRightArea: .zero)
    _ = FullPanelDisplayGeometry.screensWithCameraHousing()

    // SwiftUI environment.
    struct Probe: View {
        @Environment(\.fullPanel) private var fullPanel
        var body: some View { Text(fullPanel.isActive ? "active" : "inactive") }
    }
    _ = Probe()
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    do { try apiSurface(); print("PASS: public API surface compiles and runs") }
    catch { print("FAIL: \(error)"); exit(1) }
}
