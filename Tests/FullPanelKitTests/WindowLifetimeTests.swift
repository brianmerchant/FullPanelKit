// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Window lifetime: FullPanel state must let go of a window that is being freed
// (OmacVM #402: a fullscreen window freed while its FullPanel state could still
// ask it -isKeyWindow). These tests never enter fullscreen. Where a test needs
// the engine to believe the window is in fullscreen, the window reports the
// FullScreen style bit itself (`LifetimeProbe.fakeFullScreen`).

import AppKit
import XCTest
@testable import FullPanelKit

/// Records messages FullPanelKit sends a window after its deallocation began.
/// Attribution is by call stack, so AppKit's own calls during -dealloc are not
/// counted.
enum LifetimeProbe {
    nonisolated(unsafe) static var touchedAfterDealloc: [String] = []

    static func record(_ what: String, deallocating: Bool) {
        guard deallocating else { return }
        let fromFullPanel = Thread.callStackSymbols.contains {
            $0.contains("FPKEngine") || $0.contains("FullPanelSession") || $0.contains("FPKSessionOwner")
        }
        if fromFullPanel { touchedAfterDealloc.append(what) }
    }
}

/// An application window class (attachable) that reports late messages.
class ProbeWindow: NSWindow {
    var deallocating = false
    var fakeFullScreen = false
    var fakeScreen: NSScreen??   // .some(nil): no screen

    deinit { deallocating = true }

    override var styleMask: NSWindow.StyleMask {
        get {
            LifetimeProbe.record("styleMask", deallocating: deallocating)
            return fakeFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask
        }
        set { super.styleMask = newValue }
    }
    override var isKeyWindow: Bool {
        LifetimeProbe.record("isKeyWindow", deallocating: deallocating)
        return super.isKeyWindow
    }
    override var screen: NSScreen? {
        LifetimeProbe.record("screen", deallocating: deallocating)
        if let fakeScreen { return fakeScreen }
        return super.screen
    }
    override var frame: NSRect {
        LifetimeProbe.record("frame", deallocating: deallocating)
        return super.frame
    }
    override var acceptsMouseMovedEvents: Bool {
        get { super.acceptsMouseMovedEvents }
        set {
            LifetimeProbe.record("setAcceptsMouseMovedEvents", deallocating: deallocating)
            super.acceptsMouseMovedEvents = newValue
        }
    }
}

/// The same probes on a FullPanelWindow.
final class ProbeFullPanelWindow: FullPanelWindow {
    var deallocating = false
    deinit { deallocating = true }
    override var styleMask: NSWindow.StyleMask {
        get { LifetimeProbe.record("styleMask", deallocating: deallocating); return super.styleMask }
        set { super.styleMask = newValue }
    }
    override var isKeyWindow: Bool {
        LifetimeProbe.record("isKeyWindow", deallocating: deallocating)
        return super.isKeyWindow
    }
    override var acceptsMouseMovedEvents: Bool {
        get { super.acceptsMouseMovedEvents }
        set {
            LifetimeProbe.record("setAcceptsMouseMovedEvents", deallocating: deallocating)
            super.acceptsMouseMovedEvents = newValue
        }
    }
}

