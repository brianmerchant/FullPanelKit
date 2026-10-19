// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// Lifecycle scenarios for attaching FullPanelSession at different points of a
// native fullscreen entry (launch with -FullPanelAttachScenario <name>):
//
//   fresh          attach, then enter fullscreen normally (Scenario A)
//   existing       enter fullscreen unattached, attach + enable inside it,
//                  then exit and enter again (Scenario B). Run with
//                  -FullPanelAttachManual YES so the window is not attached at
//                  appearance.
//   restoreSetup   enter fullscreen with every attached window, then quit with
//                  the windows kept (run with -NSQuitAlwaysKeepsWindows YES)
//   restoreCheck   the relaunch: AppKit restores the windows straight into
//                  fullscreen, without -toggleFullScreen:. Records whether each
//                  attached window becomes active without leaving fullscreen.
//   lifecycle      repeated attach/detach, closing a window in fullscreen and
//                  during the entry and exit animations, and two FullPanel
//                  windows in two fullscreen Spaces at once (presentation
//                  ownership when one of them closes)
//
// Options: -FullPanelAttachScenarioWindows <n> (restoreSetup/restoreCheck, default 1),
// -FullPanelAttachMissionControlCycles <n> (fresh, restoreCheck: originating-Space
// Mission Control returns), -FullPanelAttachExpectFallback YES (restoreCheck with a
// late attach: expect the documented fallback instead of adoption),
// -FullPanelAttachDelayMs <ms> (WindowModel: attach that much later),
// -FullPanelAttachBackgroundFirst YES (restoreCheck: put the application in the
// background first, then activate it through LaunchServices like a Dock click),
// -FullPanelAttachReport <path> (JSON; default ~/Downloads/FullPanelAttachDemo-<scenario>.json),
// -FullPanelAttachLifecycleSteps L1,L2,L5 (lifecycle: run only these steps; default all,
// 13 fullscreen transitions; L1+L2+L5 is 7).
//
// Pixels: each check captures the band beside the camera housing (screencapture,
// so the launching terminal needs Screen Recording) and reports the fraction of
// non-black pixels in each region (the demo's window content: navy background
// and green / blue bars); ordinary fullscreen leaves the band black. An accepted frame is not proof.

import AppKit
import FullPanelKit

@MainActor
final class ScenarioTest {
    static var shared: ScenarioTest?
    private static let start = ProcessInfo.processInfo.systemUptime

    private let name: String
    private var timeline: [[String: Any]] = []
    private var checks: [[String: Any]] = []
    private var results: [String: Any] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard

