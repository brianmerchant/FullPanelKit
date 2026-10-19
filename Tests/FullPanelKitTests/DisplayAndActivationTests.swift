// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Display migration and activation. Moving a fullscreen Space to a display
// without a camera housing (and back) and Dock / Command-Tab activation are
// hardware checks (docs/WINDOW_LIFECYCLE.md). These tests cover the decisions
// and the engine's response with the window reporting fullscreen itself
// (`ProbeWindow.fakeFullScreen`); nothing enters fullscreen.

import AppKit
import XCTest
@testable import FullPanelKit
import FullPanelKitCore.Decisions   // test-only decision SPI

@MainActor
final class DisplayAndActivationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func make<W: NSWindow>(_ type: W.Type) -> W {
        let w = W(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    // ---- Decisions ------------------------------------------------------------------

    func testScreenReleaseAndResumeDecisions() {
        // Armed fullscreen Space on a display without a housing: release once.
        XCTAssertTrue(FPKScreenReleasesSession(true, true, false, false))
        XCTAssertFalse(FPKScreenReleasesSession(true, true, false, true), "already released")
        XCTAssertFalse(FPKScreenReleasesSession(true, true, true, false), "beside the housing")
        XCTAssertFalse(FPKScreenReleasesSession(false, true, false, false), "ordinary fullscreen")
        XCTAssertFalse(FPKScreenReleasesSession(true, false, false, false), "windowed")
        // Back beside a housing in the same fullscreen session.
        XCTAssertTrue(FPKScreenResumesSession(true, true, true))
        XCTAssertFalse(FPKScreenResumesSession(true, true, false))
        XCTAssertFalse(FPKScreenResumesSession(false, true, true))
        XCTAssertFalse(FPKScreenResumesSession(true, false, true), "the exit resets instead")
    }

    func testFallbackReasonInFullScreen() {
        XCTAssertEqual(FPKFullScreenFallbackReason(.menuBarAlwaysShown, false), .menuBarAlwaysShown)
        XCTAssertEqual(FPKFullScreenFallbackReason(.none, false), .noCameraHousing)
        XCTAssertEqual(FPKFullScreenFallbackReason(.none, true), .frameNotAccepted)
    }

    // ---- Engine: fullscreen Space moved to a display without a housing --------------

    /// A connected display without a camera housing (an external display).
    private func screenWithoutHousing() throws -> NSScreen {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top <= 0 }) else {
            throw XCTSkip("needs a display without a camera housing (external or Sidecar)")
        }
        return s
    }

    private func armedFullScreenSession() throws -> (ProbeWindow, FullPanelSession, NSObject) {
        let w = make(ProbeWindow.self)
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        let engine = try XCTUnwrap(session.value(forKey: "engine") as? NSObject)
        // As after an accepted FullPanel entry and its menu-bar commit, without
        // changing anything outside the process.
        w.fakeFullScreen = true
        for key in ["fpArmed", "fpAccepted", "fpEnteringOrInside", "fpkRevealSupported", "fpkTracking"] {
            engine.setValue(true, forKey: key)
        }
        return (w, session, engine)
    }

    func testSpaceOnDisplayWithoutHousingReleasesSystemStateAndReportsFallback() throws {
        let external = try screenWithoutHousing()
        let (w, session, _) = try armedFullScreenSession()
        let before = NSApp.presentationOptions
        w.fakeScreen = .some(external)   // the Space moved to the external display
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: w)
        let d = session.diagnostics()
        XCTAssertEqual(d["screenReleased"] as? Bool, true)
        XCTAssertEqual(d["revealActive"] as? Bool, false, "reveal monitor and KVO removed")
        XCTAssertEqual(d["revealIntegration"] as? Bool, true, "latched for the rest of the session")
        XCTAssertEqual(d["armed"] as? Bool, true, "the entry stays armed for a move back")
        XCTAssertEqual(session.state, .fallback)
        XCTAssertEqual(session.fallbackReason, .noCameraHousing)
        XCTAssertEqual(NSApp.presentationOptions, before)

        // Key / active / Space signals there must not start a menu-bar commit.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(session.diagnostics()["returnCheckPending"] as? Bool, false)
        XCTAssertEqual(session.diagnostics()["menuBarOverrideSubmitted"] as? Bool, false)

        w.fakeFullScreen = false
        session.detach()
    }

    func testSpaceBackBesideHousingResumes() throws {
        guard let housing = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            throw XCTSkip("needs a display with a camera housing")
        }
        let external = try screenWithoutHousing()
        let (w, session, _) = try armedFullScreenSession()
        w.fakeScreen = .some(external)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: w)
        XCTAssertEqual(session.diagnostics()["screenReleased"] as? Bool, true)
        w.fakeScreen = .some(housing)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: w)
        let d = session.diagnostics()
        XCTAssertEqual(d["screenReleased"] as? Bool, false)
        XCTAssertEqual(d["armed"] as? Bool, true)
        XCTAssertEqual(d["screenHasCameraHousing"] as? Bool, true)
        // The commit itself needs the window key on the active Space (hardware);
        // here the return check is at most scheduled, never a frame change.
        XCTAssertEqual(w.frame, NSRect(x: 100, y: 100, width: 640, height: 400))
        w.fakeFullScreen = false
        session.detach()
    }

    func testExitClearsScreenRelease() throws {
        let external = try screenWithoutHousing()
        let (w, session, _) = try armedFullScreenSession()
        w.fakeScreen = .some(external)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: w)
        XCTAssertEqual(session.diagnostics()["screenReleased"] as? Bool, true)
        session.restoreSystemState()   // the exit-reset path
        XCTAssertEqual(session.diagnostics()["screenReleased"] as? Bool, false)
        XCTAssertEqual(session.diagnostics()["armed"] as? Bool, false)
        w.fakeFullScreen = false
        session.detach()
    }

    func testDisplayParameterChangeReevaluatesTheScreen() throws {
        let external = try screenWithoutHousing()
        let (w, session, _) = try armedFullScreenSession()
        w.fakeScreen = .some(external)   // e.g. macOS moved the Space when a display went away
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        XCTAssertEqual(session.diagnostics()["screenReleased"] as? Bool, true)
        w.fakeFullScreen = false
        session.detach()
    }

    // During a display reconfiguration a window can briefly have no screen:
    // that is not a move to a display without a housing.
    func testNoScreenDuringReconfigurationReleasesNothing() throws {
        let (w, session, _) = try armedFullScreenSession()
        w.fakeScreen = .some(nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: w)
        let d = session.diagnostics()
        XCTAssertEqual(d["screenReleased"] as? Bool, false)
        XCTAssertEqual(d["revealActive"] as? Bool, true)
        XCTAssertNotEqual(session.fallbackReason, .noCameraHousing)
        w.fakeFullScreen = false
        session.detach()
    }

    // ---- Activation: FullPanel leaves AppKit's Space and key attributes alone -----------

    private struct Attributes: Equatable {
        let canBecomeKey, canBecomeMain, hidesOnDeactivate, excludedFromWindowsMenu, canHide: Bool
        let level: NSWindow.Level
        @MainActor init(_ w: NSWindow) {
            canBecomeKey = w.canBecomeKey
            canBecomeMain = w.canBecomeMain
            hidesOnDeactivate = w.hidesOnDeactivate
            excludedFromWindowsMenu = w.isExcludedFromWindowsMenu
            canHide = w.canHide
            level = w.level
        }
    }

    func testFullPanelKeepsNativeSpaceAndActivationAttributes() throws {
        // Collection behaviors that would detach a window from its own Space or
        // from Command-Tab / Dock window cycling.
        let foreign: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace, .transient,
                                                    .stationary, .ignoresCycle, .fullScreenAuxiliary,
                                                    .fullScreenNone]
        let fp = make(FullPanelWindow.self)
        let attachedWindow = make(ProbeWindow.self)
        let session = try FullPanelSession.attach(to: attachedWindow)
        let hosts: [(String, NSWindow, (Bool) -> Void)] = [
            ("FullPanelWindow", fp, { fp.fullPanelEnabled = $0 }),
            ("FullPanelSession", attachedWindow, { session.isEnabled = $0 }),
        ]
        for (name, w, setEnabled) in hosts {
            w.collectionBehavior = [.managed, .participatesInCycle]
            let behavior = w.collectionBehavior
            let attributes = Attributes(w)
            setEnabled(true)
            XCTAssertEqual(w.collectionBehavior, behavior.union(.fullScreenPrimary), name)
            XCTAssertTrue(w.collectionBehavior.intersection(foreign).isEmpty, name)
            XCTAssertEqual(Attributes(w), attributes, name)
            setEnabled(false)
            XCTAssertEqual(w.collectionBehavior, behavior, name)
            XCTAssertEqual(Attributes(w), attributes, name)
        }
        session.detach()
    }

    func testDiagnosticsReportActivationInputs() throws {
        let w = make(FullPanelWindow.self)
        w.fullPanelEnabled = true
        let d = w.fullPanelDiagnostics()
        let raw = UserDefaults.standard.object(forKey: "AppleSpacesSwitchOnActivate")
        XCTAssertEqual(d["spacesSwitchOnActivate"] as? Bool, (raw as? Bool) ?? true)
        for key in ["windowNumber", "collectionBehaviorRaw", "isKeyWindow", "isMainWindow", "isVisible", "appActive"] {
            XCTAssertNotNil(d[key], key)
        }
    }

    // ---- Detach during fullscreen, twice ----------------------------------------------

    func testSecondDetachInFullScreenKeepsTheFirstStyleRestore() throws {
        let w = make(ProbeWindow.self)
        let first = try FullPanelSession.attach(to: w)
        first.isEnabled = true                     // windowed: style applied now
        XCTAssertTrue(w.styleMask.contains(.fullSizeContentView))
        w.fakeFullScreen = true
        first.detach()                             // style restore waits for the exit
        let second = try FullPanelSession.attach(to: w)
        second.isEnabled = true                    // in fullscreen: style pending
        second.detach()
        w.fakeFullScreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: w)
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView),
                       "the first detach's style restore still runs at the exit")
    }
}
