// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// The menu-bar reservation hook is FullPanelKit's only whole-display
// mechanism; it is installed at the first enable. Without it an entry is
// ordinary fullscreen. These tests prepare an entry by posting
// willEnterFullScreen; nothing enters fullscreen, and options are set in the
// volatile argument domain only. Entry verification (P1) and preparation at
// the reservation request (P2) need a real fullscreen entry: their decisions
// are tested here, the behaviour on hardware (docs/TESTING.md).

import AppKit
import ObjectiveC
import XCTest
@testable import FullPanelKit
import FullPanelKitCore.Decisions   // test-only decision SPI

@MainActor
final class ReservationHookTests: XCTestCase {
    private let controller: AnyClass? = NSClassFromString("_NSFullScreenContentController")
    private let selector = NSSelectorFromString("reservesSpaceForMenuBarInFullScreen")

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func appKitIMP() throws -> IMP {
        let cls: AnyClass = try XCTUnwrap(controller, "AppKit's fullscreen content controller class")
        return try XCTUnwrap(class_getInstanceMethod(cls, selector).map(method_getImplementation))
    }

    private func withOptions(_ options: [String: Any], _ body: () throws -> Void) rethrows {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let saved = arguments
        for (k, v) in options { arguments[k] = v }
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        try body()
    }

    private func prepareEntry() throws -> (ProbeWindow, FullPanelSession) {
        let w = ProbeWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        guard let screen = w.screen, screen.safeAreaInsets.top > 0 else {
            throw XCTSkip("needs the window on a display with a camera housing")
        }
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: w)
        return (w, session)
    }

    private func finish(_ w: ProbeWindow, _ session: FullPanelSession) {
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: w)
        session.detach()
    }

    private func geometry(_ s: FullPanelSession) -> String? { s.diagnostics()["geometry"] as? String }

    func testDefaultEntryUsesReservationGeometry() throws {
        try XCTSkipUnless(FullPanelSession.systemSupportAvailable(), "private methods unavailable")
        let (w, session) = try prepareEntry()
        let d = session.diagnostics()
        XCTAssertEqual(d["armed"] as? Bool, true)
        XCTAssertEqual(geometry(session), "reservation")
        XCTAssertEqual(d["reservationHookInstalled"] as? Bool, true)
        XCTAssertEqual(d["frameAccepted"] as? Bool, false, "accepted only once verified in fullscreen (P1)")
        finish(w, session)
        XCTAssertEqual(geometry(session), "none", "the latch ends with the entry")
    }

    func testHookIsInstalledAtEnableAndOnlyOnce() throws {
        try XCTSkipUnless(FullPanelSession.systemSupportAvailable(), "private methods unavailable")
        let w = ProbeWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true   // before any entry: in place for an entry that begins now (P2)
        XCTAssertEqual(session.diagnostics()["reservationHookInstalled"] as? Bool, true)
        let installed = try appKitIMP()
        session.detach()
        let (w2, session2) = try prepareEntry()
        XCTAssertEqual(try appKitIMP(), installed, "installed once per process")
        finish(w2, session2)
    }

    // The experiment's former geometry switches select nothing any more:
    // there is no other whole-display mechanism.
    func testRemovedGeometryOptionsHaveNoEffect() throws {
        try XCTSkipUnless(FullPanelSession.systemSupportAvailable(), "private methods unavailable")
        for options in [
            ["FullPanelGeometry": "legacy"], ["FullPanelGeometry": "hybrid"],
            ["FullPanelReservationHook": false], ["FullPanelReservationHook": true],
        ] as [[String: Any]] {
            try withOptions(options) {
                let (w, session) = try prepareEntry()
                XCTAssertEqual(geometry(session), "reservation", "\(options)")
                XCTAssertEqual(session.diagnostics()["armed"] as? Bool, true, "\(options)")
                finish(w, session)
            }
        }
    }

    // Without the reservation methods an entry is ordinary fullscreen; there
    // is no fallback to another geometry.
    func testWithoutReservationTheEntryIsOrdinaryFullScreen() throws {
        try withOptions(["FullPanelSimulateNoReservation": true]) {
            XCTAssertEqual(FullPanelSession.systemSupportAvailable(), false)
            let (w, session) = try prepareEntry()
            let d = session.diagnostics()
            XCTAssertEqual(d["armed"] as? Bool, false)
            XCTAssertEqual(geometry(session), "none")
            XCTAssertEqual(d["lastError"] as? String,
                           FullPanelFallbackReason.appKitUnavailable.summary)
            finish(w, session)
        }
    }

    // Gate 1: code that replaces the method after FullPanelKit makes later
    // entries ordinary fullscreen; FullPanelKit never puts AppKit's back.
    // The test restores FullPanelKit's own replacement afterwards.
    func testReplacementByOtherCodeAfterInstallationFallsBack() throws {
        try XCTSkipUnless(FullPanelSession.systemSupportAvailable(), "private methods unavailable")
        let (w0, s0) = try prepareEntry()   // installs the hook
        finish(w0, s0)
        let cls: AnyClass = try XCTUnwrap(controller)
        let method = try XCTUnwrap(class_getInstanceMethod(cls, selector))
        let ours = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        method_setImplementation(method, imp_implementationWithBlock(block))
        defer { method_setImplementation(method, ours) }
        XCTAssertEqual(FullPanelSession.systemSupportAvailable(), false)
        let (w, session) = try prepareEntry()
        let d = session.diagnostics()
        XCTAssertEqual(d["armed"] as? Bool, false)
        XCTAssertEqual(d["reservationHookInstalled"] as? Bool, false)
        XCTAssertEqual(geometry(session), "none")
        XCTAssertEqual(d["lastError"] as? String, FullPanelFallbackReason.appKitUnavailable.summary)
        finish(w, session)
        method_setImplementation(method, ours)
        XCTAssertEqual(FullPanelSession.systemSupportAvailable(), true, "usable again with ours in place")
    }

    // The hook replaces exactly one method of the process: AppKit's content
    // controller's reservation answer. No window class gains or changes one.
    func testHookChangesOnlyTheContentControllerMethod() throws {
        try XCTSkipUnless(FullPanelSession.systemSupportAvailable(), "private methods unavailable")
        let cls: AnyClass = try XCTUnwrap(controller)
        let windows = methodSnapshot(ProbeWindow.self, to: NSObject.self)
        let fullPanelWindow = methodSnapshot(FullPanelWindow.self, to: NSWindow.self)
        let controllerOthers = ownMethods(cls).filter { $0.key != "reservesSpaceForMenuBarInFullScreen" }
        let (w, session) = try prepareEntry()
        XCTAssertEqual(session.diagnostics()["reservationHookInstalled"] as? Bool, true)
        XCTAssertEqual(methodSnapshot(ProbeWindow.self, to: NSObject.self), windows)
        XCTAssertEqual(methodSnapshot(FullPanelWindow.self, to: NSWindow.self), fullPanelWindow)
        XCTAssertEqual(ownMethods(cls).filter { $0.key != "reservesSpaceForMenuBarInFullScreen" },
                       controllerOthers)
        XCTAssertNotNil(imp_getBlock(try appKitIMP()), "the reservation method runs FullPanelKit's block")
        finish(w, session)
    }
}

