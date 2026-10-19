// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// FullPanelSession tests that do not need a notched display and never enter
// fullscreen. Fullscreen attachment is verified with FullPanelAttachDemo on
// hardware (docs/ATTACHMENT.md).
//
// Attaching must not modify any window class: these tests compare the
// Objective-C method tables of the window's class and every superclass up to
// NSWindow before and after attach, enable, entry preparation and detach
// (ClassMutation.swift).

import AppKit
import ObjectiveC
import XCTest
@testable import FullPanelKit

/// Stand-in for an application- or framework-defined window class such as
/// SwiftUI.AppKitWindow (not an AppKit class).
class HostWindow: NSWindow {}
/// A subclass of a class whose windows may also be attached.
final class HostSubWindow: HostWindow {}
/// A class that overrides frame setters and -toggleFullScreen: itself.
final class OverridingWindow: NSWindow {
    var setFrameCalls = 0
    var toggleCalls = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        setFrameCalls += 1
        super.setFrame(frameRect, display: flag)
    }
    override func toggleFullScreen(_ sender: Any?) {
        toggleCalls += 1   // never calls super: the test must not enter fullscreen
    }
}

private final class KeepingDelegate: NSObject, NSWindowDelegate {}

@MainActor
final class SessionTests: XCTestCase {
    private func make<W: NSWindow>() -> W {
        _ = NSApplication.shared
        let w = W(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                  styleMask: [.titled, .closable, .resizable],
                  backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    // ---- Attachment and identity -----------------------------------------------

    func testAttachPreservesIdentityClassAndDelegate() throws {
        let w: HostWindow = make()
        let delegate = KeepingDelegate()
        w.delegate = delegate
        let runtimeClassBefore: AnyClass = object_getClass(w)!
        let session = try FullPanelSession.attach(to: w)
        XCTAssertTrue(session.window === w)
        XCTAssertTrue(object_getClass(w) === runtimeClassBefore, "isa must not change")
        XCTAssertTrue(w.isMember(of: HostWindow.self))
        XCTAssertTrue(w.delegate === delegate, "the delegate must not be replaced")
        session.isEnabled = true
        XCTAssertTrue(w.delegate === delegate)
        // The style change makes AppKit itself KVO-observe the window (plain
        // AppKit does the same), so the runtime class may become AppKit's
        // NSKVONotifying_ subclass. FullPanelKit never changes it.
        XCTAssertTrue(w.isMember(of: HostWindow.self))
        let runtime: AnyClass = object_getClass(w)!
        XCTAssertTrue(runtime === runtimeClassBefore || class_getSuperclass(runtime) === HostWindow.self)
        session.detach()
    }

    func testAttachToKVOObservedWindowKeepsItsDynamicClass() throws {
        let w: HostWindow = make()
        // Like SwiftUI: an existing KVO observation gives the instance a
        // dynamic NSKVONotifying_ subclass.
        let observation = w.observe(\.title) { _, _ in }
        let dynamicClass: AnyClass = object_getClass(w)!
        XCTAssertNotEqual(NSStringFromClass(dynamicClass), "HostWindow")
        let before = methodSnapshot(HostWindow.self)
        let session = try FullPanelSession.attach(to: w)
        XCTAssertNil(session.diagnostics()["hookClass"], "nothing is hooked, so nothing to report")
        XCTAssertTrue(object_getClass(w) === dynamicClass)
        session.isEnabled = true
        XCTAssertEqual(session.state, .inactive)
        XCTAssertTrue(object_getClass(w) === dynamicClass)
        XCTAssertEqual(methodSnapshot(HostWindow.self), before, "the real class is not modified either")
        observation.invalidate()
        session.detach()
    }

    func testAttachIsIdempotentWhileAttached() throws {
        let w: HostWindow = make()
        let a = try FullPanelSession.attach(to: w)
        let b = try FullPanelSession.attach(to: w)
        XCTAssertTrue(a === b)
        XCTAssertTrue(FullPanelSession.session(for: w) === a)
        a.detach()
        XCTAssertNil(FullPanelSession.session(for: w))
        let c = try FullPanelSession.attach(to: w)
        XCTAssertFalse(c === a, "a detached session is inert; attaching again makes a new one")
        XCTAssertFalse(a.isAttached)
        XCTAssertTrue(c.isAttached)
        c.detach()
    }

    func testRejectsFullPanelWindow() {
        let w = FullPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        XCTAssertThrowsError(try FullPanelSession.attach(to: w)) { error in
            XCTAssertEqual((error as NSError).domain, FullPanelSessionErrorDomain)
            XCTAssertEqual((error as NSError).code, FullPanelSessionError.Code.fullPanelWindow.rawValue)
        }
        XCTAssertNil(FullPanelSession.session(for: w))
    }

    func testRejectsAppKitClassesWithoutModifyingThem() {
        let nsWindowBefore = methodSnapshot(NSWindow.self)
        let nsPanelBefore = methodSnapshot(NSPanel.self)
        let plain: NSWindow = make()
        let panel: NSPanel = make()
        for w in [plain, panel] {
            XCTAssertThrowsError(try FullPanelSession.attach(to: w)) { error in
                XCTAssertEqual((error as NSError).code,
                               FullPanelSessionError.Code.unsupportedWindowClass.rawValue)
            }
            XCTAssertNil(FullPanelSession.session(for: w))
        }
        XCTAssertEqual(methodSnapshot(NSWindow.self), nsWindowBefore)
        XCTAssertEqual(methodSnapshot(NSPanel.self), nsPanelBefore)
    }

    // ---- No window class is modified ---------------------------------------------

    /// Attach, enable, prepare an entry (willEnterFullScreen), end it, disable
    /// and detach `w`, checking the method tables of its class chain after
    /// each step. Also installs the menu-bar reservation hook when this macOS
    /// has it (first enable), which must not touch a window class either.
    private func assertLifecycleLeavesClassUnchanged<W: NSWindow>(_ w: W, file: StaticString = #filePath,
                                                                   line: UInt = #line) throws {
        let cls: AnyClass = W.self
        let before = methodSnapshot(cls)
        let isaBefore: AnyClass = object_getClass(w)!
        func check(_ step: String) {
            XCTAssertEqual(methodSnapshot(cls), before, "\(cls) changed after \(step)", file: file, line: line)
            XCTAssertEqual(blockImplementations(cls), [], "block-based IMP after \(step)", file: file, line: line)
            XCTAssertTrue(w.isMember(of: cls), "class changed after \(step)", file: file, line: line)
        }
        let session = try FullPanelSession.attach(to: w)
        check("attach")
        XCTAssertTrue(object_getClass(w) === isaBefore, "attach must not change the isa", file: file, line: line)
        session.isEnabled = true
        check("enable")
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: w)
        check("entry preparation")
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: w)
        session.isEnabled = false
        check("disable")
        session.detach()
        check("detach")
        _ = FullPanelSession.systemSupportAvailable()
        check("capability check")
    }

