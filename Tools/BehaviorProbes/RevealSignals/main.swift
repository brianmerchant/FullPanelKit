// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Black-box probe: which public signals change when the menu bar is revealed
// over a native fullscreen window? Uses no FullPanelKit code and no private
// API. Ground truth is WindowServer's own menu-bar window (layer 24) as
// CGWindowList reports it. Every candidate signal is logged with a timestamp
// so its timing can be compared with the ground truth.
//
//   swiftc -O main.swift -o reveal-signals && ./reveal-signals [--toolbar] [--drive]
//
// --toolbar  give the window an NSToolbar (otherwise a plain titled window)
// --drive    after entering fullscreen, post HID mouse-moved events to the top
//            edge and back (tests whether synthetic movement reveals at all)
// --gate     scripted: hold the pointer at the top edge while presentation
//            options hide the menu bar, then allow auto-hide, then move down;
//            captures the top of the screen after each step (needs Screen
//            Recording). Tests whether the signals hold under gating.

import AppKit
import Carbon

let args = Set(CommandLine.arguments.dropFirst())
let start = Date()
func log(_ s: String) {
    let t = String(format: "%8.3f", Date().timeIntervalSince(start))
    print("\(t) \(s)")
    fflush(stdout)
}

func describe(_ r: NSRect) -> String {
    String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
}

// Ground truth: WindowServer-owned windows on the main-menu layer.
func menuBarTruth() -> String {
    guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    else { return "-" }
    var parts: [String] = []
    for e in info {
        let layer = e[kCGWindowLayer as String] as? Int ?? 0
        let owner = e[kCGWindowOwnerName as String] as? String ?? ""
        guard layer == Int(CGWindowLevelForKey(.mainMenuWindow)), owner == "Window Server" else { continue }
        var b = CGRect.zero
        if let d = e[kCGWindowBounds as String] as! CFDictionary? { CGRectMakeWithDictionaryRepresentation(d, &b) }
        let a = e[kCGWindowAlpha as String] as? Double ?? -1
        parts.append(String(format: "y=%.0f h=%.0f a=%.2f", b.minY, b.height, a))
    }
    return parts.isEmpty ? "none" : parts.joined(separator: " | ")
}

final class Probe: NSObject, NSWindowDelegate {
    var window: NSWindow!
    var last: [String: String] = [:]

    func change(_ key: String, _ value: String) {
        if last[key] == value { return }
        last[key] = value
        log("\(key): \(value)")
    }

