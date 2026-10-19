// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// SpacesLab: one window, one mode, a log line per lifecycle event.
//
//   -mode control | session | fpwindow | plain   (default session)
//         control: an NSWindow subclass in native fullscreen, nothing attached
//         session: the same class with FullPanelSession attached and enabled
//         fpwindow: FullPanelWindow with fullPanelEnabled
//         plain:   a plain NSWindow (used for the "other application")
//   -tag <name>      command channel and window title suffix (default: mode)
//   -log <path>      event log (default /tmp/SpacesLab-<tag>.log)
//   -screen builtin | external   where the window opens (default builtin)
//   -autoFS YES      enter fullscreen after launch
//   -attachAt willEnter   session mode: attach and enable FullPanelSession
//                    inside the window's first willEnterFullScreen (an entry
//                    the engine is not told about), not at launch
//   -second control | session   a second window in the same process: an
//                    unattached window of the same class in native
//                    fullscreen, or another attached window
//   -interceptReservation YES   before anything attaches, replace AppKit's
//                    -reservesSpaceForMenuBarInFullScreen with a pass-through
//                    (another library that got there first; gate 1)
//
// Commands (spacesctl cmd <tag> <command>): dump, enter, exit, front, close,
// detach, disable, quit, diag; enter2, exit2, front2, diag2 for the second
// window; tileLeft (AppKit's "tile to the left of the screen", the Split View
// entry), join2:<position> (the second window joins the first's tile Space).
// Sleep, wake, screen lock and unlock are logged as EV lines.

import AppKit
import FullPanelKit

final class LabWindow: NSWindow {}

// ---- SkyLight, read-only -------------------------------------------------------

private typealias MainConnFn = @convention(c) () -> Int32
private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias SpaceTypeFn = @convention(c) (Int32, UInt64) -> Int32
private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let slsMain = unsafeBitCast(dlsym(sky, "SLSMainConnectionID"), to: MainConnFn.self)
private let slsSpacesForWindows = unsafeBitCast(dlsym(sky, "SLSCopySpacesForWindows"), to: SpacesForWindowsFn.self)
private let slsSpaceType = unsafeBitCast(dlsym(sky, "SLSSpaceGetType"), to: SpaceTypeFn.self)

private func spaces(of w: NSWindow) -> String {
    guard w.windowNumber > 0,
          let ids = slsSpacesForWindows(slsMain(), 7, [w.windowNumber] as CFArray)?.takeRetainedValue() as? [NSNumber]
    else { return "-" }
    return ids.map { "\($0.uint64Value)/t\(slsSpaceType(slsMain(), $0.uint64Value))" }.joined(separator: ",")
}

private func displayID(_ s: NSScreen?) -> String {
    guard let s else { return "nil" }
    let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? -1
    return "\(n)\(s.safeAreaInsets.top > 0 ? "/housing" : "")"
}

// ---- Log --------------------------------------------------------------------------

let defaults = UserDefaults.standard
let mode = defaults.string(forKey: "mode") ?? "session"
let tag = defaults.string(forKey: "tag") ?? mode
let logPath = defaults.string(forKey: "log") ?? "/tmp/SpacesLab-\(tag).log"
let start = ProcessInfo.processInfo.systemUptime
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath)

func log(_ s: String) {
    let line = String(format: "%9.1f ", (ProcessInfo.processInfo.systemUptime - start) * 1000) + s + "\n"
    logHandle?.seekToEndOfFile()
    logHandle?.write(Data(line.utf8))
}

func describe(_ w: NSWindow) -> String {
    let hex = { (v: UInt) in "0x" + String(v, radix: 16) }
    return "[\(NSStringFromClass(type(of: w))) #\(w.windowNumber) scr=\(displayID(w.screen)) fr=\(NSStringFromRect(w.frame)) "
        + "sm=\(hex(w.styleMask.rawValue)) cb=\(hex(w.collectionBehavior.rawValue)) vis=\(w.isVisible ? 1 : 0) "
        + "occ=\(w.occlusionState.contains(.visible) ? 1 : 0) onAS=\(w.isOnActiveSpace ? 1 : 0) "
        + "key=\(w.isKeyWindow ? 1 : 0) main=\(w.isMainWindow ? 1 : 0) sp=\(spaces(of: w))]"
}

var window: NSWindow?
var session: FullPanelSession?
var window2: NSWindow?
var session2: FullPanelSession?