    init(name: String) {
        self.name = name
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
        ]
        for n in names {
            tokens.append(center.addObserver(forName: n, object: nil, queue: nil) { note in
                MainActor.assumeIsolated {
                    guard let w = note.object as? NSWindow, !Self.isAuxiliary(w) else { return }
                    ScenarioTest.shared?.event(n.rawValue.replacingOccurrences(of: "NSWindow", with: ""), w)
                }
            })
        }
    }

    private static func isAuxiliary(_ w: NSWindow) -> Bool {
        NSStringFromClass(type(of: w)).hasPrefix("NSToolbarFullScreen") || NSStringFromClass(type(of: w)).hasPrefix("_NS")
    }

    static func ms() -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }

    func event(_ what: String, _ window: NSWindow?, _ extra: [String: Any] = [:]) {
        var e: [String: Any] = ["tMs": Self.ms().rounded(), "event": what]
        if let window {
            e["window"] = String(format: "%p", unsafeBitCast(window, to: Int.self))
            e["fs"] = window.styleMask.contains(.fullScreen)
            e["frame"] = NSStringFromRect(window.frame)
            if let s = FullPanelSession.session(for: window) {
                let d = s.diagnostics()
                e["state"] = s.state.rawValue
                e["armed"] = d["armed"]
                e["space"] = d["fullscreenSpaceID"]
                e["entryPreparedBy"] = d["entryPreparedBy"] ?? ""
            }
        }
        e.merge(extra) { a, _ in a }
        timeline.append(e)
        NSLog("FullPanelAttachDemo scenario: %@", e.description)
    }

    private func check(_ label: String, _ ok: Bool, _ detail: Any = "") {
        checks.append(["check": label, "ok": ok, "detail": "\(detail)"])
        NSLog("FullPanelAttachDemo scenario %@: %@ %@", ok ? "PASS" : "FAIL", label, "\(detail)")
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func waitFor(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            await sleep(0.05)
        }
        return cond()
    }

    private var attachedModels: [WindowModel] {
        DemoRegistry.shared.models.filter { $0.role == .attached }
    }

    private func waitWindows(_ n: Int) async -> [WindowModel] {
        _ = await waitFor(10) { attachedModels.count >= n }
        return Array(attachedModels.prefix(n))
    }

    // ---- Measurement ---------------------------------------------------------------

    /// Fraction of non-black pixels in the regions left and right of the housing:
    /// the demo's window background (navy) and bars, versus the black band of
    /// ordinary fullscreen.
    private func bandPixels(_ screen: NSScreen, label: String) -> [String: Any] {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return ["error": "no camera housing on this screen"]
        }
        let dir = (defaults.string(forKey: "FullPanelAttachShotDir") ?? NSTemporaryDirectory())
        // screencapture does not create directories: a missing one is a
        // "capture failed", which says nothing about the band.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(name)-\(label).png")
        let inset = screen.safeAreaInsets.top
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R\(Int(screen.frame.minX)),0,\(Int(screen.frame.width)),\(Int(inset))", path]
        do { try task.run() } catch let failure { return ["error": failure.localizedDescription] }
        task.waitUntilExit()
        guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else {
            return ["error": "capture failed", "path": path]
        }
        let scale = CGFloat(rep.pixelsWide) / screen.frame.width
        func bright(_ r: NSRect) -> Double {
            var hit = 0, n = 0
            var x = r.minX - screen.frame.minX + 8
            while x < r.maxX - screen.frame.minX - 8 {
                var y: CGFloat = 3
                while y < inset - 3 {
                    if let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale)) {
                        n += 1
                        if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.08 { hit += 1 }
                    }
                    y += 3
                }
                x += 6
            }
            return n == 0 ? 0 : (Double(hit) / Double(n) * 100).rounded() / 100
        }
        return ["left": bright(left), "right": bright(right), "path": path]
    }

    private func sample(_ label: String, _ model: WindowModel) -> [String: Any] {
        guard let window = model.window, let session = model.session else {
            return ["label": label, "error": "no window or session"]
        }
        let d = session.diagnostics()
        var s: [String: Any] = [
            "label": label, "tMs": Self.ms().rounded(),
            "state": session.state.rawValue, "fallbackReason": session.fallbackReason.rawValue,
            "inFullScreen": window.styleMask.contains(.fullScreen),
            "frame": NSStringFromRect(window.frame),
            "screen": window.screen.map { NSStringFromRect($0.frame) } ?? "none",
        ]
        for key in ["armed", "frameAccepted", "fullscreenSpaceID", "windowServerBounds",
                    "menuBarOverrideSubmitted", "entryPreparedBy", "adoption", "lastError",
                    "appPresentationOptionsRaw", "revealActive"] {
            if let v = d[key] { s[key] = v }
        }
        if let screen = window.screen, window.styleMask.contains(.fullScreen), window.isOnActiveSpace {
            s["pixels"] = bandPixels(screen, label: label)
        }
        NSLog("FullPanelAttachDemo scenario sample: %@", s.description)
        return s
    }

    private func pixelsRendered(_ s: [String: Any]) -> Bool {
        guard let p = s["pixels"] as? [String: Any],
              let l = p["left"] as? Double, let r = p["right"] as? Double else { return false }
        return l > 0.9 && r > 0.9
    }

    /// The band was actually captured and is black. A sample taken while the
    /// window's Space is not shown has no pixels and proves nothing.
    private func pixelsBlack(_ s: [String: Any]) -> Bool {
        guard let p = s["pixels"] as? [String: Any],
              let l = p["left"] as? Double, let r = p["right"] as? Double else { return false }
        return l < 0.1 && r < 0.1
    }

    /// A relaunched application is not necessarily active: a process started
    /// from a script (not LaunchServices) can stay in the background, and then
    /// macOS never shows the Space AppKit restored its window into. A user who
    /// launches the app from the Dock or Finder gets it active. Harness
    /// precondition, not an SDK check.
    private func activateApplication(launchServices: Bool = false) async -> Bool {
        if !NSApp.isActive && !launchServices {
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        }
        if !launchServices, await waitFor(3, { NSApp.isActive }) { return true }
        // Cooperative activation can refuse a background process; ask
        // LaunchServices, as a Dock click does. By path, never by bundle
        // identifier: other builds of this demo share it, and `open -b` may
        // launch one of those instead of activating this process.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundlePath]
        try? task.run()
        task.waitUntilExit()
        return await waitFor(5) { NSApp.isActive }
    }

    private func spaceID(_ model: WindowModel) -> Int {
        (model.session?.diagnostics()["fullscreenSpaceID"] as? NSNumber)?.intValue ?? 0
    }

    private func isActive(_ m: WindowModel) -> Bool { m.session?.state == .active }

    private func enter(_ m: WindowModel) async -> Bool {
        guard let w = m.window else { return false }
        if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        let ok = await waitFor(8) { w.styleMask.contains(.fullScreen) && w.isOnActiveSpace }
        await sleep(1.2)   // let the entry animation and SkyLight commit finish
        return ok
    }

    private func exit(_ m: WindowModel) async -> Bool {
        guard let w = m.window else { return false }
        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        let ok = await waitFor(8) { !w.styleMask.contains(.fullScreen) }
        await sleep(0.8)
        return ok
    }

    // ---- Mission Control (originating-Space return) ---------------------------------

    /// -FullPanelAttachMissionControlCycles N: opens Mission Control, then presses
    /// Escape, which returns to the Space Mission Control was opened from. Needs
    /// Accessibility for the launching terminal (the Escape key event).
    private func missionControlCycles(_ m: WindowModel, _ label: String) async {
        let n = defaults.integer(forKey: "FullPanelAttachMissionControlCycles")
        guard n > 0, let w = m.window else { return }
        let space0 = spaceID(m)
        var rows: [[String: Any]] = []
        for i in 1...n {
            event("missionControl-open \(i)", w)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            let left = await waitFor(3) { !w.isKeyWindow || !w.occlusionState.contains(.visible) }
            await sleep(1.2)
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
            }
            event("missionControl-escape \(i)", w)
            let back = await waitFor(5) { w.isKeyWindow && w.isOnActiveSpace && w.occlusionState.contains(.visible) }
            // The engine's compositor-verified return check, then its re-assert.
            _ = await waitFor(4) { (m.session?.diagnostics()["returnCheckPending"] as? Bool) == false }
            await sleep(0.6)
            let s = sample("\(label)-mc\(i)", m)
            let ok = back && isActive(m) && pixelsRendered(s) && spaceID(m) == space0
            check("\(label) Mission Control return \(i)", ok,
                  "left=\(left) back=\(back) state=\(s["state"] ?? "") space=\(space0)->\(spaceID(m)) pixels=\(s["pixels"] ?? "")")
            rows.append(s)
        }
        results["\(label)MissionControl"] = rows
    }

    // ---- Scenarios -----------------------------------------------------------------

    func run() async {
        NSLog("FullPanelAttachDemo scenario %@ starting", name)
        switch name {
        case "fresh": await fresh()
        case "existing": await existing()
        case "restoreSetup": await restoreSetup()
        case "restoreCheck": await restoreCheck()
        case "lifecycle": await lifecycle()
        default: check("known scenario", false, name)
        }
        finish()
    }

    private func fresh() async {
        guard let m = await waitWindows(1).first else { return check("window", false) }
        check("attached before entry", m.session != nil && m.window?.styleMask.contains(.fullScreen) == false)
        check("entered fullscreen", await enter(m))
        let s = sample("fresh-entered", m)
        results["fresh"] = s
        check("active after fresh entry", isActive(m), s["state"] ?? "")
        check("notch-side pixels rendered (fresh)", pixelsRendered(s), s["pixels"] ?? "")
        await missionControlCycles(m, "fresh")
        check("exited", await exit(m))
        check("inactive after exit", m.session?.state == .inactive)
    }

    private func existing() async {
        guard let m = await waitWindows(1).first else { return check("window", false) }
        check("not attached at appearance", m.session == nil)
        check("entered fullscreen unattached", await enter(m))
        m.attach()
        event("attached-inside-fullscreen", m.window)
        let spaceBefore = spaceID(m)
        await sleep(2.0)
        let s = sample("existing-attached", m)
        results["existingAttached"] = s
        let sameSpace = spaceBefore != 0 && spaceBefore == spaceID(m)
        check("window kept its fullscreen Space", sameSpace, "\(spaceBefore) -> \(spaceID(m))")
        // In-place adoption is not possible (WindowServer keeps an existing
        // fullscreen Space camera-safe); the session must say so, not claim it.
        results["inPlaceAdoption"] = isActive(m) && pixelsRendered(s)
        check("attached inside fullscreen: documented fallback, no FullPanel claim",
              m.session?.state == .fallback && !((s["adoption"] as? String) ?? "").isEmpty && pixelsBlack(s),
              "state=\(s["state"] ?? "") pixels=\(s["pixels"] ?? "") adoption=\(s["adoption"] ?? "")")
        check("never left fullscreen while attaching", !timeline.contains { ($0["event"] as? String)?.contains("Exit") == true })
        // The next entry is a FullPanel entry.
        check("exited", await exit(m))
        check("re-entered", await enter(m))
        let s2 = sample("existing-reentered", m)
        results["existingReentered"] = s2
        check("active on the next entry", isActive(m), s2["state"] ?? "")
        check("notch-side pixels rendered (next entry)", pixelsRendered(s2), s2["pixels"] ?? "")
        check("exited again", await exit(m))
    }

    private func restoreSetup() async {
        let n = max(1, defaults.integer(forKey: "FullPanelAttachScenarioWindows"))
        // Start from exactly n windowed windows, whatever the last run's saved
        // state restored: the saved state then holds only this setup.
        _ = await waitWindows(1)
        await sleep(1.0)   // let a restoration finish first
        for m in attachedModels where m.window?.styleMask.contains(.fullScreen) == true { _ = await exit(m) }
        for m in attachedModels.dropFirst(n) { m.window?.close() }
        _ = await waitFor(5) { attachedModels.count <= n }
        var models = await waitWindows(1)
        while models.count < n {
            DemoRegistry.shared.openWindow?(SceneID.fullPanel)
            models = await waitWindows(models.count + 1)
            if models.count < n && attachedModels.count < n { break }
        }
        check("windows open", models.count == n, models.count)
        for (i, m) in models.enumerated() {
            check("window \(i) entered fullscreen", await enter(m))
            check("window \(i) active before quit", isActive(m))
        }
        results["setup"] = models.map { ["window": String(describing: $0.window.map { String(format: "%p", unsafeBitCast($0, to: Int.self)) }),
                                         "space": spaceID($0)] }
        check("NSQuitAlwaysKeepsWindows", defaults.bool(forKey: "NSQuitAlwaysKeepsWindows"),
              "launch with -NSQuitAlwaysKeepsWindows YES so AppKit restores the windows")
    }

    private func restoreCheck() async {
        // Nothing here enters fullscreen: AppKit's restoration does.
        let expected = max(1, defaults.integer(forKey: "FullPanelAttachScenarioWindows"))
        // The windows AppKit restored into fullscreen (a windowed restored window
        // may be open too).
        func restoredFullScreen() -> [WindowModel] {
            attachedModels.filter { $0.window?.styleMask.contains(.fullScreen) == true }
        }
        let restored = await waitFor(10) { restoredFullScreen().count >= expected }
        let models = Array(restoredFullScreen().prefix(expected))
        check("restored into fullscreen", restored && models.count == expected,
              "\(restoredFullScreen().count) in fullscreen of \(attachedModels.count) windows")
        guard !models.isEmpty else { return }
        let expectFallback = defaults.bool(forKey: "FullPanelAttachExpectFallback")
        _ = await waitFor(6) { models.allSatisfy { expectFallback ? $0.session != nil : isActive($0) } }
        _ = await waitFor(5) { models.allSatisfy { spaceID($0) != 0 } }
        // Hold: a bounce would show up as exit notifications in this window.
        var spaces: [Int] = models.map(spaceID)
        await sleep(1.5)
        // -FullPanelAttachBackgroundFirst YES (R5): the windows were restored
        // while another application is in use (login, or a relaunch the user
        // did not bring forward). The restored Spaces exist but are not shown;
        // the menu bar is committed only once the window is key there. The
        // application is then activated through LaunchServices, as a Dock
        // click does.
        let background = defaults.bool(forKey: "FullPanelAttachBackgroundFirst")
        if background {
            let finder = Process()
            finder.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            finder.arguments = ["-b", "com.apple.finder"]
            try? finder.run()
            finder.waitUntilExit()
            let inactive = await waitFor(5) { !NSApp.isActive }
            await sleep(2.0)
            let hidden = models.allSatisfy { !($0.window?.isKeyWindow ?? false) }
            event("background", nil, ["inactive": inactive, "hidden": hidden])
            check("harness: application in the background (precondition)", inactive && hidden)
            // The commit may or may not have happened before the application
            // went to the background; it is recorded, not required either way.
            check("in the background: no exit, whole-display entry kept",
                  models.allSatisfy { isActive($0) && $0.window?.styleMask.contains(.fullScreen) == true },
                  models.map { "state=\($0.session?.state.rawValue ?? -1) " +
                               "submitted=\($0.session?.diagnostics()["menuBarOverrideSubmitted"] ?? "")" })
        }
        let wasActive = NSApp.isActive
        let active = await activateApplication(launchServices: background)
        event("harness-activate", nil, ["wasActive": wasActive, "active": active])
        check("harness: application active before the checks (precondition)", active,
              "wasActive=\(wasActive)")
        var out: [[String: Any]] = []
        for (i, m) in models.enumerated() {
            if let w = m.window, !(w.isOnActiveSpace && w.isKeyWindow) {
                // Bring each restored Space forward in turn for its pixel check.
                w.makeKeyAndOrderFront(nil)
                _ = await waitFor(3) { w.isOnActiveSpace && w.isKeyWindow }
            }
            // The restored entry skipped its didEnterFullScreen commit (its Space
            // was not active); the return check commits once the window is key.
            _ = await waitFor(3) { (m.session?.diagnostics()["returnCheckPending"] as? Bool) == false }
            await sleep(1.0)
            let shown = m.window.map { $0.isOnActiveSpace && $0.isKeyWindow } ?? false
            check("window \(i) shown and key in its fullscreen Space", shown)
            let s = sample("restored-\(i)", m)
            out.append(s)
            let detail = "state=\(s["state"] ?? "") reason=\(s["fallbackReason"] ?? "") prepared=\(s["entryPreparedBy"] ?? "") adoption=\(s["adoption"] ?? "")"
            if expectFallback {
                // Attached after AppKit's entry began: documented fallback, not adopted.
                check("window \(i) reports late attachment (fallback + adoption note)",
                      m.session?.state == .fallback && !((s["adoption"] as? String) ?? "").isEmpty, detail)
                check("window \(i) band captured and black (no claim of FullPanel pixels)", pixelsBlack(s), s["pixels"] ?? "")
            } else {
                check("window \(i) active after restore", isActive(m), detail)
                check("window \(i) notch-side pixels rendered", pixelsRendered(s), s["pixels"] ?? "")
            }
            check("window \(i) kept its restored fullscreen Space", spaces[i] != 0 && spaces[i] == spaceID(m), "\(spaces[i]) -> \(spaceID(m))")
            spaces[i] = spaceID(m)
        }
        results["restored"] = out
        let exits = timeline.filter { ($0["event"] as? String)?.contains("Exit") == true }
        check("no exit/re-entry bounce", exits.isEmpty, "\(exits.count) exit notifications")
        let enters = timeline.filter { ($0["event"] as? String) == "WillEnterFullScreenNotification" }
        check("one entry per restored window", enters.count == expected, enters.count)
        if !expectFallback, let first = models.first { await missionControlCycles(first, "restored") }
        // Leave fullscreen so the saved state does not keep restoring.
        for m in attachedModels { _ = await exit(m) }
    }

    // ---- Lifecycle (closing, transitions, repeated attachment, two Spaces) -----------

    private static let forcedPresentation: NSApplication.PresentationOptions = [.fullScreen, .hideMenuBar, .hideDock]

    /// Opens a new SwiftUI window of `role` and returns its model: never one
    /// that existed before (a closed window can outlive its close).
    private func openWindow(_ role: WindowModel.Role) async -> WindowModel? {
        let before = Set(DemoRegistry.shared.models.map(ObjectIdentifier.init))
        func fresh() -> WindowModel? {
            DemoRegistry.shared.models.first { $0.role == role && !before.contains(ObjectIdentifier($0)) }
        }
        DemoRegistry.shared.openWindow?(role == .attached ? SceneID.fullPanel : SceneID.ordinary)
        _ = await waitFor(8) { fresh().map { role != .attached || $0.session != nil } ?? false }
        await sleep(0.8)
        return fresh()
    }

    private func openAttachedWindow(excluding: [WindowModel]) async -> WindowModel? {
        await openWindow(.attached)
    }

    /// Closes a window and reports whether its session went away with it (the
    /// window owns the session; SwiftUI frees closed scene windows).
    private func closeAndRelease(_ m: WindowModel, _ label: String) async {
        let session = Weak(m.session), window = Weak(m.window)
        m.window?.close()
        let released = await waitFor(6) { (session.object as? FullPanelSession)?.isAttached != true }
        await sleep(1.5)   // the Space transition after a fullscreen window closes
        check("\(label): session released or detached", released,
              "windowFreed=\(window.object == nil)")
    }

    /// What happened to a window closed `delay` seconds into a fullscreen entry
    /// (`exiting` NO) or exit (YES), for an attached window and for an
    /// ordinary SwiftUI window as the AppKit control.
    private func closeDuringTransition(_ role: WindowModel.Role, exiting: Bool, delay: Double) async -> [String: Any]? {
        guard let m = await openWindow(role), let w = m.window else { return nil }
        if exiting {
            guard await enter(m) else { return nil }
        }
        let session = Weak(m.session), window = Weak(w)
        w.toggleFullScreen(nil)
        await sleep(delay)
        event("close during \(exiting ? "exit" : "entry") (\(role.rawValue))", w,
              ["inFullScreenStyle": w.styleMask.contains(.fullScreen)])
        w.close()
        _ = await waitFor(8) { window.object == nil }
        await sleep(1.5)
        let survivor = window.object as? NSWindow
        var r: [String: Any] = [
            "freed": survivor == nil,
            "visible": survivor?.isVisible ?? false,
            "inFullScreen": survivor?.styleMask.contains(.fullScreen) ?? false,
            "presentation": String(NSApp.presentationOptions.rawValue, radix: 16),
        ]
        if let s = session.object as? FullPanelSession {
            r["sessionAttached"] = s.isAttached
            r["state"] = s.state.rawValue
            r["menuBarOverrideSubmitted"] = s.diagnostics()["menuBarOverrideSubmitted"] ?? ""
        }
        // Leave nothing behind for the next step.
        if let survivor {
            if survivor.styleMask.contains(.fullScreen) { survivor.toggleFullScreen(nil); await sleep(1.5) }
            survivor.close()
            await sleep(1.0)
        }
        return r
    }

    private func lifecycle() async {
        guard let a = await waitWindows(1).first, let aw = a.window else { return check("window", false) }
        let steps = Set((defaults.string(forKey: "FullPanelAttachLifecycleSteps") ?? "L1,L2,L3,L4,L5")
                            .split(separator: ",").map(String.init))
        results["lifecycleSteps"] = steps.sorted()

        // L1: repeated attach/detach while windowed restores the window exactly
        // and frees every detached session.
        if steps.contains("L1") {
            a.detach()
            await sleep(0.3)
            let frame0 = aw.frame, style0 = aw.styleMask.rawValue
            let transparent0 = aw.titlebarAppearsTransparent, behavior0 = aw.collectionBehavior.rawValue
            var detached: [Weak] = []
            for _ in 1...20 {
                a.attach()
                detached.append(Weak(a.session))
                a.detach()
            }
            await sleep(0.3)
            check("L1 20 attach/detach cycles: frame unchanged", aw.frame == frame0,
                  "\(NSStringFromRect(frame0)) -> \(NSStringFromRect(aw.frame))")
            check("L1 style, titlebar and collection behavior unchanged",
                  aw.styleMask.rawValue == style0 && aw.titlebarAppearsTransparent == transparent0
                      && aw.collectionBehavior.rawValue == behavior0,
                  "style 0x\(String(style0, radix: 16))->0x\(String(aw.styleMask.rawValue, radix: 16)) "
                      + "cb 0x\(String(behavior0, radix: 16))->0x\(String(aw.collectionBehavior.rawValue, radix: 16))")
            check("L1 detached sessions freed", detached.allSatisfy { $0.object == nil },
                  "\(detached.filter { $0.object != nil }.count) of \(detached.count) alive")
            check("L1 no session left on the window", FullPanelSession.session(for: aw) == nil)
            a.attach()
            check("L1 re-attached", a.session?.isEnabled == true)
        }

        // L2: close a window in FullPanel fullscreen.
        if !steps.contains("L2") {
        } else if let b = await openAttachedWindow(excluding: [a]) {
            check("L2 entered fullscreen", await enter(b))
            check("L2 active before close", isActive(b))
            await closeAndRelease(b, "L2 close in fullscreen")
            check("L2 presentation options released", NSApp.presentationOptions.isEmpty,
                  "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
        } else { check("L2 second window opened", false) }

        // L3 / L4: close 150 ms into the entry / exit animation. AppKit decides
        // what a close during a transition does; the attached window must end
        // the same way as an ordinary window (control) and must not leave
        // FullPanel's menu-bar override or forced presentation behind.
        for (label, exiting) in [("L3 close during entry", false), ("L4 close during exit", true)]
            where steps.contains(String(label.prefix(2))) {
            let control = await closeDuringTransition(.ordinary, exiting: exiting, delay: 0.15)
            let attached = await closeDuringTransition(.attached, exiting: exiting, delay: 0.15)
            results[label] = ["control": control ?? [:], "attached": attached ?? [:]]
            guard let control, let attached else { check("\(label): windows opened", false); continue }
            let sameOutcome = ["freed", "visible", "inFullScreen"].allSatisfy {
                (control[$0] as? Bool) == (attached[$0] as? Bool)
            }
            check("\(label): same outcome as an ordinary window", sameOutcome,
                  "control=\(control) attached=\(attached)")
            check("\(label): no menu-bar override left",
                  (attached["menuBarOverrideSubmitted"] as? Bool) != true, attached)
            check("\(label): presentation options released", NSApp.presentationOptions.isEmpty,
                  "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
        }

        // The first window is unaffected by all of the above.
        check("first window still attached, enabled and windowed",
              a.session?.isEnabled == true && aw.styleMask.contains(.fullScreen) == false
                  && a.session?.state == .inactive)

        // L5: two FullPanel windows in two fullscreen Spaces at once.
        guard steps.contains("L5") else { return }
        guard let e = await openAttachedWindow(excluding: [a]), let ew = e.window else {
            return check("L5 second window opened", false)
        }
        check("L5 first window entered fullscreen", await enter(a))
        ew.makeKeyAndOrderFront(nil)
        _ = await waitFor(3) { ew.isKeyWindow }
        check("L5 second window entered fullscreen", await enter(e))
        let spaceA = spaceID(a), spaceE = spaceID(e)
        check("L5 two distinct fullscreen Spaces", spaceA != 0 && spaceE != 0 && spaceA != spaceE, "\(spaceA) \(spaceE)")
        let se = sample("L5-second", e)
        check("L5 second window active, pixels rendered", isActive(e) && pixelsRendered(se), se["pixels"] ?? "")
        check("L5 first window still active in its own Space", isActive(a))
        aw.makeKeyAndOrderFront(nil)
        let backA = await waitFor(4) { aw.isOnActiveSpace && aw.isKeyWindow }
        _ = await waitFor(3) { (a.session?.diagnostics()["returnCheckPending"] as? Bool) == false }
        await sleep(0.8)
        let sa = sample("L5-first", a)
        check("L5 switch back to the first Space: active, pixels rendered",
              backA && isActive(a) && pixelsRendered(sa), "shown=\(backA) pixels=\(sa["pixels"] ?? "")")
        check("L5 first window owns the forced presentation",
              NSApp.presentationOptions == Self.forcedPresentation,
              "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
        // Closing the other fullscreen window (not key, another Space) must not
        // release the options the key FullPanel window still forces.
        let eSession = Weak(e.session)
        ew.close()
        _ = await waitFor(6) { (eSession.object as? FullPanelSession)?.isAttached != true }
        await sleep(1.5)
        check("L5 closing the other window keeps the first window's presentation",
              NSApp.presentationOptions == Self.forcedPresentation,
              "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
        let sa2 = sample("L5-first-after-close", a)
        check("L5 first window still active and rendered after the other closed",
              isActive(a) && aw.isOnActiveSpace && pixelsRendered(sa2), sa2["pixels"] ?? "")
        check("L5 first window exited", await exit(a))
        check("L5 presentation options released after the last exit", NSApp.presentationOptions.isEmpty,
              "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
        check("L5 first window inactive after exit", a.session?.state == .inactive)
    }

    private final class Weak {
        weak var object: AnyObject?
        init(_ object: AnyObject?) { self.object = object }
    }

    private func finish() {
        let failed = checks.filter { ($0["ok"] as? Bool) != true }
        let report: [String: Any] = [
            "scenario": name, "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "passed": checks.count - failed.count, "failed": failed.count,
            "checks": checks, "timeline": timeline, "results": results,
        ]
        let path = defaults.string(forKey: "FullPanelAttachReport")
            ?? ("~/Downloads/FullPanelAttachDemo-\(name).json" as NSString).expandingTildeInPath
        if let data = try? JSONSerialization.data(withJSONObject: jsonSafe(report), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSLog("FullPanelAttachDemo scenario %@ done: %d passed, %d failed; report %@",
              name, checks.count - failed.count, failed.count, path)
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        NSApp.terminate(nil)
    }

    private func jsonSafe(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.mapValues(jsonSafe) }
        if let a = v as? [Any] { return a.map(jsonSafe) }
        if v is NSNumber || v is String { return v }
        return "\(v)"
    }
}