    func run() {
        let screen = NSScreen.main!
        log("screen \(describe(screen.frame)) safeTop=\(screen.safeAreaInsets.top) visible=\(describe(screen.visibleFrame))")
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "RevealSignals"
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.systemTeal.cgColor
        window.contentView = content
        if args.contains("--toolbar") {
            let tb = NSToolbar(identifier: "probe")
            window.toolbar = tb
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let w = note.object as? NSWindow, w !== self.window else { return }
                let occ = w.occlusionState.contains(.visible)
                log("note \(name.rawValue.replacingOccurrences(of: "NSWindow", with: "")) " +
                    "\(type(of: w)) #\(w.windowNumber) frame=\(describe(w.frame)) occVisible=\(occ) visible=\(w.isVisible)")
            }
        }
        NSApp.addObserver(self, forKeyPath: "currentSystemPresentationOptions", options: [.new], context: nil)
        installCarbonMenuBarHandler()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.window.toggleFullScreen(nil) }
        // Ground-truth and polled-signal sampler (probe only).
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in self?.sample() }
    }

    func sample() {
        change("truth.menubar", menuBarTruth())
        change("NSMenu.menuBarVisible", "\(NSMenu.menuBarVisible())")
        let others = NSApp.windows.filter { $0 !== window }.map {
            "\(type(of: $0))#\($0.windowNumber) \(describe($0.frame)) vis=\($0.isVisible) occ=\($0.occlusionState.contains(.visible)) a=\($0.alphaValue) lvl=\($0.level.rawValue)"
        }
        change("appWindows", others.joined(separator: " ; "))
        change("main.frame", describe(window.frame))
        change("pointer", String(format: "y=%.3f", NSEvent.mouseLocation.y))
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        log(String(format: "kvo currentSystemPresentationOptions=0x%lx app=0x%lx",
                   NSApp.currentSystemPresentationOptions.rawValue, NSApp.presentationOptions.rawValue))
    }

    func installCarbonMenuBarHandler() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassMenu), eventKind: UInt32(kEventMenuBarShown)),
                     EventTypeSpec(eventClass: OSType(kEventClassMenu), eventKind: UInt32(kEventMenuBarHidden))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let kind = GetEventKind(event)
            log("carbon \(kind == UInt32(kEventMenuBarShown) ? "MenuBarShown" : "MenuBarHidden")")
            return OSStatus(eventNotHandledErr)
        }, 2, &specs, nil, nil)
        log("carbon handler status=\(status)")
    }

    var alphaObservations: [NSKeyValueObservation] = []
    func observeTitlebarAlpha() {
        for w in NSApp.windows where w !== window && "\(type(of: w))" == "NSToolbarFullScreenWindow" {
            alphaObservations.append(w.observe(\.alphaValue, options: [.new]) { w, _ in
                log("kvo titlebar alphaValue=\(w.alphaValue) frame=\(describe(w.frame))")
            })
            log("observing titlebar #\(w.windowNumber) alpha parent=\(w.parent.map { "#\($0.windowNumber)" } ?? "nil") " +
                "children=\(w.childWindows?.map { "#\($0.windowNumber)" } ?? []) mainChildren=\(window.childWindows?.map { "#\($0.windowNumber)" } ?? []) " +
                "mainParent=\(window.parent.map { "#\($0.windowNumber)" } ?? "nil") main=#\(window.windowNumber) " +
                "tabbedWindows=\(w.tabbedWindows?.count ?? -1) screenSame=\(w.screen == window.screen) level=\(w.level.rawValue)/\(window.level.rawValue)")
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        log("didEnterFullScreen frame=\(describe(window.frame))")
        observeTitlebarAlpha()
        if args.contains("--gate") { gate(); return }
        guard args.contains("--drive") else {
            log("READY: move the pointer to the very top edge, wait for the menu bar, then move it back down. Repeat 2-3 times.")
            return
        }
        DispatchQueue.global().async {
            let s = NSScreen.main!.frame
            func move(_ y: CGFloat) {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: CGPoint(x: s.midX - 300, y: y), mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
            for cycle in 1...2 {
                DispatchQueue.main.async { log("drive: cycle \(cycle) up") }
                for y in stride(from: 300.0, through: 0.0, by: -20.0) { move(y); usleep(16_000) }
                for _ in 0..<60 { move(0); usleep(33_000) }
                DispatchQueue.main.async { log("drive: cycle \(cycle) down") }
                for y in stride(from: 0.0, through: 400.0, by: 20.0) { move(y); usleep(16_000) }
                usleep(1_500_000)
            }
            DispatchQueue.main.async { log("drive: done") }
        }
    }
    func gate() {
        let outDir = ProcessInfo.processInfo.environment["PROBE_OUT"] ?? "."
        let forced: NSApplication.PresentationOptions = [.fullScreen, .hideMenuBar, .hideDock]
        let revealable: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]
        func setOptions(_ o: NSApplication.PresentationOptions, _ why: String) {
            DispatchQueue.main.sync {
                NSApp.presentationOptions = o
                log(String(format: "gate: %@ requested=0x%lx readback=0x%lx", why, o.rawValue, NSApp.presentationOptions.rawValue))
            }
        }
        DispatchQueue.global().async {
            let s = NSScreen.main!.frame
            func move(_ y: CGFloat) {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: CGPoint(x: s.midX - 300, y: y), mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
            func hold(_ y: CGFloat, _ seconds: Double) {
                for _ in 0..<Int(seconds / 0.033) { move(y); usleep(33_000) }
            }
            func capture(_ name: String) {
                let task = Process()
                task.launchPath = "/usr/sbin/screencapture"
                task.arguments = ["-x", "-R0,0,\(Int(s.width)),60", "\(outDir)/\(name).png"]
                try? task.run(); task.waitUntilExit()
                DispatchQueue.main.async { log("gate: captured \(name) menuBarVisible=\(NSMenu.menuBarVisible())") }
            }
            hold(400, 0.5)
            for cycle in 1...2 {
                setOptions(forced, "forced (cycle \(cycle))")
                hold(400, 0.6)
                DispatchQueue.main.async { log("gate: pointer to top edge, still forced") }
                for y in stride(from: 300.0, through: 0.0, by: -20.0) { move(y); usleep(16_000) }
                hold(0, 1.5)
                capture("gate-c\(cycle)-1-forced-top")
                setOptions(revealable, "revealable at top edge")
                hold(0, 1.5)
                capture("gate-c\(cycle)-2-revealable-top")
                DispatchQueue.main.async { log("gate: pointer down") }
                for y in stride(from: 0.0, through: 400.0, by: 20.0) { move(y); usleep(16_000) }
                hold(400, 1.2)
                capture("gate-c\(cycle)-3-down")
            }
            setOptions(forced, "forced (end)")
            hold(400, 0.5)
            DispatchQueue.main.async { log("gate: done") }
        }
    }
    func windowDidExitFullScreen(_ notification: Notification) { log("didExitFullScreen") }
    // Entry ordering: which callbacks precede AppKit's first frame decision.
    func windowWillEnterFullScreen(_ notification: Notification) {
        log("order: willEnterFullScreen styleHasFullScreen=\(window.styleMask.contains(.fullScreen))")
    }
    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
        log("order: willUseFullScreenContentSize \(proposedSize) styleHasFullScreen=\(window.styleMask.contains(.fullScreen))")
        return proposedSize
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        log(String(format: "order: willUseFullScreenPresentationOptions proposed=0x%lx", proposedOptions.rawValue))
        return proposedOptions
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// A visible main menu, so a revealed menu bar is distinguishable in captures.
let mainMenu = NSMenu()
for title in ["RevealSignals", "ProbeFile", "ProbeEdit", "ProbeView", "ProbeWindow"] {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = NSMenu(title: title)
    item.submenu?.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    mainMenu.addItem(item)
}
app.mainMenu = mainMenu
let probe = Probe()
probe.run()
DispatchQueue.main.asyncAfter(deadline: .now() + (args.contains("--drive") ? 14 : args.contains("--gate") ? 22 : 40)) {
    log("exiting")
    probe.window.toggleFullScreen(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
}
app.run()