    func testAttachingModifiesNoWindowClass() throws {
        try assertLifecycleLeavesClassUnchanged(make() as HostWindow)
        try assertLifecycleLeavesClassUnchanged(make() as HostSubWindow)
        try assertLifecycleLeavesClassUnchanged(make() as OverridingWindow)
        // And AppKit's own window classes, which every window inherits from.
        let nsWindow = methodSnapshot(NSWindow.self, to: NSObject.self)
        try assertLifecycleLeavesClassUnchanged(make() as HostWindow)
        XCTAssertEqual(methodSnapshot(NSWindow.self, to: NSObject.self), nsWindow)
    }

    func testAttachedClassesHaveNoBlockImplementations() throws {
        let a: HostWindow = make(), b: HostSubWindow = make(), c: OverridingWindow = make()
        let sessions = try [a, b, c].map { w -> FullPanelSession in
            let s = try FullPanelSession.attach(to: w)
            s.isEnabled = true
            return s
        }
        for cls: AnyClass in [HostWindow.self, HostSubWindow.self, OverridingWindow.self] {
            XCTAssertEqual(blockImplementations(cls), [], "\(cls)")
        }
        sessions.forEach { $0.detach() }
    }

    // ---- Isolation ------------------------------------------------------------------

    func testUnattachedWindowsOfAnAttachedClassBehaveNormally() throws {
        let attached: HostWindow = make()
        let other: HostWindow = make()
        let session = try FullPanelSession.attach(to: attached)
        session.isEnabled = true
        XCTAssertNil(FullPanelSession.session(for: other))
        XCTAssertFalse(other.styleMask.contains(.fullSizeContentView))

        // Frame setters reach AppKit unchanged.
        other.setFrame(NSRect(x: 10, y: 20, width: 500, height: 300), display: false)
        XCTAssertEqual(other.frame, NSRect(x: 10, y: 20, width: 500, height: 300))
        other.setFrameOrigin(NSPoint(x: 30, y: 40))
        XCTAssertEqual(other.frame.origin, NSPoint(x: 30, y: 40))
        other.setFrameTopLeftPoint(NSPoint(x: 50, y: 400))
        XCTAssertEqual(other.frame.origin, NSPoint(x: 50, y: 100))
        other.setContentSize(NSSize(width: 420, height: 260))
        XCTAssertEqual(other.contentRect(forFrameRect: other.frame).size, NSSize(width: 420, height: 260))
        other.setFrame(NSRect(x: 0, y: 0, width: 300, height: 200), display: false, animate: false)
        XCTAssertEqual(other.frame, NSRect(x: 0, y: 0, width: 300, height: 200))
        session.detach()
    }

