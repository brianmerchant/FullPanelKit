// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Entry preparation at willEnterFullScreen for every entry path (toggle,
// state restoration, other AppKit paths), at the reservation request for an
// entry the engine was not told about, and attachment inside an entry that
// already began.
// No window here is shown or enters fullscreen: the entry's notification is
// delivered directly, and the in-fullscreen cases are the pure decisions the
// engine calls (AppKit refuses the fullscreen style bit outside a transition). The
// hardware behavior (pixels, Spaces, Mission Control) is verified with
// FullPanelAttachDemo -FullPanelAttachScenario (docs/ATTACHMENT.md).

import AppKit
import XCTest
@testable import FullPanelKit
import FullPanelKitCore.Decisions   // test-only decision SPI

private final class EntryHostWindow: NSWindow {}
/// Overrides -toggleFullScreen: without calling super, so no fullscreen
/// transition starts.
private final class EntryToggleWindow: NSWindow {
    var toggles = 0
    override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
}

@MainActor
final class EntryPreparationTests: XCTestCase {
    private func make<W: NSWindow>() -> W {
        _ = NSApplication.shared
        let w = W(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                  styleMask: [.titled, .closable, .resizable],
                  backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    private func preparedBy(_ s: FullPanelSession) -> String? { s.diagnostics()["entryPreparedBy"] as? String }
    private func adoption(_ s: FullPanelSession) -> String { (s.diagnostics()["adoption"] as? String) ?? "" }

    /// Through Objective-C dispatch, as AppKit's menu item and button do.
    private func toggle(_ w: NSWindow) {
        _ = w.perform(#selector(NSWindow.toggleFullScreen(_:)), with: nil)
    }

    private func postWillEnter(_ w: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: w)
    }

    // ---- Attaching before entry -------------------------------------------------------

    func testEntryWithoutToggleIsPreparedAtWillEnter() throws {
        let w: EntryHostWindow = make()
        let s = try FullPanelSession.attach(to: w)
        s.isEnabled = true
        XCTAssertEqual(preparedBy(s), "")
        postWillEnter(w)   // e.g. AppKit state restoration: no -toggleFullScreen:
        XCTAssertEqual(preparedBy(s), "willEnterFullScreen")
        s.detach()
    }

    // -toggleFullScreen: is not wrapped; the entry it starts
    // is prepared at its willEnterFullScreen like every other entry.
    func testToggleIsNotHookedAndItsEntryIsPreparedAtWillEnter() throws {
        let w: EntryToggleWindow = make()
        let s = try FullPanelSession.attach(to: w)
        s.isEnabled = true
        toggle(w)
        XCTAssertEqual(w.toggles, 1)
        XCTAssertEqual(preparedBy(s), "", "nothing is prepared before AppKit's own notification")
        postWillEnter(w)
        XCTAssertEqual(preparedBy(s), "willEnterFullScreen")
        s.detach()
    }

    func testEnablingBeforeWillEnterPreparesTheEntry() throws {
        let w: EntryToggleWindow = make()
        let s = try FullPanelSession.attach(to: w)
        toggle(w)                        // disabled at the toggle
        s.isEnabled = true
        postWillEnter(w)
        XCTAssertEqual(preparedBy(s), "willEnterFullScreen")
        s.detach()
    }

    func testFullPanelWindowEntryWithoutToggleIsPrepared() {
        _ = NSApplication.shared
        let w = FullPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.fullPanelEnabled = true
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: w)
        XCTAssertEqual(w.fullPanelDiagnostics()["entryPreparedBy"] as? String, "willEnterFullScreen")
        w.fullPanelEnabled = false
    }

    func testRepeatedAttachKeepsEntryPreparation() throws {
        let w: EntryHostWindow = make()
        let s = try FullPanelSession.attach(to: w)
        s.isEnabled = true
        postWillEnter(w)
        XCTAssertTrue(try FullPanelSession.attach(to: w) === s)
        XCTAssertEqual(preparedBy(s), "willEnterFullScreen")
        s.detach()
    }

    // ---- Decisions for entries already under way -------------------------------------
    //
    // AppKit refuses NSWindowStyleMaskFullScreen outside a real transition, so the
    // in-fullscreen paths are the pure decisions the engine calls, plus the
    // hardware scenarios (restoreCheck with -FullPanelAttachOnWillEnter,
    // -FullPanelAttachDelayMs; SpacesLab -attachAt willEnter, P2).

    func testReservationRequestPreparesOnlyAnEntryThatBeganAfterWindowedEnable() {
        // Attached inside the entry's own willEnterFullScreen: the request prepares.
        XCTAssertTrue(FPKReservationRequestPreparesEntry(true, true, false, true))
        // Already prepared (willEnter, or this path earlier).
        XCTAssertFalse(FPKReservationRequestPreparesEntry(true, true, true, true))
        // Enabled inside fullscreen, during an exit, or after disable: never.
        XCTAssertFalse(FPKReservationRequestPreparesEntry(false, true, false, true))
        XCTAssertFalse(FPKReservationRequestPreparesEntry(true, false, false, true))
        // Windowed: AppKit's first question of an entry, before the style mask
        // has FullScreen (measured), does not prepare.
        XCTAssertFalse(FPKReservationRequestPreparesEntry(true, true, false, false))
    }

    func testEnableInsideFullScreenIsAnEntryAlreadyUnderway() {
        XCTAssertTrue(FPKEntryAlreadyUnderway(true, false))     // attached after entry: fallback
        XCTAssertFalse(FPKEntryAlreadyUnderway(true, true))     // this entry is ours
        XCTAssertFalse(FPKEntryAlreadyUnderway(false, false))   // windowed: next entry is ours
    }

    func testEnablingWindowedThenDisablingNeverPreparesAnEntry() throws {
        let w: EntryHostWindow = make()
        let s = try FullPanelSession.attach(to: w)
        s.isEnabled = true
        s.isEnabled = false
        XCTAssertEqual(preparedBy(s), "")
        XCTAssertEqual(adoption(s), "")
        XCTAssertEqual(s.state, .disabled)
        s.detach()
    }

    // ---- Detach / re-attach ----------------------------------------------------------

    func testReattachStartsWithoutEntryState() throws {
        let w: EntryHostWindow = make()
        let s = try FullPanelSession.attach(to: w)
        s.isEnabled = true
        postWillEnter(w)
        s.detach()
        let s2 = try FullPanelSession.attach(to: w)
        XCTAssertFalse(s2 === s)
        XCTAssertEqual(preparedBy(s2), "")
        XCTAssertEqual(adoption(s2), "")
        s2.isEnabled = true
        postWillEnter(w)
        XCTAssertEqual(preparedBy(s2), "willEnterFullScreen")
        s2.detach()
    }
}