final class GeometryDecisionTests: XCTestCase {
    func testNoGeometryIsAppKitUnavailable() {
        let caps = FPKCapabilities(band: true, geometry: false, menuBarOverlay: true, menuBarPinned: false)
        XCTAssertEqual(FPKFallbackForCapabilities(caps), .appKitUnavailable)
    }

    // Gate 1: when the hook may be installed or relied on.
    func testReservationHookCheck() {
        XCTAssertEqual(FPKReservationHookCheck(true, true, true, false, false), .usable, "AppKit's own, not installed")
        XCTAssertEqual(FPKReservationHookCheck(true, true, false, true, true), .usable, "installed, still ours")
        XCTAssertEqual(FPKReservationHookCheck(false, true, true, false, false), .missing)
        XCTAssertEqual(FPKReservationHookCheck(true, false, true, false, false), .inherited,
                       "never replace a superclass's method")
        XCTAssertEqual(FPKReservationHookCheck(true, true, false, false, false), .intercepted,
                       "another library's implementation: not installed")
        XCTAssertEqual(FPKReservationHookCheck(true, true, false, true, false), .replaced,
                       "replaced after installation")
    }

    // P1: accepted when the fullscreen window covers its display beside the
    // housing; rejected only at didEnterFullScreen.
    func testEntryVerification() {
        XCTAssertEqual(FPKVerifyReservationEntry(true, true, true, true, true), .accepted)
        XCTAssertEqual(FPKVerifyReservationEntry(true, true, true, true, false), .accepted)
        XCTAssertEqual(FPKVerifyReservationEntry(true, true, false, true, true), .rejected, "e.g. Split View")
        XCTAssertEqual(FPKVerifyReservationEntry(true, true, true, false, true), .rejected, "no housing")
        XCTAssertEqual(FPKVerifyReservationEntry(true, true, false, true, false), .pending,
                       "a later event never rejects")
        XCTAssertEqual(FPKVerifyReservationEntry(false, true, true, true, true), .pending, "not armed")
        XCTAssertEqual(FPKVerifyReservationEntry(true, false, true, true, true), .pending, "not in fullscreen")
    }
}