    func testAttachedWindowFrameSettersReachAppKit() throws {
        let w: HostWindow = make()
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        w.setFrame(NSRect(x: 10, y: 20, width: 500, height: 300), display: false)
        XCTAssertEqual(w.frame, NSRect(x: 10, y: 20, width: 500, height: 300))
        w.setContentSize(NSSize(width: 410, height: 250))
        XCTAssertEqual(w.contentRect(forFrameRect: w.frame).size, NSSize(width: 410, height: 250))
        session.detach()
    }

    func testClassThatOverridesFrameSettersKeepsItsOverrides() throws {
        let w: OverridingWindow = make()
        let other: OverridingWindow = make()
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        w.setFrameCalls = 0   // the style change made AppKit call setFrame itself
        other.setFrameCalls = 0
        w.setFrame(NSRect(x: 0, y: 0, width: 333, height: 222), display: false)
        other.setFrame(NSRect(x: 0, y: 0, width: 334, height: 223), display: false)
        XCTAssertEqual(w.setFrameCalls, 1)
        XCTAssertEqual(other.setFrameCalls, 1)
        XCTAssertEqual(w.frame.size, NSSize(width: 333, height: 222))
        w.toggleFullScreen(nil)       // the override never calls super
        other.toggleFullScreen(nil)
        XCTAssertEqual(w.toggleCalls, 1)
        XCTAssertEqual(other.toggleCalls, 1)
        session.detach()
    }