func dump(_ why: String) {
    var s = "\(why) active=\(NSApp.isActive ? 1 : 0) pres=0x\(String(NSApp.presentationOptions.rawValue, radix: 16))"
    guard let w = window else { log(s + " W=nil"); return }
    s += " W=" + describe(w)
    if let d = session?.diagnostics() ?? (w as? FullPanelWindow)?.fullPanelDiagnostics() {
        s += " fp{state=\(d["state"] ?? "") reason=\(d["fallbackReason"] ?? "") armed=\(d["armed"] ?? "") "
            + "sub=\(d["menuBarOverrideSubmitted"] ?? "") reveal=\(d["revealActive"] ?? "") "
            + "released=\(d["screenReleased"] ?? "") switchOnActivate=\(d["spacesSwitchOnActivate"] ?? "")}"
    }
    log(s)
}

// ---- App --------------------------------------------------------------------------

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let wantHousing = (defaults.string(forKey: "screen") ?? "builtin") == "builtin"
        let screen = NSScreen.screens.first { ($0.safeAreaInsets.top > 0) == wantHousing } ?? NSScreen.main!
        let rect = NSRect(x: screen.visibleFrame.midX - 400, y: screen.visibleFrame.midY - 250, width: 800, height: 500)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let w: NSWindow
        switch mode {
        case "fpwindow":
            let fw = FullPanelWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            fw.fullPanelEnabled = true
            w = fw
        case "plain":
            w = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        default:
            w = LabWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        }
        w.isReleasedWhenClosed = false
        w.title = "SpacesLab \(tag)"
        w.collectionBehavior.insert(.fullScreenPrimary)
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = (mode == "plain" ? NSColor.systemOrange : NSColor.systemTeal).cgColor
        w.contentView = content
        if mode == "control" {   // the style FullPanel would apply, without FullPanel
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
        }
        window = w
        if defaults.bool(forKey: "interceptReservation") { interceptReservation() }
        if mode == "session" && defaults.string(forKey: "attachAt") == "willEnter" {
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: w, queue: nil) { _ in
                MainActor.assumeIsolated {
                    if session == nil {
                        session = try? FullPanelSession.attach(to: w)
                        session?.isEnabled = true
                        dump("ATTACHED inside willEnterFullScreen")
                    }
                }
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        } else if mode == "session" {
            session = try? FullPanelSession.attach(to: w)
            session?.isEnabled = true
        }
        if let kind = defaults.string(forKey: "second") {
            let w2 = LabWindow(contentRect: rect.offsetBy(dx: 60, dy: -60), styleMask: style,
                               backing: .buffered, defer: false)
            w2.isReleasedWhenClosed = false
            w2.title = "SpacesLab \(tag)-2"
            w2.collectionBehavior.insert(.fullScreenPrimary)
            let c2 = NSView()
            c2.wantsLayer = true
            c2.layer?.backgroundColor = NSColor.systemTeal.cgColor
            w2.contentView = c2
            if kind == "session" {
                session2 = try? FullPanelSession.attach(to: w2)
                session2?.isEnabled = true
            } else {   // as in control mode: FullPanel's style, without FullPanel
                w2.styleMask.insert(.fullSizeContentView)
                w2.titlebarAppearsTransparent = true
            }
            window2 = w2
            w2.orderFront(nil)
        }
        w.setFrame(rect, display: false)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        observeEvents()
        dump("launched")
        if defaults.bool(forKey: "autoFS") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { w.toggleFullScreen(nil) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("SpacesLab.cmd.\(tag)"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(command) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dump("EV reopen hasVisibleWindows=\(flag)")
        return true
    }
}

// Another library's replacement of the menu-bar reservation method that only
// calls AppKit's implementation.
func interceptReservation() {
    let sel = NSSelectorFromString("reservesSpaceForMenuBarInFullScreen")
    guard let cls = NSClassFromString("_NSFullScreenContentController"),
          let m = class_getInstanceMethod(cls, sel) else { log("INTERCEPT unavailable"); return }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    let original = unsafeBitCast(method_getImplementation(m), to: Getter.self)
    let block: @convention(block) (AnyObject) -> Bool = { original($0, sel) }
    method_setImplementation(m, imp_implementationWithBlock(block))
    log("INTERCEPT reservation replaced before attach")
}

func observeEvents() {
    let names: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
        NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
        NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
        NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
        NSWindow.willCloseNotification,
        NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        NSApplication.didChangeScreenParametersNotification,
    ]
    for name in names {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                if let w = note.object as? NSWindow, w !== window {
                    log("EV \(name.rawValue) aux=\(describe(w))")
                } else {
                    dump("EV \(name.rawValue)")
                }
            }
        }
    }
    for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification,
                 NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification,
                 NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidResignActiveNotification,
                 NSWorkspace.sessionDidBecomeActiveNotification] {
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { dump("EV \(name.rawValue)") }
        }
    }
    for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { dump("EV \(name)") }
        }
    }
}

