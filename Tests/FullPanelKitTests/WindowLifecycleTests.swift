// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Window-level tests that do not need a notched display and never enter
// fullscreen. Fullscreen behavior is verified on hardware (docs/HARDWARE_BASELINE.md).

import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import FullPanelKit

private final class RecordingDelegate: NSObject, NSWindowDelegate {
    var shouldCloseAsked = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseAsked = true
        return false
    }
}

@MainActor
final class WindowLifecycleTests: XCTestCase {
    private func makeWindow() -> FullPanelWindow {
        _ = NSApplication.shared
        let w = FullPanelWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                                styleMask: [.titled, .closable, .resizable],
                                backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    func testDefaultsToDisabled() {
        let w = makeWindow()
        XCTAssertFalse(w.fullPanelEnabled)
        XCTAssertEqual(w.fullPanelState, .disabled)
        XCTAssertEqual(w.fullPanelFallbackReason, .none)
        XCTAssertFalse(w.isFullPanelActive)
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView))
    }

    func testEnablingAppliesAndDisablingRestoresTestedStyle() {
        let w = makeWindow()
        w.titlebarAppearsTransparent = false
        let originalBehavior = w.collectionBehavior
        w.fullPanelEnabled = true
        XCTAssertEqual(w.fullPanelState, .inactive)
        XCTAssertTrue(w.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(w.titlebarAppearsTransparent)
        XCTAssertTrue(w.collectionBehavior.contains(.fullScreenPrimary))
        w.fullPanelEnabled = false
        XCTAssertEqual(w.fullPanelState, .disabled)
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(w.titlebarAppearsTransparent)
        XCTAssertEqual(w.collectionBehavior, originalBehavior)
    }

    func testPreexistingStyleIsPreserved() {
        let w = makeWindow()
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.fullPanelEnabled = true
        w.fullPanelEnabled = false
        XCTAssertTrue(w.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(w.titlebarAppearsTransparent)
    }

    func testStateChangePostsNotification() {
        let w = makeWindow()
        let posted = expectation(forNotification: FullPanelWindow.stateDidChangeNotification,
                                 object: w)
        w.fullPanelEnabled = true
        wait(for: [posted], timeout: 1)
    }

    func testStateIsKeyValueObservable() {
        let w = makeWindow()
        var seen: [FullPanelState] = []
        let observation = w.observe(\.fullPanelState, options: [.new]) { window, _ in
            seen.append(window.fullPanelState)
        }
        w.fullPanelEnabled = true
        w.fullPanelEnabled = false
        observation.invalidate()
        XCTAssertEqual(seen, [.inactive, .disabled])
    }

    func testRestoreIsIdempotentAndLeavesPresentationAlone() {
        let w = makeWindow()
        w.fullPanelEnabled = true
        let before = NSApp?.presentationOptions
        w.fullPanelRestoreSystemState()
        w.fullPanelRestoreSystemState()
        XCTAssertEqual(NSApp?.presentationOptions, before)
        XCTAssertEqual(w.fullPanelState, .inactive)
    }

    func testCloseCleansUp() {
        let w = makeWindow()
        w.fullPanelEnabled = true
        w.close()
        XCTAssertEqual(w.fullPanelState, .inactive)
        XCTAssertEqual(w.fullPanelDiagnostics()["menuBarOverrideSubmitted"] as? Bool, false)
    }

    // The window's delegate is the application's own object: FullPanelWindow
    // does not wrap it, so AppKit sends it every message directly.
    func testDelegateIsTheApplicationsOwnObject() {
        let w = makeWindow()
        XCTAssertNil(w.delegate)
        let delegate = RecordingDelegate()
        w.delegate = delegate
        XCTAssertTrue(w.delegate === delegate)
        w.fullPanelEnabled = true
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: w)
        XCTAssertTrue(w.delegate === delegate)
        w.performClose(nil)
        XCTAssertTrue(delegate.shouldCloseAsked, "AppKit asked the application's delegate")
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: w)
        w.delegate = nil
        XCTAssertNil(w.delegate)
        w.fullPanelEnabled = false
    }

    // FullPanelWindow's class and NSWindow keep their method tables through
    // creation, enable, an entry's preparation and disable; ordinary windows
    // are untouched.
    func testNoWindowClassIsModified() {
        _ = makeWindow()   // the first FullPanelWindow is created before the snapshot
        let before = methodSnapshot(FullPanelWindow.self, to: NSObject.self)
        let w = makeWindow()
        w.fullPanelEnabled = true
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: w)
        _ = FullPanelWindow.fullPanelSystemSupportAvailable()
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: true)
        plain.isReleasedWhenClosed = false
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: w)
        w.fullPanelEnabled = false
        XCTAssertEqual(methodSnapshot(FullPanelWindow.self, to: NSObject.self), before)
        XCTAssertEqual(blockImplementations(FullPanelWindow.self), [])
        XCTAssertFalse(plain.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(plain is FullPanelWindow)
    }

    // FullPanelWindow overrides no frame setter, -toggleFullScreen: or private
    // fullscreen method, so a subclass's overrides behave as on NSWindow.
    func testFullPanelWindowOverridesNoFrameOrFullScreenMethod() {
        let own = Set(ownMethods(FullPanelWindow.self).keys)
        for name in ["setFrame:display:", "setFrame:display:animate:", "setFrameOrigin:",
                     "setFrameTopLeftPoint:", "setContentSize:", "toggleFullScreen:",
                     "setDelegate:", "delegate", "_frameForFullScreenMode"] {
            XCTAssertFalse(own.contains(name), name)
        }
    }

    func testIndependentWindowsHaveIndependentState() {
        let a = makeWindow(), b = makeWindow()
        a.fullPanelEnabled = true
        XCTAssertEqual(a.fullPanelState, .inactive)
        XCTAssertEqual(b.fullPanelState, .disabled)
        XCTAssertFalse(b.styleMask.contains(.fullSizeContentView))
    }

    func testSwiftUIHostingKeepsEngineWindow() {
        _ = NSApplication.shared
        let w = FullPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300)) {
            EmptyHostedView()
        }
        w.isReleasedWhenClosed = false
        XCTAssertTrue(w.contentView is NSHostingView<FullPanelRootView<EmptyHostedView>>)
        w.fullPanelEnabled = true
        XCTAssertEqual(w.fullPanelLayout.state, .inactive)
    }
}

struct EmptyHostedView: View {
    var body: some View { Color.clear }
}