    func testToggleFullScreenIsNeverHooked() throws {
        let before = class_getInstanceMethod(HostWindow.self, #selector(NSWindow.toggleFullScreen(_:)))
            .map(method_getImplementation)
        let w: HostWindow = make()
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        let after = class_getInstanceMethod(HostWindow.self, #selector(NSWindow.toggleFullScreen(_:)))
            .map(method_getImplementation)
        XCTAssertEqual(after, before)
        session.detach()
    }

    func testSubclassAndSuperclassWindowsAttachIndependently() throws {
        let base: HostWindow = make()
        let sub: HostSubWindow = make()
        let s1 = try FullPanelSession.attach(to: base)
        let s2 = try FullPanelSession.attach(to: sub)
        s1.isEnabled = true
        s2.isEnabled = true
        sub.setFrame(NSRect(x: 5, y: 6, width: 400, height: 300), display: false)
        XCTAssertEqual(sub.frame, NSRect(x: 5, y: 6, width: 400, height: 300))
        base.setFrameOrigin(NSPoint(x: 7, y: 8))
        XCTAssertEqual(base.frame.origin, NSPoint(x: 7, y: 8))
        XCTAssertEqual(s1.diagnostics()["windowClass"] as? String, NSStringFromClass(HostWindow.self))
        XCTAssertEqual(s2.diagnostics()["windowClass"] as? String, NSStringFromClass(HostSubWindow.self))
        s1.detach()
        s2.detach()
    }

    func testIndependentSessions() throws {
        let a: HostWindow = make(), b: HostWindow = make()
        let sa = try FullPanelSession.attach(to: a)
        let sb = try FullPanelSession.attach(to: b)
        sa.isEnabled = true
        XCTAssertEqual(sa.state, .inactive)
        XCTAssertEqual(sb.state, .disabled)
        XCTAssertTrue(a.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(b.styleMask.contains(.fullSizeContentView))
        sa.detach()
        sb.detach()
    }

    // ---- State and observation -------------------------------------------------

    func testEnableAppliesAndDisableRestoresStyle() throws {
        let w: HostWindow = make()
        let behavior = w.collectionBehavior
        let session = try FullPanelSession.attach(to: w)
        XCTAssertEqual(session.state, .disabled)
        XCTAssertFalse(session.isEnabled)
        session.isEnabled = true
        XCTAssertEqual(session.state, .inactive)
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(w.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(w.titlebarAppearsTransparent)
        XCTAssertTrue(w.collectionBehavior.contains(.fullScreenPrimary))
        session.isEnabled = false
        XCTAssertEqual(session.state, .disabled)
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(w.titlebarAppearsTransparent)
        XCTAssertEqual(w.collectionBehavior, behavior)
        session.detach()
    }

    func testDetachRestoresStyleAndDisables() throws {
        let w: HostWindow = make()
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        session.detach()
        XCTAssertFalse(session.isAttached)
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(session.state, .disabled)
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView))
        session.isEnabled = true   // ignored once detached
        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView))
        session.detach()           // idempotent
    }

