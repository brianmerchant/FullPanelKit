// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// Scripted hardware run (launch with -FullPanelAttachAutotest YES). It drives
// real AppKit fullscreen, Mission Control and window lifecycle, records what
// AppKit and WindowServer report, writes a JSON report and quits.
//
// What it cannot prove: physical pixels and menu-bar transparency (use the
// screenshots taken at each phase), and physical mouse/keyboard input (clicks
// here are synthesized NSEvents delivered through NSApp.sendEvent).
//
// Options (user defaults / launch arguments):
//   -FullPanelAttachReport <path>     JSON report (default ~/Downloads/FullPanelAttachDemo-autotest.json)
//   -FullPanelAttachPhaseFile <path>  current phase name, for external screenshots
//   -FullPanelAttachMissionControl NO skip the Mission Control round trip
//   -FullPanelAttachMissionControlOnly YES  run the two fullscreen cycles (each with a
//                                     Mission Control return) and stop
//   -FullPanelAttachMissionControlTimeout <s>  how long to wait in Mission Control (default 20)
//   -FullPanelAttachNotchClickTimeout <s>  how long to wait for the notch-area click (default 10)
//   -FullPanelAttachDetachOnly YES    presentation lifecycle only: a normal fullscreen cycle, then
//                                     detach in fullscreen sampled every 100 ms for 3 s, then
//                                     re-attach and a further cycle (run with -FullPanelTrace YES)
//   -FullPanelAttachPresentationExperiment YES  AppKit only (no FullPanel): in native fullscreen, set
//                                     NSApp.presentationOptions to several values and sample the getter
//                                     immediately and over the next run-loop turns / 1 s
//   -FullPanelAttachAppKitSubclassOnly YES  AppKit integration only: an application-defined
//                                     NSWindow subclass (NSWindowController, ordinary delegate)
//                                     with FullPanelSession, two fullscreen cycles with Mission
//                                     Control returns, detach/re-attach, untouched control window
//   -FullPanelAttachBriefing NO       skip the dialog that explains the manual steps
//   -FullPanelAttachRevealProbe YES   also warp the pointer to the top edge (it
//                                     moves the real cursor and can change focus;
//                                     the menu-bar reveal itself needs a person)
//
// Mission Control return is a MANUAL step. The test opens Mission Control, prints
// what to select (cycle 1: the fullscreen Space thumbnail at the top; cycle 2: leave
// Mission Control and swipe to the fullscreen Space) and waits for you, sampling state every 0.25 s. It then
// verifies the return and writes the timeline to the report ("missionControl").
// Nothing here posts input: Mission Control exposes no accessibility children and
// WindowServer does not report the thumbnail, so a click cannot be targeted safely.

import AppKit
import FullPanelKit

@MainActor
final class Autotest {
    private var checks: [[String: Any]] = []
    private var snapshots: [[String: Any]] = []
    private var failures: [String] = []
    private let defaults = UserDefaults.standard
    private let initialPresentation = NSApp.presentationOptions

