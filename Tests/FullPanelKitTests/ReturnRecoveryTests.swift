// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Mission Control return recovery (presentation re-assert, 40f579a) through
// both hosts of the shared engine: FullPanelWindow and FullPanelSession.
// These never enter fullscreen. The re-assert decision is covered in
// DecisionTests; the actual Mission Control return is a hardware test
// (docs/HARDWARE_BASELINE.md).

import AppKit
import XCTest
@testable import FullPanelKit

private final class SessionHostWindow: NSWindow {}

@MainActor
final class ReturnRecoveryTests: XCTestCase {
    /// One engine host under test, with the window it drives.
    private struct Host {
        let window: NSWindow
        let engine: NSObject
        let diagnostics: () -> [String: Any]
        let restore: () -> Void
        let cleanup: () -> Void
    }

    private func makeWindow<W: NSWindow>(_ type: W.Type) -> W {
        _ = NSApplication.shared
        let w = W(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                  styleMask: [.titled, .closable, .resizable],
                  backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    // The engine is internal (FPKEngine.h): reached through its owner's ivar.
    private func fullPanelWindowHost() throws -> Host {
        let w = makeWindow(FullPanelWindow.self)
        w.fullPanelEnabled = true
        let engine = try XCTUnwrap(w.value(forKey: "fpkEngine") as? NSObject)
        return Host(window: w, engine: engine,
                    diagnostics: { w.fullPanelDiagnostics() },
                    restore: { w.fullPanelRestoreSystemState() },
                    cleanup: { w.fullPanelEnabled = false })
    }

    private func sessionHost() throws -> Host {
        let w = makeWindow(SessionHostWindow.self)
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        let engine = try XCTUnwrap(session.value(forKey: "engine") as? NSObject)
        return Host(window: w, engine: engine,
                    diagnostics: { session.diagnostics() },
                    restore: { session.restoreSystemState() },
                    cleanup: { session.detach() })
    }

    private func hosts() throws -> [(String, Host)] {
        [("FullPanelWindow", try fullPanelWindowHost()), ("FullPanelSession", try sessionHost())]
    }

    private func flag(_ host: Host, _ key: String) -> Bool? {
        host.diagnostics()[key] as? Bool
    }

    /// Runs the main queue until the re-assert's two follow-up turns have run.
    private func drainMainQueue() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                DispatchQueue.main.async { done.fulfill() }
            }
        }
        wait(for: [done], timeout: 2)
    }

    private func scheduleReassert(_ host: Host) {
        host.engine.perform(NSSelectorFromString("fpReassertPresentationAfterReturn"))
    }

    func testReturnStateIsReportedAndIdleByDefault() throws {
        for (name, host) in try hosts() {
            XCTAssertEqual(flag(host, "returnCheckPending"), false, name)
            XCTAssertEqual(flag(host, "returnFromAway"), false, name)
            XCTAssertEqual(flag(host, "presentationReassertScheduled"), false, name)
            host.cleanup()
        }
    }

    func testReassertIsBoundedAndInertWithoutActiveReveal() throws {
        for (name, host) in try hosts() {
            let before = NSApp?.presentationOptions
            scheduleReassert(host)
            XCTAssertEqual(flag(host, "presentationReassertScheduled"), true, name)
            // No reveal integration active: the release step has nothing to restore.
            XCTAssertEqual(NSApp?.presentationOptions, before, name)
            drainMainQueue()
            // Clears itself; never re-forced, never committed an alpha.
            XCTAssertEqual(flag(host, "presentationReassertScheduled"), false, name)
            XCTAssertEqual(NSApp?.presentationOptions, before, name)
            XCTAssertEqual(flag(host, "menuBarOverrideSubmitted"), false, name)
            host.cleanup()
        }
    }

    func testRestoreCancelsInFlightReassert() throws {
        for (name, host) in try hosts() {
            let before = NSApp?.presentationOptions
            scheduleReassert(host)
            host.restore()   // the exit-reset path (fullscreen exit, disable, close)
            XCTAssertEqual(flag(host, "presentationReassertScheduled"), false, name)
            XCTAssertEqual(flag(host, "returnFromAway"), false, name)
            drainMainQueue()
            XCTAssertEqual(flag(host, "presentationReassertScheduled"), false, name)
            XCTAssertEqual(NSApp?.presentationOptions, before, name)
            host.cleanup()
        }
    }

    func testCloseAndDetachCancelInFlightReassert() throws {
        let fp = try fullPanelWindowHost()
        scheduleReassert(fp)
        fp.window.close()
        XCTAssertEqual(flag(fp, "presentationReassertScheduled"), false)

        let w = makeWindow(SessionHostWindow.self)
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        let engine = try XCTUnwrap(session.value(forKey: "engine") as? NSObject)
        engine.perform(NSSelectorFromString("fpReassertPresentationAfterReturn"))
        session.detach()
        XCTAssertEqual(session.diagnostics()["presentationReassertScheduled"] as? Bool, false)

        let before = NSApp?.presentationOptions
        drainMainQueue()
        XCTAssertEqual(NSApp?.presentationOptions, before)
    }

    func testReassertOutlivingItsWindowIsHarmless() throws {
        let before = NSApp?.presentationOptions
        var session: FullPanelSession?
        weak var weakWindow: SessionHostWindow?
        try autoreleasepool {
            let w = makeWindow(SessionHostWindow.self)
            weakWindow = w
            session = try FullPanelSession.attach(to: w)
            session?.isEnabled = true
            let engine = try XCTUnwrap(session?.value(forKey: "engine") as? NSObject)
            engine.perform(NSSelectorFromString("fpReassertPresentationAfterReturn"))
        }
        XCTAssertNil(weakWindow)
        drainMainQueue()
        XCTAssertEqual(NSApp?.presentationOptions, before)
        XCTAssertEqual(session?.diagnostics()["presentationReassertScheduled"] as? Bool, false)
        session = nil
    }
}