@MainActor
final class WindowLifetimeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        LifetimeProbe.touchedAfterDealloc = []
    }

    private func make<W: NSWindow>(_ type: W.Type) -> W {
        let w = W(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    /// Puts the engine where its teardown restores window state (reveal
    /// tracking running, presentation forced), as in fullscreen, without
    /// changing anything outside the process.
    private func armTeardownThatTouchesTheWindow(_ engine: NSObject) {
        engine.setValue(true, forKey: "fpkRevealSupported")
        engine.perform(NSSelectorFromString("fpkStartTracking"))
        engine.setValue(true, forKey: "fpkForcing")
        engine.setValue(NSApp.presentationOptions.rawValue, forKey: "fpkPresentationBeforeForcing")
        engine.setValue(true, forKey: "fpkPresentationBeforeForcingValid")
    }

    // The test that fails against the vulnerable pattern: with an unretained
    // window reference (OmacVM before #414), the engine's teardown under the
    // window's -dealloc messages the half-freed window.
    func testSessionTeardownNeverMessagesADeallocatingWindow() throws {
        var session: FullPanelSession?
        weak var weakWindow: ProbeWindow?
        let before = NSApp.presentationOptions
        try autoreleasepool {
            let w = make(ProbeWindow.self)
            weakWindow = w
            session = try FullPanelSession.attach(to: w)
            session?.isEnabled = true
            armTeardownThatTouchesTheWindow(try XCTUnwrap(session?.value(forKey: "engine") as? NSObject))
        }
        XCTAssertNil(weakWindow)
        XCTAssertEqual(LifetimeProbe.touchedAfterDealloc, [],
                       "FullPanel state must not message a window that is being freed")
        XCTAssertEqual(session?.isAttached, false)
        XCTAssertEqual(session?.diagnostics()["revealActive"] as? Bool, false)
        XCTAssertEqual(NSApp.presentationOptions, before)
        session = nil
    }

    func testFullPanelWindowTeardownNeverMessagesItselfWhileDeallocating() throws {
        weak var weakWindow: ProbeFullPanelWindow?
        autoreleasepool {
            let w = make(ProbeFullPanelWindow.self)
            weakWindow = w
            w.fullPanelEnabled = true
            if let engine = w.value(forKey: "fpkEngine") as? NSObject {
                armTeardownThatTouchesTheWindow(engine)
            }
        }
        XCTAssertNil(weakWindow)
        XCTAssertEqual(LifetimeProbe.touchedAfterDealloc, [])
    }

    // Detached during fullscreen: the style is restored by one-shot observers
    // after the exit. A window freed without exiting or closing must not leave
    // them (and the engine they hold) registered for an address another window
    // may reuse.
    func testStyleRestoreAfterDetachInFullScreenEndsWithTheWindow() throws {
        weak var weakEngine: NSObject?
        weak var weakWindow: ProbeWindow?
        try autoreleasepool {
            let w = make(ProbeWindow.self)
            weakWindow = w
            w.fakeFullScreen = true   // enabled "inside fullscreen": style sync pending
            let session = try FullPanelSession.attach(to: w)
            session.isEnabled = true
            let engine = try XCTUnwrap(session.value(forKey: "engine") as? NSObject)
            weakEngine = engine
            XCTAssertEqual(engine.value(forKey: "styleSyncPending") as? Bool, true)
            session.detach()   // installs the post-exit style restore
        }
        XCTAssertNil(weakWindow)
        XCTAssertNil(weakEngine, "the post-exit style restore must end when its window is freed")
    }

    func testStyleRestoreAfterDetachStillRunsAtExit() throws {
        let w = make(ProbeWindow.self)
        w.fakeFullScreen = true
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        session.detach()
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView), "never applied inside fullscreen")
        w.fakeFullScreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: w)
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView))
        // A second exit notification finds nothing registered.
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: w)
    }

    // A session the application keeps after its window is gone stays inert:
    // late application and Space notifications, restore and diagnostics do
    // nothing and never reach a window.
    func testSessionOutlivingWindowIgnoresLateNotifications() throws {
        var session: FullPanelSession?
        try autoreleasepool {
            let w = make(ProbeWindow.self)
            session = try FullPanelSession.attach(to: w)
            session?.isEnabled = true
        }
        let before = NSApp.presentationOptions
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                   object: NSWorkspace.shared)
        session?.restoreSystemState()
        XCTAssertEqual(session?.diagnostics()["lifecycleObservers"] as? Int, 0)
        XCTAssertEqual(session?.diagnostics()["returnCheckPending"] as? Bool, false)
        XCTAssertEqual(NSApp.presentationOptions, before)
        XCTAssertEqual(LifetimeProbe.touchedAfterDealloc, [])
        session = nil
    }
}