    // ---- Infrastructure ----------------------------------------------------------

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitFor(_ what: String, timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(0.05)
        }
        check("timeout waiting for \(what)", false)
        return false
    }

    private func check(_ name: String, _ ok: Bool, _ detail: Any = "") {
        checks.append(["check": name, "ok": ok, "detail": "\(detail)"])
        if !ok { failures.append(name) }
        NSLog("FullPanelAttachDemo autotest %@ %@ %@", ok ? "PASS" : "FAIL", name, "\(detail)")
    }

    private func phase(_ name: String) async {
        NSLog("FullPanelAttachDemo autotest phase %@", name)
        if let path = defaults.string(forKey: "FullPanelAttachPhaseFile") {
            try? name.write(toFile: path, atomically: true, encoding: .utf8)
            await sleep(1.2)   // time for an external screenshot
        }
    }

    private func snapshot(_ label: String, _ model: WindowModel) {
        model.refresh()
        var d = model.diagnostics
        d["label"] = label
        d["role"] = model.role.rawValue
        d["leftClicks"] = model.leftClicks
        d["rightClicks"] = model.rightClicks
        d["isKeyWindow"] = model.window?.isKeyWindow ?? false
        d["appPresentationOptionsRaw"] = NSApp.presentationOptions.rawValue
        if model.role == .attached, let window = model.window, window.styleMask.contains(.fullScreen) {
            d.merge(bandDiagnostics(window, model)) { $1 }
        }
        if let layout = Optional(model.layout) {
            d["layoutLeft"] = layout.leftArea.map { NSStringFromRect($0) } ?? "nil"
            d["layoutRight"] = layout.rightArea.map { NSStringFromRect($0) } ?? "nil"
            d["layoutHousing"] = layout.cameraHousing.map { NSStringFromRect($0) } ?? "nil"
        }
        snapshots.append(d.mapValues { jsonSafe($0) })
    }

    /// What is drawn in the camera-housing band, from public APIs only: every on-screen
    /// window overlapping the band (front to back, so a menu bar or other overlay covering
    /// our regions shows up) and the colors our own view tree renders at the centers of the
    /// LEFT and RIGHT areas. The render is the view hierarchy's, not the compositor's.
    private func bandDiagnostics(_ window: NSWindow, _ model: WindowModel) -> [String: Any] {
        var out: [String: Any] = [:]
        guard let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return out }
        let display = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        let band = CGRect(x: display.minX, y: display.minY, width: display.width,
                          height: FullPanelDisplayGeometry(screen: screen).topInset)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var occupants: [String] = []
        for w in list {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.intersects(band) else { continue }
            let ours = (w[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
            occupants.append("\(ours ? "OURS " : "")\(w[kCGWindowOwnerName as String] as? String ?? "?")"
                             + "/\(w[kCGWindowName as String] as? String ?? "") layer \(w[kCGWindowLayer as String] ?? "?")"
                             + " alpha \(w[kCGWindowAlpha as String] ?? "?") \(NSStringFromRect(bounds))")
            if occupants.count >= 12 { break }
        }
        out["bandOccupants"] = occupants
        if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            func rgb(_ area: CGRect?) -> String {
                guard let area else { return "no area" }
                let x = Int(area.midX * CGFloat(rep.pixelsWide) / content.bounds.width)
                let yTop = Int(area.midY * CGFloat(rep.pixelsHigh) / content.bounds.height)
                let y = content.isFlipped ? yTop : rep.pixelsHigh - 1 - yTop
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "unreadable" }
                return String(format: "%.2f,%.2f,%.2f", c.redComponent, c.greenComponent, c.blueComponent)
            }
            out["contentRenderLeft"] = rgb(model.layout.leftArea)       // expect about 0.06,0.88,0.38
            out["contentRenderRight"] = rgb(model.layout.rightArea)     // expect about 0.15,0.75,1.00
        }
        return out
    }

    private func jsonSafe(_ value: Any) -> Any {
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return "\(value)"
    }

    private func model(_ role: WindowModel.Role, excluding: [WindowModel] = []) -> WindowModel? {
        DemoRegistry.shared.models.first { m in m.role == role && !excluding.contains { $0 === m } }
    }

    private func waitModel(_ role: WindowModel.Role, excluding: [WindowModel] = []) async -> WindowModel? {
        var found: WindowModel?
        _ = await waitFor("\(role) window") {
            found = model(role, excluding: excluding)
            return found != nil
        }
        return found
    }

    private func enterFullScreen(_ window: NSWindow, _ label: String) async -> Bool {
        window.makeKeyAndOrderFront(nil)
        await sleep(0.3)
        window.toggleFullScreen(nil)
        let ok = await waitFor("\(label) enter") { window.styleMask.contains(.fullScreen) }
        // The style mask flips at the start of the animation: wait until the frame has
        // stopped changing on the active Space (bounded), then for the didEnter commit.
        var lastFrame = NSRect.zero
        var steady = 0
        _ = await poll(timeout: 8) {
            steady = window.frame == lastFrame && window.isOnActiveSpace ? steady + 1 : 0
            lastFrame = window.frame
            return steady >= 4
        }
        await sleep(0.8)
        return ok
    }

    private func exitFullScreen(_ window: NSWindow, _ label: String) async -> Bool {
        window.toggleFullScreen(nil)
        let ok = await waitFor("\(label) exit") { !window.styleMask.contains(.fullScreen) }
        await sleep(1.4)
        return ok
    }

    // ---- Mission Control ----------------------------------------------------------
    //
    // Why the original round trip failed: it opened Mission Control and then
    // "returned" with NSApp.activate + makeKeyAndOrderFront. That never selects a
    // Space or a window preview, so Mission Control stayed open (the window was
    // still a scaled preview: WindowServer 1157x751, isOnActiveSpace false) and the
    // checks ran against that. The return must be a selection inside Mission Control.

    private var skipped: [String] = []
    private var manualTests: [String] = []
    private var missionControlRuns: [[String: Any]] = []
    private var extraReport: [String: Any] = [:]
    private var missionControlEnabled: Bool {
        !skipMissionControl && (defaults.object(forKey: "FullPanelAttachMissionControl") == nil
                                || defaults.bool(forKey: "FullPanelAttachMissionControl"))
    }
    private var skipMissionControl = false

    /// Mission Control hides this app's windows, so the person cannot read a prompt
    /// while it is open. Explain the two manual steps before anything starts.
    private func briefing() {
        guard missionControlEnabled, defaults.object(forKey: "FullPanelAttachBriefing") == nil
                || defaults.bool(forKey: "FullPanelAttachBriefing") else { return }
        let alert = NSAlert()
        alert.messageText = "FullPanelAttachDemo hardware test"
        alert.informativeText = """
            The test enters fullscreen twice and opens Mission Control each time. \
            You must leave Mission Control yourself, and the window is hidden while it is open, \
            so read this now. You will hear a beep and a spoken cue when it is your turn.

            Test 1 — Space thumbnail:
            Mission Control opens. Click the small thumbnail of this app's fullscreen Space \
            in the bar at the top of the screen.

            Test 2 — swipe to the Space:
            Mission Control opens, but no large preview of this window is shown. Leave Mission \
            Control (press Esc or click the desktop), then swipe (or press Control-Left/Right) \
            to this app's fullscreen Space.

            After each return, click the green (LEFT) or blue (RIGHT) area beside the camera \
            notch. If you cannot see them, do nothing: the test records that as a failure.

            Returning from Mission Control waits up to 20 seconds, the notch click 10. If you do nothing, the test stops instead of \
            continuing; if Mission Control is still open, select the window or press Esc.

            The test uses your mouse and keyboard only when you do. Do not touch anything else \
            until it finishes.
            """
        alert.addButton(withTitle: "Start Test")
        alert.addButton(withTitle: "Skip Mission Control Steps")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn:
            skipMissionControl = true
            skipped.append("Mission Control steps (chosen in the briefing dialog)")
        default:
            skipped.append("cancelled in the briefing dialog")
            cancelled = true
        }
    }
    private var cancelled = false

    /// Polls a condition without recording a failure on timeout.
    private func poll(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(0.1)
        }
        return condition()
    }

    /// Engine state can say "active" while no notch-side pixels are drawn, so the person must
    /// click a real notch area (physical mouse, not synthesized) after every return.
    private func requireNotchClick(_ model: WindowModel, label: String) async {
        let timeout = defaults.object(forKey: "FullPanelAttachNotchClickTimeout") != nil
            ? defaults.double(forKey: "FullPanelAttachNotchClickTimeout") : 10
        let l0 = model.leftClicks, r0 = model.rightClicks
        let prompt = "\(label): MANUAL STEP — click the green (LEFT) or blue (RIGHT) area beside the camera notch "
            + "(waiting up to \(Int(timeout)) s). If you cannot see them, do nothing and the test will record that."
        NSLog("FullPanelAttachDemo autotest %@", prompt)
        FileHandle.standardError.write(Data(("\n>>> " + prompt + "\n\n").utf8))
        snapshot("\(label) awaiting notch click", model)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["Click a notch area"]
        try? say.run()
        let started = Date()
        let clicked = await poll(timeout: timeout) { model.leftClicks > l0 || model.rightClicks > r0 }
        snapshot("\(label) after notch click", model)
        let band = model.window.map { bandDiagnostics($0, model) } ?? [:]
        let detail = "left +\(model.leftClicks - l0) right +\(model.rightClicks - r0); layout left \(model.layout.leftArea.map { NSStringFromRect($0) } ?? "nil") right \(model.layout.rightArea.map { NSStringFromRect($0) } ?? "nil")"
            + "; render left \(band["contentRenderLeft"] ?? "-") right \(band["contentRenderRight"] ?? "-")"
            + "; band windows: \((band["bandOccupants"] as? [String])?.joined(separator: " | ") ?? "-")"
        manualTests.append("\(label) notch-area click after Mission Control return: MANUAL — "
                           + (clicked ? "clicked after \(String(format: "%.1f", Date().timeIntervalSince(started))) s" : "NO CLICK RECEIVED"))
        check("\(label) notch area clicked by the person after Mission Control return", clicked,
              clicked ? detail : "no click within \(Int(timeout)) s (notch areas not visible or not clickable?) " + detail)
    }

    // ---- Detach-in-fullscreen presentation probe ------------------------------------

    private static let forcedBits: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar]

    private func presentationSample(_ label: String, _ window: NSWindow, _ session: FullPanelSession,
                                    since: Date?) -> [String: Any] {
        let d = session.diagnostics()
        let app = NSApp.presentationOptions
        return ["label": label,
                "msSinceDetach": since.map { Int(Date().timeIntervalSince($0) * 1000) } ?? NSNull(),
                "appPresentation": "0x" + String(app.rawValue, radix: 16),
                "appForced": !app.isDisjoint(with: Self.forcedBits),
                "systemPresentation": "0x" + String(NSApp.currentSystemPresentationOptions.rawValue, radix: 16),
                "attached": session.isAttached, "enabled": session.isEnabled, "state": session.state.rawValue,
                "inFullScreen": window.styleMask.contains(.fullScreen),
                "onActiveSpace": window.isOnActiveSpace,
                "revealActive": jsonSafe(d["revealActive"] ?? "-"),
                "revealAllowed": jsonSafe(d["revealAllowed"] ?? "-"),
                "menuBarRevealed": jsonSafe(d["menuBarRevealed"] ?? "-"),
                "menuBarOverrideSubmitted": jsonSafe(d["menuBarOverrideSubmitted"] ?? "-")]
    }

    /// Enters FullPanel fullscreen, detaches, then watches the presentation options. A late
    /// restore is reported with its delay but still fails the check: the contract is that
    /// detach restores them at once (docs/ATTACHMENT.md).
    private func detachPresentationProbe(_ model: WindowModel, _ window: NSWindow, _ session: FullPanelSession) async {
        var samples: [[String: Any]] = [presentationSample("before fullscreen", window, session, since: nil)]
        let windowed = NSApp.presentationOptions

        // Normal fullscreen exit first: FullPanel forced, then AppKit restores the windowed options.
        if await enterFullScreen(window, "normal cycle") {
            check("normal cycle: FullPanel active, presentation forced", session.state == .active
                  && !NSApp.presentationOptions.isDisjoint(with: Self.forcedBits),
                  "0x" + String(NSApp.presentationOptions.rawValue, radix: 16))
            _ = await exitFullScreen(window, "normal cycle")
            check("normal cycle exit: windowed presentation restored", NSApp.presentationOptions == windowed
                  && session.state == .inactive,
                  "0x" + String(NSApp.presentationOptions.rawValue, radix: 16)
                  + " restore: \(session.diagnostics()["lastPresentationRestore"] ?? "-")")
        }

        guard await enterFullScreen(window, "detach probe") else { return }
        samples.append(presentationSample("fullscreen, FullPanel active", window, session, since: nil))
        check("detach probe: FullPanel active in fullscreen", session.state == .active, session.state.rawValue)
        samples.append(presentationSample("immediately before detach", window, session, since: nil))
        let nativeRaw = session.diagnostics()["nativeFullScreenPresentationRaw"] as? Int ?? -1
        let detachedAt = Date()
        model.detach()
        samples.append(presentationSample("immediately after detach", window, session, since: detachedAt))
        let afterDetach = NSApp.presentationOptions.rawValue
        let restore = session.diagnostics()["lastPresentationRestore"] ?? "-"
        var post: [Bool] = [samples.last!["appForced"] as? Bool ?? true]
        while Date().timeIntervalSince(detachedAt) < 3 {
            await sleep(0.1)
            let sample = presentationSample("poll", window, session, since: detachedAt)
            samples.append(sample)
            post.append(sample["appForced"] as? Bool ?? true)
        }
        _ = await exitFullScreen(window, "detach probe")
        samples.append(presentationSample("after fullscreen exit", window, session, since: nil))

        // Classify the series that starts immediately after the detach.
        let classification: String
        var delayMs: Any = NSNull()
        if post.allSatisfy({ !$0 }) {
            classification = "restored immediately"
        } else if post.allSatisfy({ $0 }) {
            classification = "remained forced for the whole observation"
        } else if let firstClear = post.firstIndex(of: false), post[firstClear...].contains(true) {
            classification = "restored, then forced again"
        } else {
            classification = "restored after a delay"
            let poll = samples.filter { $0["label"] as? String == "poll" }
            delayMs = poll.first { $0["appForced"] as? Bool == false }?["msSinceDetach"] ?? NSNull()
        }
        extraReport["detachPresentation"] = ["classification": classification, "restoreDelayMs": delayMs,
                                             "samples": samples]
        NSLog("FullPanelAttachDemo autotest detach presentation: %@ (delay %@)", classification, "\(delayMs)")
        check("detach in fullscreen: FullPanel presentation released immediately", classification == "restored immediately",
              "\(classification); restoreDelayMs \(delayMs)")
        check("detach in fullscreen: restored to the native fullscreen policy recorded at entry",
              nativeRaw >= 0 && afterDetach == UInt(nativeRaw),
              "native 0x\(String(nativeRaw, radix: 16)) after detach 0x\(String(afterDetach, radix: 16)); \(restore)")
        check("detached exit: windowed presentation restored", NSApp.presentationOptions == windowed,
              "0x" + String(NSApp.presentationOptions.rawValue, radix: 16))
    }

    /// Plain AppKit window in native fullscreen, FullPanelKit not involved: what does the
    /// NSApp.presentationOptions getter do after the setter, for the transitions FullPanel makes?
    private func presentationExperiment() async {
        let entry = AppKitWindows.open(role: .appkitControl)
        guard let window = entry.controller.window else { return }
        await sleep(0.8)
        await placeOnHousingScreen(window)
        guard await enterFullScreen(window, "presentation experiment") else { return }
        let hex = { (o: NSApplication.PresentationOptions) in "0x" + String(o.rawValue, radix: 16) }
        let native = NSApp.presentationOptions
        let forced: NSApplication.PresentationOptions = [.fullScreen, .hideDock, .hideMenuBar]
        var trials: [[String: Any]] = []
        let transitions: [(String, NSApplication.PresentationOptions, NSApplication.PresentationOptions)] = [
            ("native -> forced (what FullPanel does)", native, forced),
            ("forced -> 0x0 (the failing restore)", forced, []),
            ("forced -> FullScreen only", forced, [.fullScreen]),
            ("forced -> native", forced, native),
            ("native -> 0x0", native, []),
        ]
        for (name, from, to) in transitions {
            NSApp.presentationOptions = from
            await sleep(0.5)
            let start = hex(NSApp.presentationOptions)
            let startSystem = hex(NSApp.currentSystemPresentationOptions)
            NSApp.presentationOptions = to
            var samples: [[String: String]] = [["when": "immediately after setter",
                                                "app": hex(NSApp.presentationOptions),
                                                "system": hex(NSApp.currentSystemPresentationOptions)]]
            let began = Date()
            for delay in [0.0, 0.01, 0.05, 0.1, 0.3, 1.0] {
                await sleep(delay == 0 ? 0 : max(0, delay - Date().timeIntervalSince(began)))
                samples.append(["when": "+\(Int(Date().timeIntervalSince(began) * 1000)) ms",
                                "app": hex(NSApp.presentationOptions),
                                "system": hex(NSApp.currentSystemPresentationOptions)])
            }
            trials.append(["transition": name, "requestedFrom": hex(from), "startedAt": start,
                           "systemAtStart": startSystem, "requestedTo": hex(to), "samples": samples])
            NSLog("FullPanelAttachDemo autotest presentation experiment %@: start %@ requested %@ immediately %@ final %@",
                  name, start, hex(to), samples[0]["app"]!, samples.last!["app"]!)
        }
        NSApp.presentationOptions = native
        _ = await exitFullScreen(window, "presentation experiment")
        extraReport["presentationExperiment"] = ["nativeInFullscreen": hex(native), "trials": trials,
                                                 "afterExit": hex(NSApp.presentationOptions)]
        entry.controller.close()
        check("presentation experiment completed (informational)", true, "native \(hex(native))")
    }

    /// Re-attach after the detach probe: a new session must force and restore as before.
    private func reattachPresentationCycle(_ model: WindowModel, _ window: NSWindow) async {
        let windowed = NSApp.presentationOptions
        model.attach()
        guard let session = model.session else { check("re-attach after detach probe", false, model.lastError ?? ""); return }
        check("re-attach after detach probe: new enabled session", session.isAttached && session.isEnabled)
        await sleep(0.5)
        guard await enterFullScreen(window, "re-attach cycle") else { return }
        check("re-attach cycle: FullPanel active, presentation forced", session.state == .active
              && !NSApp.presentationOptions.isDisjoint(with: Self.forcedBits),
              "0x" + String(NSApp.presentationOptions.rawValue, radix: 16))
        _ = await exitFullScreen(window, "re-attach cycle")
        check("re-attach cycle exit: windowed presentation restored", NSApp.presentationOptions == windowed
              && session.state == .inactive, "0x" + String(NSApp.presentationOptions.rawValue, radix: 16))
    }

    private func cycleCue(_ label: String) -> String {
        label.hasSuffix("cycle1") ? "Click the small Space thumbnail at the top" : "Leave Mission Control, then swipe to the fullscreen Space"
    }

    /// One timeline sample while waiting in Mission Control.
    private func missionControlSample(_ window: NSWindow, _ session: FullPanelSession, _ started: Date) -> [String: Any] {
        let d = session.diagnostics()
        return ["t": (Date().timeIntervalSince(started) * 100).rounded() / 100,
                "onActiveSpace": window.isOnActiveSpace,
                "inFullScreen": window.styleMask.contains(.fullScreen),
                "isKey": window.isKeyWindow,
                "frame": NSStringFromRect(window.frame),
                "windowServer": windowServerBounds(window).map { NSStringFromRect($0) } ?? "none",
                "state": session.state.rawValue,
                "compositorState": jsonSafe(d["compositorState"] ?? "-"),
                "menuBarOverrideSubmitted": jsonSafe(d["menuBarOverrideSubmitted"] ?? "-")]
    }

    /// Opens Mission Control, tells the person what to select, waits (bounded) for the
    /// return and records the timeline. Returns nil on success, else a reason.
    private func missionControlReturn(_ window: NSWindow, label: String, instruction: String,
                                      session: FullPanelSession, screen: NSScreen) async -> String? {
        let timeout = defaults.object(forKey: "FullPanelAttachMissionControlTimeout") != nil
            ? defaults.double(forKey: "FullPanelAttachMissionControlTimeout") : 20
        var timeline: [[String: Any]] = []
        let started = Date()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        // Mission Control is open once our Space is no longer the active one.
        guard await poll(timeout: 6, { !window.isOnActiveSpace }) else {
            missionControlRuns.append(["label": label, "result": "Mission Control did not open", "timeline": timeline])
            return "Mission Control did not open (window still on the active Space)"
        }
        timeline.append(missionControlSample(window, session, started).merging(["event": "mission-control-open"]) { $1 })
        let prompt = "\(label): MANUAL STEP — in Mission Control, \(instruction) (waiting up to \(Int(timeout)) s)"
        NSLog("FullPanelAttachDemo autotest %@", prompt)
        FileHandle.standardError.write(Data(("\n>>> " + prompt + "\n\n").utf8))
        NSSound.beep()
        // Mission Control hides the window, so also say what to do.
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [cycleCue(label)]
        try? say.run()

        // Wait for the person; sample the whole time so the report shows what happened.
        var returnedAt: Date?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            timeline.append(missionControlSample(window, session, started))
            if returnProblems(window, session: session, screen: screen).isEmpty {
                returnedAt = returnedAt ?? Date()
                // Hold for the engine's own return check (<= 2 s polling) to finish.
                if Date().timeIntervalSince(returnedAt!) >= 2.5 { break }
            } else {
                returnedAt = nil
            }
            await sleep(0.25)
        }
        timeline.append(missionControlSample(window, session, started).merging(["event": "final"]) { $1 })
        let problems = returnProblems(window, session: session, screen: screen)
        missionControlRuns.append(["label": label, "instruction": instruction,
                                   "selectedAfterSeconds": returnedAt.map { $0.timeIntervalSince(started) } ?? NSNull(),
                                   "result": problems.isEmpty ? "returned" : problems.joined(separator: "; "),
                                   "timeline": timeline])
        manualTests.append("\(label) Mission Control return: MANUAL — \(instruction); "
                           + (problems.isEmpty ? "completed by the person in \(String(format: "%.1f", returnedAt!.timeIntervalSince(started))) s"
                                               : "NOT completed"))
        return problems.isEmpty ? nil : "no return within \(Int(timeout)) s: " + problems.joined(separator: "; ")
    }

    private func returnProblems(_ window: NSWindow, session: FullPanelSession, screen: NSScreen) -> [String] {
        var problems: [String] = []
        if !window.styleMask.contains(.fullScreen) { problems.append("not in native fullscreen") }
        if !window.isOnActiveSpace { problems.append("fullscreen Space not active") }
        if !covers(window) { problems.append("AppKit frame \(NSStringFromRect(window.frame))") }
        let ws = windowServerBounds(window)
        if ws.map({ $0.size == screen.frame.size && $0.origin == screen.frame.origin }) != true {
            problems.append("WindowServer bounds \(ws.map { NSStringFromRect($0) } ?? "none")")
        }
        if session.state != .active { problems.append("session \(session.state.rawValue)") }
        return problems
    }

    /// Synthesized click (NSApp.sendEvent) at a point in SwiftUI top-left content coordinates.
    private func click(_ window: NSWindow, topLeft point: CGPoint) {
        guard let content = window.contentView else { return }
        let local = content.isFlipped ? NSPoint(x: point.x, y: point.y)
                                      : NSPoint(x: point.x, y: content.bounds.height - point.y)
        let location = content.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func postMouseMoved(_ window: NSWindow) {
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: window.mouseLocationOutsideOfEventStream,
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Moves a window onto the display with the camera housing (others may be
    /// connected; FullPanel correctly falls back there).
    private func placeOnHousingScreen(_ window: NSWindow) async {
        guard let screen = FullPanelDisplayGeometry.screensWithCameraHousing().first,
              window.screen != screen else { return }
        let v = screen.visibleFrame
        let size = window.frame.size
        window.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        await sleep(0.4)
    }

    /// AppKit's own fullscreen presentation is allowed; FullPanel's forced
    /// "hide menu bar" must not remain.
    private var presentationNotForced: Bool {
        !NSApp.presentationOptions.contains(.hideMenuBar) && !NSApp.presentationOptions.contains(.hideDock)
    }

    private func covers(_ window: NSWindow) -> Bool {
        guard let screen = window.screen else { return false }
        return window.frame.equalTo(screen.frame)
    }

    /// WindowServer's own bounds for the window (public CoreGraphics).
    private func windowServerBounds(_ window: NSWindow) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                    CGWindowID(window.windowNumber)) as? [[String: Any]],
              let entry = info.first,
              let dict = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    // ---- Script ------------------------------------------------------------------

    func run() async {
        NSApp.activate(ignoringOtherApps: true)
        briefing()
        if cancelled { return finish() }
        if defaults.bool(forKey: "FullPanelAttachAppKitSubclassOnly") {
            await appKitSubclassOnly()
            skipped.append("everything except the AppKit subclass integration (-FullPanelAttachAppKitSubclassOnly)")
            return finish()
        }
        guard let a = await waitModel(.attached), let aw = a.window, let aSession = a.session else {
            check("attached window and session at launch", false)
            return finish()
        }
        await sleep(0.8)
        await placeOnHousingScreen(aw)
        let screen = aw.screen ?? NSScreen.main!
        let geometry = FullPanelDisplayGeometry(screen: screen)
        check("display has a camera housing", geometry.hasCameraHousing,
              "screen \(NSStringFromRect(screen.frame)) inset \(geometry.topInset)")
        let identity = ObjectIdentifier(aw)
        let delegateBefore = aw.delegate.map { ObjectIdentifier($0 as AnyObject) }
        let controllerBefore = aw.windowController.map(ObjectIdentifier.init)
        let windowedFrame = aw.frame
        let titlebarTransparentBefore = aw.titlebarAppearsTransparent
        check("SwiftUI window class kept", NSStringFromClass(type(of: aw).classForCoder()).contains("AppKitWindow"),
              NSStringFromClass(type(of: aw).classForCoder()))
        check("session attached and enabled", aSession.isAttached && aSession.isEnabled && aSession.state == .inactive)
        snapshot("launch", a)
        if defaults.bool(forKey: "FullPanelAttachPresentationExperiment") {
            await presentationExperiment()
            skipped.append("everything except the presentation experiment (-FullPanelAttachPresentationExperiment)")
            return finish()
        }
        if defaults.bool(forKey: "FullPanelAttachDetachOnly") {
            await detachPresentationProbe(a, aw, aSession)
            await reattachPresentationCycle(a, aw)
            skipped.append("everything except the detach presentation probe (-FullPanelAttachDetachOnly)")
            return finish()
        }

        // An ordinary SwiftUI window of the same class as the attached one.
        DemoRegistry.shared.openWindow?(SceneID.ordinary)
        guard let o = await waitModel(.ordinary), let ow = o.window else {
            check("ordinary window opened", false)
            return finish()
        }
        await sleep(0.8)
        await placeOnHousingScreen(ow)
        check("ordinary window has no session", FullPanelSession.session(for: ow) == nil)
        check("ordinary window is the same class", type(of: ow) == type(of: aw),
              NSStringFromClass(type(of: ow)))
        let ordinaryFrame = ow.frame

        // ---- FullPanel cycles with Mission Control ----
        for cycle in 1...2 {
            let label = "cycle\(cycle)"
            guard await enterFullScreen(aw, label) else { break }
            await phase("\(label)-fullpanel")
            snapshot("\(label) fullscreen", a)
            let ws = windowServerBounds(aw)
            check("\(label) state active", aSession.state == .active, aSession.state.rawValue)
            check("\(label) frame covers whole display", covers(aw),
                  "\(NSStringFromRect(aw.frame)) vs \(NSStringFromRect(screen.frame))")
            check("\(label) WindowServer bounds cover whole display",
                  ws.map { $0.size == screen.frame.size && $0.origin.y == 0 } ?? false,
                  ws.map { NSStringFromRect($0) } ?? "none")
            check("\(label) content view covers whole display",
                  aw.contentView?.bounds.size == screen.frame.size,
                  aw.contentView.map { NSStringFromRect($0.bounds) } ?? "none")
            check("\(label) menu-bar override submitted",
                  aSession.diagnostics()["menuBarOverrideSubmitted"] as? Bool == true)
            check("\(label) layout has both side areas",
                  a.layout.leftArea != nil && a.layout.rightArea != nil)
            check("\(label) window identity, delegate, controller unchanged",
                  ObjectIdentifier(aw) == identity
                  && aw.delegate.map { ObjectIdentifier($0 as AnyObject) } == delegateBefore
                  && aw.windowController.map(ObjectIdentifier.init) == controllerBefore)
            check("\(label) ordinary window untouched",
                  ow.frame == ordinaryFrame && !ow.styleMask.contains(.fullScreen)
                  && FullPanelSession.session(for: ow) == nil, NSStringFromRect(ow.frame))

            // Input beside the housing (synthesized, in-process).
            if let left = a.layout.leftArea, let right = a.layout.rightArea {
                let l0 = a.leftClicks, r0 = a.rightClicks
                click(aw, topLeft: CGPoint(x: left.midX, y: left.midY))
                click(aw, topLeft: CGPoint(x: right.midX, y: right.midY))
                await sleep(0.3)
                check("\(label) clicks reach both side areas",
                      a.leftClicks == l0 + 1 && a.rightClicks == r0 + 1,
                      "left \(a.leftClicks - l0) right \(a.rightClicks - r0)")
            }
            check("\(label) window is key in fullscreen", aw.isKeyWindow)

            if cycle == 1 && defaults.bool(forKey: "FullPanelAttachRevealProbe") {
                // Menu-bar reveal: put the real pointer at the top edge and
                // let the engine see a mouse-moved event.
                let saved = CGEvent(source: nil)?.location
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.minX + 200, y: 0))
                postMouseMoved(aw)
                await sleep(2.0)
                await phase("\(label)-reveal-top-edge")
                snapshot("\(label) pointer at top edge", a)
                let d = aSession.diagnostics()
                check("\(label) reveal allowed at top edge (engine)", d["revealAllowed"] as? Bool == true,
                      "menuBarRevealed=\(d["menuBarRevealed"] ?? "-") presentation=0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
                postMouseMoved(aw)
                await sleep(1.5)
                snapshot("\(label) pointer back in content", a)
                let d2 = aSession.diagnostics()
                check("\(label) reveal re-forced below band", d2["revealAllowed"] as? Bool == false
                      && d2["menuBarRevealed"] as? Bool == false, "\(d2["menuBarRevealed"] ?? "-")")
                if let saved { CGWarpMouseCursorPosition(saved) }
            }

            if missionControlEnabled {
                let instruction = cycle == 1
                    ? "click the fullscreen Space thumbnail for this window (top of the screen)"
                    : "leave Mission Control, then swipe (or Control-Left/Right) to this app's fullscreen Space"
                let failure = await missionControlReturn(aw, label: label, instruction: instruction,
                                                         session: aSession, screen: screen)
                await phase("\(label)-after-mission-control")
                snapshot("\(label) after Mission Control", a)
                check("\(label) Mission Control return: native fullscreen, Space active, frame and WindowServer cover display, session active",
                      failure == nil, failure ?? "")
                if let failure {
                    return finishAborted("\(label) Mission Control return failed (\(failure)). "
                        + "Later fullscreen tests were skipped; if Mission Control is still open, select the window or press Esc.")
                }
                check("\(label) Mission Control return: menu override submitted",
                      aSession.diagnostics()["menuBarOverrideSubmitted"] as? Bool == true)
                await requireNotchClick(a, label: label)
            }

            guard await exitFullScreen(aw, label) else { break }
            snapshot("\(label) exited", a)
            check("\(label) exit: state inactive", aSession.state == .inactive, aSession.state.rawValue)
            check("\(label) exit: windowed frame restored", aw.frame == windowedFrame,
                  "\(NSStringFromRect(aw.frame)) vs \(NSStringFromRect(windowedFrame))")
            check("\(label) exit: presentation options restored",
                  NSApp.presentationOptions == initialPresentation,
                  "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
            check("\(label) exit: menu override cleared",
                  aSession.diagnostics()["menuBarOverrideSubmitted"] as? Bool == false)
        }

        // ---- Ordinary window fullscreen: AppKit geometry only ----
        if await enterFullScreen(ow, "ordinary") {
            await phase("ordinary-fullscreen")
            snapshot("ordinary fullscreen", o)
            check("ordinary fullscreen gets AppKit's camera-safe frame, not FullPanel's",
                  !covers(ow) && ow.frame.height <= screen.frame.height - geometry.topInset,
                  NSStringFromRect(ow.frame))
            check("ordinary fullscreen did not touch the attached session",
                  aSession.state == .inactive && aSession.diagnostics()["armed"] as? Bool == false)
            _ = await exitFullScreen(ow, "ordinary")
            check("ordinary window frame restored", ow.frame == ordinaryFrame, NSStringFromRect(ow.frame))
        }

        // ---- Original API in the same process ----
        let legacy = LegacyWindow.open()
        await sleep(0.6)
        await placeOnHousingScreen(legacy)
        if await enterFullScreen(legacy, "legacy") {
            await phase("legacy-fullpanelwindow")
            check("FullPanelWindow still reaches FullPanel", legacy.fullPanelState == .active && covers(legacy),
                  "state \(legacy.fullPanelState.rawValue) frame \(NSStringFromRect(legacy.frame))")
            _ = await exitFullScreen(legacy, "legacy")
            check("FullPanelWindow exit restores", legacy.fullPanelState == .inactive
                  && NSApp.presentationOptions == initialPresentation)
        }
        LegacyWindow.close()
        await sleep(0.5)

        if defaults.bool(forKey: "FullPanelAttachMissionControlOnly") {
            skipped.append("everything after the Mission Control cycles (-FullPanelAttachMissionControlOnly)")
            return finish()
        }

        // ---- A second attached window ----
        DemoRegistry.shared.openWindow?(SceneID.fullPanel)
        weak var weakSecondSession: FullPanelSession?
        weak var weakSecondWindow: NSWindow?
        if let b = await waitModel(.attached, excluding: [a]), let bw = b.window, let bSession = b.session {
            weakSecondSession = bSession
            weakSecondWindow = bw
            check("second attached window has its own session", bSession !== aSession && bw !== aw)
            await sleep(0.6)
            await placeOnHousingScreen(bw)
            if await enterFullScreen(bw, "second") {
                await phase("second-attached-fullpanel")
                snapshot("second fullscreen", b)
                check("second window active", bSession.state == .active && covers(bw))
                check("first window unaffected", aSession.state == .inactive && aw.frame == windowedFrame)
                _ = await exitFullScreen(bw, "second")
                check("second window exit", bSession.state == .inactive)
            }
            // SwiftUI scene lifecycle: closing the window releases its session.
            bw.performClose(nil)
            await sleep(1.5)
        } else {
            check("second attached window opened", false)
        }
        check("closed window: session released or detached",
              weakSecondSession == nil || weakSecondSession?.isAttached == false,
              "session alive: \(weakSecondSession != nil) window deallocated: \(weakSecondWindow == nil)")

        // ---- Detach while fullscreen, then re-attach ----
        if await enterFullScreen(aw, "detach") {
            check("detach cycle active", aSession.state == .active)
            a.detach()
            await sleep(0.5)
            snapshot("detached in fullscreen", a)
            check("detach in fullscreen: session detached, state disabled",
                  !aSession.isAttached && aSession.state == .disabled && FullPanelSession.session(for: aw) == nil)
            check("detach in fullscreen: menu override cleared",
                  aSession.diagnostics()["menuBarOverrideSubmitted"] as? Bool == false)
            check("detach in fullscreen: FullPanel presentation released", presentationNotForced,
                  "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
            _ = await exitFullScreen(aw, "detach")
            check("after detached exit: windowed frame restored", aw.frame == windowedFrame,
                  NSStringFromRect(aw.frame))
            check("after detached exit: window style restored",
                  aw.titlebarAppearsTransparent == titlebarTransparentBefore)
        }
        a.attach()
        check("re-attach gives a new enabled session",
              a.session != nil && a.session !== aSession && a.session?.state == .inactive)
        check("same window after detach/re-attach", ObjectIdentifier(aw) == identity)
        await appKitBaseline(housingScreenWindow: aw)
        finish()
    }

    // ---- Ordinary AppKit NSWindow and KVO baseline --------------------------------

    /// Selector -> IMP for the methods an Objective-C class itself implements.
    private func methodTable(_ cls: AnyClass) -> [String: UnsafeRawPointer] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [:] }
        defer { free(list) }
        var table: [String: UnsafeRawPointer] = [:]
        for i in 0..<Int(count) {
            let method = list[i]
            table[NSStringFromSelector(method_getName(method))] = UnsafeRawPointer(method_getImplementation(method))
        }
        return table
    }

    private func sameTable(_ a: [String: UnsafeRawPointer], _ b: [String: UnsafeRawPointer]) -> Bool {
        a.count == b.count && a.allSatisfy { b[$0.key] == $0.value }
    }

    /// Methods of the classes from `cls` up to (not including) NSWindow whose
    /// implementation is a block trampoline (imp_implementationWithBlock), the
    /// way a runtime hook is installed. NSWindow itself has a few (AppKit's own).
    private func blockMethods(_ cls: AnyClass) -> [String] {
        var found: [String] = []
        var c: AnyClass? = cls
        while let current = c, current !== NSWindow.self {
            for (name, imp) in methodTable(current)
            where imp_getBlock(OpaquePointer(imp)) != nil {
                found.append("\(NSStringFromClass(current)) -\(name)")
            }
            c = class_getSuperclass(current)
        }
        return found.sorted()
    }

    /// Mutates each observed property on an unmodified window and records what
    /// the probe saw. Records only: which properties notify is not asserted.
    private func recordKVOBaseline(_ window: NSWindow, _ probe: KVOProbe) -> [String: Int] {
        var observed: [String: Int] = [:]
        func measure(_ key: String, _ change: () -> Void) {
            probe.resetCounts()
            change()
            observed[key] = probe.counts[key] ?? 0
        }
        let frame = window.frame
        measure("frame") { window.setFrame(frame.offsetBy(dx: 12, dy: -12), display: true) }
        window.setFrame(frame, display: true)
        let mask = window.styleMask
        measure("styleMask") { window.styleMask.formSymmetricDifference(.miniaturizable) }
        window.styleMask = mask
        let behavior = window.collectionBehavior
        measure("collectionBehavior") { window.collectionBehavior.formSymmetricDifference(.ignoresCycle) }
        window.collectionBehavior = behavior
        let content = window.contentView
        measure("contentView") { window.contentView = NSView() }
        window.contentView = content
        return observed
    }

    private func appKitBaseline(housingScreenWindow aw: NSWindow) async {
        await phase("appkit-nswindow")
        let nsWindowTableBefore = methodTable(NSWindow.self)

        AppKitWindows.openPair()
        guard let k = await waitModel(.appkit), let kw = k.window,
              let c = await waitModel(.appkitControl), let cw = c.window else {
            check("AppKit test and control windows opened", false)
            return
        }
        await sleep(0.8)
        let entry = AppKitWindows.entry(for: kw)
        let controlEntry = AppKitWindows.entry(for: cw)

        // Creation and identity.
        check("AppKit window is a genuine NSWindow", type(of: kw) == NSWindow.self && type(of: cw) == NSWindow.self,
              NSStringFromClass(type(of: kw)))
        check("AppKit window has an ordinary NSWindowController",
              kw.windowController === entry?.controller && type(of: kw.windowController!) == NSWindowController.self)
        check("AppKit window delegate is the ordinary delegate",
              kw.delegate === entry?.delegate && entry != nil)
        check("AppKit test and control windows are distinct", kw !== cw && entry?.delegate !== controlEntry?.delegate)
        let kwIdentity = ObjectIdentifier(kw)
        let delegateBefore = kw.delegate.map(ObjectIdentifier.init)
        let controllerBefore = kw.windowController.map(ObjectIdentifier.init)
        let runtimeClassBefore: AnyClass? = object_getClass(kw)
        let ncMethodsBefore = methodTable(NSWindow.self)
        check("NSWindow method table unchanged by the demo's setup", sameTable(nsWindowTableBefore, ncMethodsBefore))

        // Attachment is rejected, and says so.
        check("AppKit window: attach rejected (unsupported window class)",
              k.session == nil && k.lastErrorCode == FullPanelSessionError.unsupportedWindowClass.rawValue,
              "code \(k.lastErrorCode.map(String.init) ?? "nil"): \(k.lastError ?? "no error")")
        check("AppKit window: rejection names the AppKit class", k.lastError?.contains("AppKit class") == true,
              k.lastError ?? "")
        k.attach()
        check("AppKit window: second attach also rejected",
              k.session == nil && FullPanelSession.session(for: kw) == nil
              && k.lastErrorCode == FullPanelSessionError.unsupportedWindowClass.rawValue)
        check("control window never attached", c.session == nil && c.lastError == nil
              && FullPanelSession.session(for: cw) == nil)
        check("rejection left window, delegate, controller and class unchanged",
              ObjectIdentifier(kw) == kwIdentity
              && kw.delegate.map(ObjectIdentifier.init) == delegateBefore
              && kw.windowController.map(ObjectIdentifier.init) == controllerBefore
              && object_getClass(kw) == runtimeClassBefore)
        check("NSWindow method table unchanged by the rejected attach",
              sameTable(nsWindowTableBefore, methodTable(NSWindow.self)))
        snapshot("appkit rejected", k)
        snapshot("appkit control", c)

        // Existing SwiftUI and FullPanelWindow behavior is unaffected by AppKit windows.
        check("SwiftUI attached window still attached", a_isAttached(aw))
        let swiftUIBlocks = blockMethods(object_getClass(aw)!)
        check("SwiftUI window class has no installed method (nothing hooked)", swiftUIBlocks.isEmpty,
              swiftUIBlocks.joined(separator: ", "))

        // KVO baseline on an unmodified window, then on the control window.
        k.setKVO(true)
        c.setKVO(false)
        guard let probe = k.kvoProbe else { check("KVO probe created", false); return }
        check("KVO probe registered", probe.isObserving && probe.registrations == KVOProbe.keyPaths.count)
        let baseline = recordKVOBaseline(kw, probe)
        snapshot("appkit kvo baseline", k)
        NSLog("FullPanelAttachDemo autotest KVO baseline (public %@ runtime %@): %@",
              probe.publicClass, probe.runtimeClassAtStart, "\(baseline)")
        checks.append(["check": "KVO baseline recorded (informational)", "ok": true,
                       "detail": "\(baseline)", "kvoBaseline": baseline,
                       "publicClass": probe.publicClass, "runtimeClass": probe.runtimeClassAtStart])
        check("KVO probe left the window's delegate and controller alone",
              kw.delegate.map(ObjectIdentifier.init) == delegateBefore
              && kw.windowController.map(ObjectIdentifier.init) == controllerBefore)
        check("control window has no probe and kept its size", c.kvoProbe == nil && cw.frame.size.width == 800)

        // Observers come off on request, and stay off.
        probe.resetCounts()
        k.setKVO(false)
        check("KVO probe removed", !probe.isObserving && probe.removals == probe.registrations)
        kw.setFrame(kw.frame.offsetBy(dx: 5, dy: 0), display: true)
        kw.setFrame(kw.frame.offsetBy(dx: -5, dy: 0), display: true)
        check("no notifications after removal", probe.total == 0, "\(probe.counts)")
        k.setKVO(true)
        check("KVO probe can be restarted", probe.isObserving && probe.registrations == 2 * KVOProbe.keyPaths.count)

        // Fullscreen on an ordinary window is AppKit's own, with the probe and delegate running.
        await placeOnHousingScreen(kw)
        let fullscreenFrameBefore = kw.frame
        probe.resetCounts()
        if await enterFullScreen(kw, "appkit") {
            await phase("appkit-nswindow-fullscreen")
            snapshot("appkit fullscreen", k)
            check("AppKit window fullscreen is AppKit's (no FullPanel session)", k.session == nil)
            check("AppKit window fullscreen: delegate was called", (entry?.delegate.counts["didEnterFS"] ?? 0) >= 1,
                  entry?.delegate.summary ?? "")
            NSLog("FullPanelAttachDemo autotest KVO counts during fullscreen enter: %@", "\(probe.counts)")
            _ = await exitFullScreen(kw, "appkit")
            check("AppKit window fullscreen exit: delegate was called", (entry?.delegate.counts["didExitFS"] ?? 0) >= 1)
            check("AppKit window frame restored", kw.frame == fullscreenFrameBefore, NSStringFromRect(kw.frame))
        }
        check("control window stayed windowed and untouched", !cw.styleMask.contains(.fullScreen) && c.session == nil)

        // Closing removes the observers before the window can deallocate.
        let weakProbeWindow = probe.window
        check("KVO probe observing before close", probe.isObserving && weakProbeWindow != nil)
        entry?.controller.close()
        await sleep(0.3)
        check("KVO probe stopped at window close", !probe.isObserving && probe.removals == probe.registrations,
              probe.events.suffix(2).joined(separator: " | "))
        check("delegate saw willClose", (entry?.delegate.counts["willClose"] ?? 0) == 1)
        controlEntry?.controller.close()
        await sleep(0.3)

        // Repeated creation and release.
        var cycles = 0
        var releasedAll = true
        for _ in 0..<5 {
            weak var weakWindow: NSWindow?
            weak var weakController: NSWindowController?
            weak var weakDelegate: AppKitWindowDelegate?
            var probeStopped = false
            autoreleasepool {
                let e = AppKitWindows.open(role: .appkit)
                weakWindow = e.controller.window
                weakController = e.controller
                weakDelegate = e.delegate
                let p = KVOProbe(window: e.controller.window!)
                p.start()
                e.controller.close()
                probeStopped = !p.isObserving
            }
            await sleep(0.4)
            let released = await waitFor("AppKit window release", timeout: 4) {
                weakWindow == nil && weakController == nil && weakDelegate == nil
            }
            releasedAll = releasedAll && released && probeStopped
            cycles += 1
        }
        check("repeated AppKit window create/close/release (\(cycles)x): observers stopped, objects released",
              releasedAll)
        check("NSWindow method table unchanged at end",
              sameTable(nsWindowTableBefore, methodTable(NSWindow.self)))
        check("no AppKit test windows left open", AppKitWindows.entries.isEmpty,
              "\(AppKitWindows.entries.count)")
    }

    // ---- AppKit subclass integration ------------------------------------------------

    /// The supported AppKit path: the application's own NSWindow subclass, created as
    /// that class, with its own NSWindowController and delegate, and FullPanelSession
    /// attached. Same expectations as the SwiftUI cycles.
    private func appKitSubclassOnly() async {
        await phase("appkit-subclass")
        let nsWindowTable = methodTable(NSWindow.self)
        let subclassTable = methodTable(FullPanelAppKitDemoWindow.self)
        // The demo's SwiftUI scene windows are not part of this run. They close only
        // after the AppKit windows are open (the app quits with its last window).
        let sceneWindows = NSApp.windows.filter { $0.isVisible }
        let entry = AppKitWindows.open(role: .appkitSubclass)
        let controlEntry = AppKitWindows.open(role: .appkitControl)
        for w in sceneWindows { w.close() }
        guard let m = await waitModel(.appkitSubclass), let w = m.window,
              let c = await waitModel(.appkitControl), let cw = c.window else {
            check("AppKit subclass and control windows opened", false)
            return
        }
        await sleep(0.8)
        await placeOnHousingScreen(w)
        let screen = w.screen ?? NSScreen.main!
        check("display has a camera housing", FullPanelDisplayGeometry(screen: screen).hasCameraHousing,
              "screen \(NSStringFromRect(screen.frame))")

        // 1. Created as the subclass; FullPanelSession attached and enabled.
        check("window is the application's NSWindow subclass",
              w.isMember(of: FullPanelAppKitDemoWindow.self) && type(of: w) == FullPanelAppKitDemoWindow.self,
              NSStringFromClass(type(of: w)))
        guard let session = m.session else {
            check("FullPanelSession attached to the subclass window", false, m.lastError ?? "no session")
            return
        }
        check("FullPanelSession attached and enabled", session.isAttached && session.isEnabled
              && session.state == .inactive && FullPanelSession.session(for: w) === session)
        check("attaching modified neither the subclass nor NSWindow",
              sameTable(subclassTable, methodTable(FullPanelAppKitDemoWindow.self))
              && sameTable(nsWindowTable, methodTable(NSWindow.self))
              && blockMethods(FullPanelAppKitDemoWindow.self).isEmpty,
              blockMethods(FullPanelAppKitDemoWindow.self).joined(separator: ", "))
        let runtime: AnyClass = object_getClass(w)!
        // AppKit's own KVO may give the instance its NSKVONotifying_ subclass; FullPanelKit never changes it.
        check("runtime class is the subclass or AppKit's KVO subclass of it",
              runtime === FullPanelAppKitDemoWindow.self || class_getSuperclass(runtime) === FullPanelAppKitDemoWindow.self,
              NSStringFromClass(runtime))
        check("ordinary NSWindowController and delegate",
              w.windowController === entry.controller && type(of: entry.controller) == NSWindowController.self
              && w.delegate === entry.delegate)
        check("control window is a plain NSWindow, never attached",
              type(of: cw) == NSWindow.self && c.session == nil && c.lastError == nil
              && FullPanelSession.session(for: cw) == nil)
        let identity = ObjectIdentifier(w)
        let content = w.contentView
        let windowedFrame = w.frame
        let controlFrame = cw.frame
        let controlStyle = cw.styleMask
        func identityKept() -> Bool {
            ObjectIdentifier(w) == identity && w.windowController === entry.controller
                && w.delegate === entry.delegate && w.contentView === content
        }
        snapshot("subclass launch", m)

        for cycle in 1...2 {
            let label = "subclass-cycle\(cycle)"
            // 2. Native fullscreen.
            guard await enterFullScreen(w, label) else { return }
            await phase("\(label)-fullscreen")
            snapshot("\(label) fullscreen", m)
            // 3-4. Whole display: AppKit frame, WindowServer bounds, content view, both side areas.
            let ws = windowServerBounds(w)
            check("\(label) state active", session.state == .active, session.state.rawValue)
            check("\(label) frame covers whole display", covers(w),
                  "\(NSStringFromRect(w.frame)) vs \(NSStringFromRect(screen.frame))")
            check("\(label) WindowServer bounds cover whole display",
                  ws.map { $0.size == screen.frame.size && $0.origin.y == 0 } ?? false,
                  ws.map { NSStringFromRect($0) } ?? "none")
            check("\(label) content view covers whole display",
                  w.contentView?.bounds.size == screen.frame.size,
                  w.contentView.map { NSStringFromRect($0.bounds) } ?? "none")
            check("\(label) content reaches both side areas",
                  m.layout.leftArea != nil && m.layout.rightArea != nil,
                  "left \(m.layout.leftArea.map { NSStringFromRect($0) } ?? "nil") right \(m.layout.rightArea.map { NSStringFromRect($0) } ?? "nil")")
            check("\(label) menu-bar override submitted",
                  session.diagnostics()["menuBarOverrideSubmitted"] as? Bool == true)
            // 5. Clicks beside the housing (synthesized here; physical after Mission Control).
            if let left = m.layout.leftArea, let right = m.layout.rightArea {
                let l0 = m.leftClicks, r0 = m.rightClicks
                click(w, topLeft: CGPoint(x: left.midX, y: left.midY))
                click(w, topLeft: CGPoint(x: right.midX, y: right.midY))
                await sleep(0.3)
                check("\(label) clicks reach both side areas",
                      m.leftClicks == l0 + 1 && m.rightClicks == r0 + 1,
                      "left \(m.leftClicks - l0) right \(m.rightClicks - r0)")
            }
            check("\(label) delegate saw didEnterFullScreen",
                  (entry.delegate.counts["didEnterFS"] ?? 0) == cycle, entry.delegate.summary)
            check("\(label) control window untouched",
                  cw.frame == controlFrame && cw.styleMask == controlStyle && FullPanelSession.session(for: cw) == nil,
                  NSStringFromRect(cw.frame))

            // 6-8. Mission Control: cycle 1 Space thumbnail, cycle 2 swipe.
            if missionControlEnabled {
                let instruction = cycle == 1
                    ? "click the fullscreen Space thumbnail for this window (top of the screen)"
                    : "leave Mission Control, then swipe (or Control-Left/Right) to this app's fullscreen Space"
                let failure = await missionControlReturn(w, label: label, instruction: instruction,
                                                         session: session, screen: screen)
                await phase("\(label)-after-mission-control")
                snapshot("\(label) after Mission Control", m)
                check("\(label) Mission Control return: native fullscreen, Space active, frame and WindowServer cover display, session active",
                      failure == nil, failure ?? "")
                if let failure {
                    return finishAborted("\(label) Mission Control return failed (\(failure)). "
                        + "Later fullscreen tests were skipped; if Mission Control is still open, select the window or press Esc.")
                }
                check("\(label) after Mission Control: content view covers whole display, both side areas",
                      w.contentView?.bounds.size == screen.frame.size
                      && m.layout.leftArea != nil && m.layout.rightArea != nil)
                check("\(label) after Mission Control: menu override submitted",
                      session.diagnostics()["menuBarOverrideSubmitted"] as? Bool == true)
                await requireNotchClick(m, label: label)
            }

            // 9. Exit: windowed frame and presentation options.
            guard await exitFullScreen(w, label) else { return }
            snapshot("\(label) exited", m)
            check("\(label) exit: state inactive", session.state == .inactive, session.state.rawValue)
            check("\(label) exit: windowed frame restored", w.frame == windowedFrame,
                  "\(NSStringFromRect(w.frame)) vs \(NSStringFromRect(windowedFrame))")
            check("\(label) exit: presentation options restored",
                  NSApp.presentationOptions == initialPresentation,
                  "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
            check("\(label) exit: menu override cleared",
                  session.diagnostics()["menuBarOverrideSubmitted"] as? Bool == false)
            check("\(label) delegate saw didExitFullScreen",
                  (entry.delegate.counts["didExitFS"] ?? 0) == cycle, entry.delegate.summary)
            // 10. Identity.
            check("\(label) window identity, delegate, controller and content view unchanged", identityKept())
        }

        // 11. Detach and re-attach.
        m.detach()
        check("detach: session detached and disabled, no session for the window",
              !session.isAttached && session.state == .disabled && FullPanelSession.session(for: w) == nil)
        check("detach: lifecycle observers removed", session.diagnostics()["lifecycleObservers"] as? Int == 0)
        // The window was created with a standard titlebar (AppKitWindows.open).
        check("detach: window style restored", !w.styleMask.contains(.fullSizeContentView)
              && !w.titlebarAppearsTransparent,
              "fullSize \(w.styleMask.contains(.fullSizeContentView)) transparent \(w.titlebarAppearsTransparent)")
        check("detach: identity, delegate, controller, content view unchanged", identityKept())
        m.attach()
        guard let again = m.session else { check("re-attach", false, m.lastError ?? ""); return }
        check("re-attach gives a new enabled session", again !== session && again.isAttached
              && again.isEnabled && again.state == .inactive)
        if await enterFullScreen(w, "subclass-reattach") {
            snapshot("subclass re-attach fullscreen", m)
            check("re-attach: active and covering the whole display", again.state == .active && covers(w),
                  NSStringFromRect(w.frame))
            _ = await exitFullScreen(w, "subclass-reattach")
            check("re-attach exit: windowed frame and presentation restored",
                  w.frame == windowedFrame && NSApp.presentationOptions == initialPresentation
                  && again.state == .inactive, NSStringFromRect(w.frame))
        }
        check("after re-attach: identity, delegate, controller, content view unchanged", identityKept())

        // 12. Unrelated windows.
        check("control window untouched at end",
              cw.frame == controlFrame && cw.styleMask == controlStyle && !cw.styleMask.contains(.fullScreen)
              && FullPanelSession.session(for: cw) == nil && (controlEntry.delegate.counts["didEnterFS"] ?? 0) == 0,
              controlEntry.delegate.summary)
        check("NSWindow method table unchanged at end", sameTable(nsWindowTable, methodTable(NSWindow.self)))
        check("subclass method table unchanged at end (fullscreen cycles, detach, re-attach)",
              sameTable(subclassTable, methodTable(FullPanelAppKitDemoWindow.self)))
        snapshot("subclass end", m)
        snapshot("control end", c)

        // Close (the control window stays open until the report is written).
        entry.controller.close()
        await sleep(0.5)
        check("close: system state restored, session stays attached (window may be shown again)",
              NSApp.presentationOptions == initialPresentation && again.isAttached
              && again.diagnostics()["menuBarOverrideSubmitted"] as? Bool == false,
              "0x\(String(NSApp.presentationOptions.rawValue, radix: 16))")
    }

    private func a_isAttached(_ window: NSWindow) -> Bool {
        FullPanelSession.session(for: window)?.isAttached == true
    }

    /// A step that later tests depend on failed: report it and stop, rather than
    /// letting every following fullscreen test fail for the same reason.
    private func finishAborted(_ reason: String) {
        skipped.append("aborted: " + reason)
        NSLog("FullPanelAttachDemo autotest ABORTED %@", reason)
        finish()
    }

    private func finish() {
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "passed": failures.isEmpty,
            "failures": failures,
            "skipped": skipped,
            "manualTests": manualTests,
            "missionControl": missionControlRuns,
            "detachPresentation": extraReport["detachPresentation"] ?? NSNull(),
            "presentationExperiment": extraReport["presentationExperiment"] ?? NSNull(),
            "checks": checks,
            "snapshots": snapshots,
            "note": "Synthesized events and AppKit/WindowServer state only. Physical pixels, menu-bar transparency and physical input need the screenshots and a person."
        ]
        let path = defaults.string(forKey: "FullPanelAttachReport")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Downloads/FullPanelAttachDemo-autotest.json")
        // The named file is always the latest run; a timestamped copy next to it keeps every run.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let archive = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent
                                    + "-" + stamp.string(from: Date()) + "." + url.pathExtension)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
            try? data.write(to: archive)
        }
        NSLog("FullPanelAttachDemo autotest done: %@ (%d checks, %d failures) -> %@ (copy: %@)",
              failures.isEmpty ? "PASS" : "FAIL", checks.count, failures.count, path, archive.path)
        if let phasePath = defaults.string(forKey: "FullPanelAttachPhaseFile") {
            try? "done".write(toFile: phasePath, atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}