// join2:auto: the position AppKit prefers for the second window.
@MainActor func preferredJoinPosition() -> UInt64? {
    guard let w = window2, let m = class_getInstanceMethod(type(of: w), NSSelectorFromString("_preferredPositionForTileJoin")),
          String(cString: method_getTypeEncoding(m)!) == "Q16@0:8" else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector) -> UInt64
    return unsafeBitCast(method_getImplementation(m), to: Fn.self)(w, NSSelectorFromString("_preferredPositionForTileJoin"))
}

// AppKit's private tile actions (macOS 27.0.1 encodings checked before use).
@MainActor func tile(_ command: String) {
    func method(_ w: NSWindow?, _ name: String, _ types: String) -> IMP? {
        guard let w, let m = class_getInstanceMethod(type(of: w), NSSelectorFromString(name)),
              String(cString: method_getTypeEncoding(m)!) == types else {
            log("TILE \(name) unavailable"); return nil
        }
        return method_getImplementation(m)
    }
    if command == "tileLeft", let imp = method(window, "_tileLeft:", "v24@0:8@16") {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(imp, to: Fn.self)(window!, NSSelectorFromString("_tileLeft:"), nil)
    } else if command.hasPrefix("join2:"),
              let position = UInt64(command.dropFirst(6)) ?? preferredJoinPosition(),
              let spaceIMP = method(window, "_tileSpaceID", "Q16@0:8"),
              let joinIMP = method(window2, "_joinTiledFullScreenSpace:usingPosition:", "B32@0:8Q16Q24") {
        typealias SpaceFn = @convention(c) (AnyObject, Selector) -> UInt64
        typealias JoinFn = @convention(c) (AnyObject, Selector, UInt64, UInt64) -> Bool
        let space = unsafeBitCast(spaceIMP, to: SpaceFn.self)(window!, NSSelectorFromString("_tileSpaceID"))
        let ok = unsafeBitCast(joinIMP, to: JoinFn.self)(
            window2!, NSSelectorFromString("_joinTiledFullScreenSpace:usingPosition:"), space, position)
        log("TILE join2 space=\(space) position=\(position) ok=\(ok)")
    } else if command.hasPrefix("sibling2:"), let positions = UInt64(command.dropFirst(9)),
              let imp = method(window, "_createSiblingTileForWindow:preferredPositions:responseHandler:",
                               "v40@0:8@16Q24@?32") {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, UInt64, AnyObject) -> Void
        let handler: @convention(block) (Int) -> Void = { r in log("TILE sibling2 response=\(r)") }
        unsafeBitCast(imp, to: Fn.self)(window!, NSSelectorFromString("_createSiblingTileForWindow:preferredPositions:responseHandler:"),
                                        window2!, positions, handler as AnyObject)
        log("TILE sibling2 requested positions=\(positions)")
    }
}

@MainActor func handle(_ command: String) {
    log("CMD \(command)")
    switch command {
    case "enter", "exit": window?.toggleFullScreen(nil)
    case "front": window?.makeKeyAndOrderFront(nil)
    case "close": window?.close()
    case "detach": session?.detach()
    case "disable":
        session?.isEnabled = false
        (window as? FullPanelWindow)?.fullPanelEnabled = false
    case "quit": NSApp.terminate(nil)
    case "enter2", "exit2": window2?.toggleFullScreen(nil)
    case "front2": window2?.makeKeyAndOrderFront(nil)
    case let c where c == "tileLeft" || c.hasPrefix("join2:") || c.hasPrefix("sibling2:"): tile(c)
    case "diag", "diag2":
        // One JSON line: the FullPanel engine's diagnostics (none for an
        // unattached window) plus the window's own geometry and screen count.
        let w = command == "diag" ? window : window2
        let s = command == "diag" ? session : session2
        var d = s?.diagnostics() ?? (w as? FullPanelWindow)?.fullPanelDiagnostics() ?? [:]
        d["screenCount"] = NSScreen.screens.count
        d["styleMaskRaw"] = w?.styleMask.rawValue ?? 0
        d["sessionAttached"] = s?.isAttached ?? false
        if let w {
            let r = { (r: NSRect) in ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
            d["labWindowFrame"] = r(w.frame)
            d["labScreenFrame"] = w.screen.map { r($0.frame) } ?? [:]
            d["labFullScreen"] = w.styleMask.contains(.fullScreen)
            d["labKey"] = w.isKeyWindow
            d["labOnActiveSpace"] = w.isOnActiveSpace
        }
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            log((command == "diag" ? "DIAG " : "DIAG2 ") + json)
        } else {
            log("DIAG unserializable")
        }
    default: break
    }
    dump("after \(command)")
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let windowItem = NSMenuItem()
mainMenu.addItem(windowItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                   keyEquivalent: "f").keyEquivalentModifierMask = [.control, .command]
windowItem.submenu = windowMenu
app.mainMenu = mainMenu
app.windowsMenu = windowMenu
app.run()