    func testPreexistingStyleIsPreserved() throws {
        let w: HostWindow = make()
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        session.detach()
        XCTAssertTrue(w.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(w.titlebarAppearsTransparent)
    }

    func testStateChangeNotificationAndKVO() throws {
        let w: HostWindow = make()
        let session = try FullPanelSession.attach(to: w)
        let posted = expectation(forNotification: FullPanelSession.stateDidChangeNotification,
                                 object: session)
        var seen: [FullPanelState] = []
        var active: [Bool] = []
        let o1 = session.observe(\.state, options: [.new]) { s, _ in seen.append(s.state) }
        let o2 = session.observe(\.isActive, options: [.new]) { s, _ in active.append(s.isActive) }
        var attachedChanges = 0
        let o3 = session.observe(\.isAttached, options: [.new]) { _, _ in attachedChanges += 1 }
        session.isEnabled = true
        wait(for: [posted], timeout: 1)
        session.isEnabled = false
        session.detach()
        [o1, o2, o3].forEach { $0.invalidate() }
        XCTAssertEqual(seen, [.inactive, .disabled])
        XCTAssertEqual(active, [false, false])
        XCTAssertEqual(attachedChanges, 1)
    }

    func testStatusFollowsSession() throws {
        let w: HostWindow = make()
        let session = try FullPanelSession.attach(to: w)
        let status = FullPanelStatus(session: session)
        XCTAssertTrue(status.session === session)
        XCTAssertNil(status.window)
        XCTAssertEqual(status.layout.state, .disabled)
        session.isEnabled = true
        XCTAssertEqual(status.layout.state, .inactive)
        XCTAssertEqual(status.layout.contentSize, w.frame.size)
        session.detach()
        XCTAssertEqual(status.layout.state, .disabled)
    }

    // ---- Lifecycle ------------------------------------------------------------------

    func testRepeatedAttachDetachDoesNotAccumulateObservers() throws {
        let w: HostWindow = make()
        var counts = Set<Int>()
        for _ in 0..<50 {
            let session = try FullPanelSession.attach(to: w)
            session.isEnabled = true
            counts.insert(session.diagnostics()["lifecycleObservers"] as? Int ?? -1)
            session.detach()
            XCTAssertEqual(session.diagnostics()["lifecycleObservers"] as? Int, 0)
        }
        XCTAssertEqual(counts.count, 1, "every session installs the same observers")
        XCTAssertGreaterThan(counts.first ?? 0, 0)
        XCTAssertFalse(w.styleMask.contains(.fullSizeContentView))
    }

    func testCloseRestoresAndStaysAttached() throws {
        let w: HostWindow = make()
        let session = try FullPanelSession.attach(to: w)
        session.isEnabled = true
        w.close()
        XCTAssertEqual(session.state, .inactive)
        XCTAssertTrue(session.isAttached)
        XCTAssertEqual(session.diagnostics()["menuBarOverrideSubmitted"] as? Bool, false)
        let before = NSApp?.presentationOptions
        session.restoreSystemState()
        XCTAssertEqual(NSApp?.presentationOptions, before)
        session.detach()
    }

    func testWindowOwnsSessionAndDeallocationReleasesIt() throws {
        weak var weakSession: FullPanelSession?
        weak var weakWindow: HostWindow?
        try autoreleasepool {
            let w: HostWindow = make()
            weakWindow = w
            let session = try FullPanelSession.attach(to: w)
            session.isEnabled = true
            weakSession = session
        }
        XCTAssertNil(weakWindow, "the session must not retain its window")
        XCTAssertNil(weakSession, "the window's deallocation releases its session")
    }

    func testSessionOutlivingWindowIsInert() throws {
        var session: FullPanelSession?
        weak var weakWindow: HostWindow?
        try autoreleasepool {
            let w: HostWindow = make()
            weakWindow = w
            session = try FullPanelSession.attach(to: w)
            session?.isEnabled = true
        }
        XCTAssertNil(weakWindow)
        XCTAssertEqual(session?.isAttached, false, "the window's deallocation detaches its session")
        XCTAssertEqual(session?.diagnostics()["lifecycleObservers"] as? Int, 0)
        XCTAssertNil(session?.window)
        XCTAssertNil(session?.geometry)
        session?.restoreSystemState()
        session?.detach()
        XCTAssertEqual(session?.isAttached, false)
        session = nil
    }

    func testFullPanelWindowUnaffectedBySessions() throws {
        let attached: HostWindow = make()
        let session = try FullPanelSession.attach(to: attached)
        session.isEnabled = true
        let fp = FullPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        fp.isReleasedWhenClosed = false
        XCTAssertEqual(fp.fullPanelState, .disabled)
        fp.fullPanelEnabled = true
        XCTAssertEqual(fp.fullPanelState, .inactive)
        XCTAssertEqual(fp.fullPanelDiagnostics()["lifecycleObservers"] as? Int,
                       session.diagnostics()["lifecycleObservers"] as? Int)
        fp.setFrame(NSRect(x: 1, y: 2, width: 310, height: 210), display: false)
        XCTAssertEqual(fp.frame, NSRect(x: 1, y: 2, width: 310, height: 210))
        session.detach()
    }
}
