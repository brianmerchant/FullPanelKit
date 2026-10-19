// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// spacesctl: drives the real system UI and reads WindowServer state.
// Needs Accessibility (key and mouse events, Dock press) and Screen Recording
// (shot) for the launching terminal. Changes no setting.
//
//   cmd <tag> <command>        SpacesLab remote command
//   cmdtab [n]                 Command-Tab, n Tab presses (default 1: the previous application)
//   key <code> [ctrl|cmd|opt|fn]...
//   dock <title>               press the Dock item (a Dock click)
//   front                      frontmost application
//   space <pid>                display of the pid's fullscreen Space, whether it is shown,
//                              and its place in that display's Spaces bar
//   shot <prefix>              capture each display; prints its non-black fraction
//   band [prefix]              built-in display: fraction of SpacesLab's teal in the
//                              areas left and right of the camera housing
//   onscreen builtin|external  windows WindowServer has on screen there
//   modes                      built-in display modes (index, points, pixels, refresh)
//   modehold <index> <seconds> that mode for this process only; reverted when it exits
//   bar <builtin|external> <count> <index>   point of a Spaces-bar thumbnail in
//                              Mission Control (calibrated, see README)
//   drag <x1> <y1> <x2> <y2>   press, move, release (global top-left points)
//   move <x> <y>               pointer only
//   click <x> <y>

import AppKit
import ApplicationServices

private typealias MainConnFn = @convention(c) () -> Int32
private typealias CopyManagedFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let slsMain = unsafeBitCast(dlsym(sky, "SLSMainConnectionID"), to: MainConnFn.self)
private let slsManaged = unsafeBitCast(dlsym(sky, "SLSCopyManagedDisplaySpaces"), to: CopyManagedFn.self)

func screen(_ which: String) -> NSScreen? {
    NSScreen.screens.first { ($0.safeAreaInsets.top > 0) == (which == "builtin") }
}

/// The built-in panel by hardware (CGDisplayIsBuiltin), with or without its
/// housing band: a mode below the housing has no safe-area inset.
func panel() -> NSScreen? {
    NSScreen.screens.first {
        CGDisplayIsBuiltin((($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value) ?? 0) != 0
    }
}

func uuid(of s: NSScreen) -> String {
    let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
    return CFUUIDCreateString(nil, u) as String
}

/// Global top-left rect of a screen (CoreGraphics / event coordinates).
func cgRect(_ s: NSScreen) -> CGRect {
    let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? s.frame.maxY
    return CGRect(x: s.frame.minX, y: primaryMaxY - s.frame.maxY, width: s.frame.width, height: s.frame.height)
}

/// Every event spacesctl posts carries this in eventSourceUserData, so
/// `spacesctl watch` can tell the harness's input from anyone else's.
let harnessMarker: Int64 = 0x4650_4B48   // "FPKH"

func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
    e?.flags = flags
    e?.setIntegerValueField(.eventSourceUserData, value: harnessMarker)
    e?.post(tap: .cghidEventTap)
}

func mouse(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.eventSourceUserData, value: harnessMarker)
    e?.post(tap: .cghidEventTap)
}

func spaceLine(_ pid: Int) -> String {
    let displays = (slsManaged(slsMain())?.takeRetainedValue() as? [[String: Any]]) ?? []
    var out = "display=none shown=0 space=0 index=0 count=0"
    for d in displays {
        let ident = d["Display Identifier"] as? String ?? ""
        let current = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.intValue ?? -1
        let spaces = (d["Spaces"] as? [[String: Any]]) ?? []   // Spaces-bar order
        for (index, s) in spaces.enumerated() where (s["pid"] as? NSNumber)?.intValue == pid {
            let id = (s["id64"] as? NSNumber)?.intValue ?? 0
            let which = NSScreen.screens.first { uuid(of: $0) == ident }.map { $0.safeAreaInsets.top > 0 ? "builtin" : "external" } ?? "unknown"
            out = "display=\(which) shown=\(id == current ? 1 : 0) space=\(id) index=\(index) count=\(spaces.count)"
        }
    }
    return out
}

func ms(_ n: Int) { usleep(useconds_t(n * 1000)) }

func ax(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, attribute as CFString, &v)
    return v
}

let args = Array(CommandLine.arguments.dropFirst())
func arg(_ i: Int) -> String { i < args.count ? args[i] : "" }

switch arg(0) {
case "cmd":
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("SpacesLab.cmd.\(arg(1))"), object: arg(2), userInfo: nil, deliverImmediately: true)
    ms(50)

case "cmdtab":
    // Command-Tab with `n` Tab presses (default 1: the previous application).
    post(55, true, .maskCommand); ms(40)
    for _ in 0..<max(1, Int(arg(1)) ?? 1) {
        post(48, true, .maskCommand); ms(40)
        post(48, false, .maskCommand); ms(120)
    }
    post(55, false, []); ms(40)

case "key":
    var flags: CGEventFlags = []
    for m in args.dropFirst(2) {
        switch m {
        case "ctrl": flags.insert(.maskControl)
        case "cmd": flags.insert(.maskCommand)
        case "opt": flags.insert(.maskAlternate)
        case "fn": flags.insert(.maskSecondaryFn)
        default: break
        }
    }
    let code = CGKeyCode(arg(1)) ?? 53
    post(code, true, flags); ms(40); post(code, false, flags)

case "dock":
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { exit(1) }
    var pressed = false
    for list in (ax(AXUIElementCreateApplication(dock.processIdentifier), "AXChildren") as? [AXUIElement]) ?? [] {
        for item in (ax(list, "AXChildren") as? [AXUIElement]) ?? [] where (ax(item, "AXTitle") as? String) == arg(1) {
            pressed = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
    }
    print(pressed ? "pressed \(arg(1))" : "no Dock item \(arg(1))")
    exit(pressed ? 0 : 1)

case "front":
    print(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")

case "space":
    // display=<builtin|external|none> shown=<0|1> space=<id>
    print(spaceLine(Int(arg(1)) ?? -1))

case "waitshown":
    // waitshown <pid> <0|1> <timeout ms>: polls every 20 ms until the pid's
    // Space is (not) shown. Prints "ok <ms>" or "timeout <ms>"; exit 0 / 1.
    let pid = Int(arg(1)) ?? -1, want = arg(2) == "1" ? "shown=1" : "shown=0"
    let timeout = Double(arg(3)) ?? 3000, start = Date()
    while true {
        let elapsed = Date().timeIntervalSince(start) * 1000
        if spaceLine(pid).contains(want) { print("ok \(Int(elapsed))"); exit(0) }
        if elapsed >= timeout { print("timeout \(Int(elapsed))"); exit(1) }
        ms(20)
    }

case "activate":
    // activate <bundle id>: activates a running application without opening
    // or reopening any of its windows.
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: arg(1)).first else {
        print("not running \(arg(1))"); exit(1)
    }
    print(app.activate() ? "activated \(arg(1))" : "refused \(arg(1))")

case "watch":
    // watch <file>: listen-only event tap until killed. Writes one line per
    // keyboard, mouse, scroll or gesture event that does NOT carry the
    // harness marker (someone else's input), with wall-clock milliseconds.
    // Never asks for a permission: without Input Monitoring / Accessibility
    // it writes "access=0" and exits 2, and the harness reports contamination
    // detection as unavailable.
    guard CGPreflightListenEventAccess() else {
        try? "access=0\n".write(toFile: arg(1), atomically: true, encoding: .utf8); exit(2)
    }
    FileManager.default.createFile(atPath: arg(1), contents: Data("access=1\n".utf8))
    guard let handle = FileHandle(forWritingAtPath: arg(1)) else { exit(1) }
    handle.seekToEndOfFile()
    let watched: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                  .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                  .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel]
    var mask: CGEventMask = 0
    for t in watched { mask |= CGEventMask(1) << t.rawValue }
    mask |= CGEventMask(1) << 29   // NSEventTypeGesture: trackpad gestures (Space swipes)
    mask |= CGEventMask(1) << 30   // NSEventTypeMagnify
    let callback: CGEventTapCallBack = { _, type, event, refcon in
        if event.getIntegerValueField(.eventSourceUserData) != harnessMarker,
           type.rawValue != 0xFFFFFFFE, type.rawValue != 0xFFFFFFFF, let refcon {
            let h = Unmanaged<FileHandle>.fromOpaque(refcon).takeUnretainedValue()
            let line = String(format: "%.0f type=%u pid=%lld x=%.0f y=%.0f\n",
                              Date().timeIntervalSince1970 * 1000, type.rawValue,
                              event.getIntegerValueField(.eventSourceUnixProcessID),
                              event.location.x, event.location.y)
            h.write(Data(line.utf8))
        }
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                      userInfo: Unmanaged.passUnretained(handle).toOpaque()) else {
        handle.write(Data("access=0 tap-failed\n".utf8)); exit(2)
    }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRun()

case "shot":
    for which in ["builtin", "external"] {
        guard let s = screen(which) else { continue }
        let r = cgRect(s)
        let path = "\(arg(1))-\(which).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", path]
        try? p.run(); p.waitUntilExit()
        guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else {
            print("\(which) capture-failed"); continue
        }
        var hit = 0, n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 23) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 23) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                n += 1
                if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.06 { hit += 1 }
            }
        }
        print(String(format: "%@ nonblack=%.2f", which, Double(hit) / Double(max(n, 1))))
    }

case "band":
    // The two areas beside the camera housing of the built-in display: the
    // fraction of SpacesLab's teal window background in each. A black band
    // (ordinary fullscreen) and an opaque fullscreen menu bar (gray, or the
    // light/dark menu bar material) both count 0, so this is proof of window
    // pixels beside the housing, unlike a non-black fraction.
    guard let s = screen("builtin"), let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea else {
        print("band no-housing"); exit(1)
    }
    let inset = s.safeAreaInsets.top
    let path = arg(1).isEmpty ? NSTemporaryDirectory() + "spacesctl-band.png" : "\(arg(1))-band.png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R\(Int(s.frame.minX)),0,\(Int(s.frame.width)),\(Int(inset))", path]
    try? p.run(); p.waitUntilExit()
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else {
        print("band capture-failed"); exit(1)
    }
    let scale = CGFloat(rep.pixelsWide) / s.frame.width
    func teal(_ r: NSRect) -> Double {
        var hit = 0, n = 0
        for x in stride(from: r.minX - s.frame.minX + 8, to: r.maxX - s.frame.minX - 8, by: 6) {
            for y in stride(from: CGFloat(3), to: inset - 3, by: 3) {
                guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { continue }
                n += 1
                if c.greenComponent > 0.45 && c.blueComponent > 0.5 && c.redComponent < 0.45 { hit += 1 }
            }
        }
        return n == 0 ? 0 : Double(hit) / Double(n)
    }
    print(String(format: "left=%.2f right=%.2f", teal(left), teal(right)))

case "modes":
    // The built-in display's modes: index, points, pixels, refresh, whether it is current.
    guard let s = panel(), let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else { exit(1) }
    let current = CGDisplayCopyDisplayMode(id)
    for (i, m) in modes.enumerated() where m.isUsableForDesktopGUI() {
        print("\(i) \(m.width)x\(m.height) px=\(m.pixelWidth)x\(m.pixelHeight) hz=\(Int(m.refreshRate))\(m.ioDisplayModeID == current?.ioDisplayModeID ? " current" : "")")
    }

case "modehold":
    // modehold <index> <seconds>: switch the built-in display to mode <index> for
    // this process only (kCGConfigureForAppOnly) and hold it until <seconds>
    // pass, the process is terminated, or its parent (the harness) is gone;
    // macOS restores the previous mode when the process ends. Nothing persists.
    guard let s = panel(), let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode],
          let index = Int(arg(1)), modes.indices.contains(index) else { exit(1) }
    let parent = getppid()
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { exit(1) }
    CGConfigureDisplayWithDisplayMode(config, id, modes[index], nil)
    guard CGCompleteDisplayConfiguration(config, .forAppOnly) == .success else { print("mode change refused"); exit(1) }
    print("holding \(modes[index].width)x\(modes[index].height)"); fflush(stdout)
    let deadline = Date().addingTimeInterval(Double(arg(2)) ?? 10)
    while Date() < deadline, getppid() == parent { ms(100) }

case "modeinfo":
    // screens=<n> builtin=<pt> px=<px> hz=<hz> inset=<top> modeid=<io id>, read
    // with CoreGraphics (current at once, unlike a long-lived NSScreen).
    guard let s = panel(), let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let m = CGDisplayCopyDisplayMode(id) else { print("screens=\(NSScreen.screens.count) builtin=none"); exit(1) }
    print("screens=\(NSScreen.screens.count) builtin=\(m.width)x\(m.height) px=\(m.pixelWidth)x\(m.pixelHeight) hz=\(Int(m.refreshRate)) inset=\(Int(s.safeAreaInsets.top)) modeid=\(m.ioDisplayModeID)")

case "modeindex":
    // modeindex <W>x<H> <PW>x<PH> <hz>: index of that mode in `modes`, or exit 1.
    guard let s = panel(), let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else { exit(1) }
    for (i, m) in modes.enumerated() where m.isUsableForDesktopGUI() &&
        "\(m.width)x\(m.height)" == arg(1) && "\(m.pixelWidth)x\(m.pixelHeight)" == arg(2) && Int(m.refreshRate) == Int(arg(3)) {
        print(i); exit(0)
    }
    exit(1)

case "restore":
    // Last resort: the user's own display configuration, as stored by macOS.
    CGRestorePermanentDisplayConfiguration()
    print("restored permanent configuration")

case "onscreen":
    guard let s = screen(arg(1)) else { exit(1) }
    let r = cgRect(s)
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for e in info {
        var b = CGRect.zero
        if let d = e[kCGWindowBounds as String] as? NSDictionary { CGRectMakeWithDictionaryRepresentation(d, &b) }
        let name = e[kCGWindowName as String] as? String ?? ""
        guard b.intersects(r), name != "Cursor", name != "StatusIndicator" else { continue }
        print("\(e[kCGWindowOwnerName as String] ?? "?") '\(name)' layer=\(e[kCGWindowLayer as String] ?? "")")
    }

case "alerts":
    // On-screen windows of macOS's permission and alert processes (privacy
    // prompts such as Files and Folders, Gatekeeper, authorization). Prints
    // them and exits 1 when there are any; reads only. The harness stops
    // rather than touch them.
    let owners: Set<String> = ["UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent",
                               "universalAccessAuthWarn", "UserNotificationCenterService"]
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var found = false
    for e in info {
        guard let owner = e[kCGWindowOwnerName as String] as? String, owners.contains(owner) else { continue }
        var b = CGRect.zero
        if let d = e[kCGWindowBounds as String] as? NSDictionary { CGRectMakeWithDictionaryRepresentation(d, &b) }
        guard b.width > 40, b.height > 40 else { continue }
        found = true
        print("\(owner) '\(e[kCGWindowName as String] as? String ?? "")' \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))")
    }
    exit(found ? 1 : 0)

case "mcstate", "waitmc":
    // Mission Control is taken as open while the Dock has an on-screen window
    // covering the whole built-in display (its backdrop); the Dock itself, its
    // hidden state in fullscreen and the desktop have none. `mcstate` prints
    // open=<0|1> and the Dock's on-screen windows (for checking the rule);
    // `waitmc <0|1> <timeout ms>` waits for that state ("ok <ms>" / "timeout").
    func dockWindows() -> (open: Bool, detail: String) {
        guard let s = screen("builtin") else { return (false, "no builtin") }
        let r = cgRect(s)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var open = false, detail = ""
        for e in info where (e[kCGWindowOwnerName as String] as? String) == "Dock" {
            var b = CGRect.zero
            if let d = e[kCGWindowBounds as String] as? NSDictionary { CGRectMakeWithDictionaryRepresentation(d, &b) }
            let covers = b.minX <= r.minX + 1 && b.minY <= r.minY + 1 && b.maxX >= r.maxX - 1 && b.maxY >= r.maxY - 1
            if covers { open = true }
            detail += " [layer=\(e[kCGWindowLayer as String] ?? "") \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))\(covers ? " covers" : "")]"
        }
        return (open, detail.isEmpty ? " none" : detail)
    }
    if arg(0) == "mcstate" {
        let d = dockWindows(); print("open=\(d.open ? 1 : 0) dock:\(d.detail)")
    } else {
        let want = arg(1) == "1", timeout = Double(arg(2)) ?? 3000, start = Date()
        while true {
            let elapsed = Date().timeIntervalSince(start) * 1000
            if dockWindows().open == want { print("ok \(Int(elapsed))"); exit(0) }
            if elapsed >= timeout { print("timeout \(Int(elapsed))"); exit(1) }
            ms(20)
        }
    }

case "wincenter":
    // wincenter <exact window title>: centre (event coordinates) and size of
    // that on-screen window, as WindowServer places it now (e.g. scaled into
    // the Split View picker). Exit 1 when it is not on screen. Reads only.
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let w = list.first(where: { ($0[kCGWindowName as String] as? String) == arg(1) }),
          let b = w[kCGWindowBounds as String] as? [String: Double] else { print("none"); exit(1) }
    let (x, y, bw, bh) = (b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0)
    print("\(Int(x + bw / 2)) \(Int(y + bh / 2)) \(Int(bw))x\(Int(bh))")

case "mcwindow":
    // mcwindow <title fragment>: centre (event coordinates) of the Mission
    // Control preview whose accessibility title or description contains the
    // fragment, searched in the Dock's accessibility tree. Prints
    // "<x> <y> ax <role>" or, when none is found, the built-in display's
    // centre with "fallback". Reads only.
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
          let s = screen("builtin") else { exit(1) }
    var queue: [(AXUIElement, Int)] = [(AXUIElementCreateApplication(dock.processIdentifier), 0)]
    var visited = 0, found: String?
    while !queue.isEmpty, visited < 5000, found == nil {
        let (e, depth) = queue.removeFirst(); visited += 1
        let text = [(ax(e, "AXTitle") as? String) ?? "", (ax(e, "AXDescription") as? String) ?? ""].joined(separator: " ")
        if text.contains(arg(1)), let pv = ax(e, "AXPosition"), let sv = ax(e, "AXSize") {
            var p = CGPoint.zero, z = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &z)
            if z.width > 100, z.height > 100 {
                found = "\(Int(p.x + z.width / 2)) \(Int(p.y + z.height / 2)) ax \((ax(e, "AXRole") as? String) ?? "?") \(Int(z.width))x\(Int(z.height))"
            }
        }
        if depth < 12 { for c in (ax(e, "AXChildren") as? [AXUIElement]) ?? [] { queue.append((c, depth + 1)) } }
    }
    let r = cgRect(s)
    print(found ?? "\(Int(r.midX)) \(Int(r.midY)) fallback")

case "bar":
    // Mission Control's Spaces bar, expanded, macOS 27: thumbnails ~172 pt
    // apart, centered; their row sits 97 pt below the top of the display, plus
    // 23 pt on a display with a camera housing. Calibrated on a 14-inch MacBook
    // Pro (1800 x 1169) and a 1539 x 1070 Sidecar display.
    guard let s = screen(arg(1)), let count = Int(arg(2)), let index = Int(arg(3)) else { exit(1) }
    let r = cgRect(s)
    let x = r.midX + (CGFloat(index) - CGFloat(count - 1) / 2) * 172
    let y = r.minY + 97 + (s.safeAreaInsets.top > 0 ? 23 : 0)
    print("\(Int(x)) \(Int(y))")

case "labthumb":
    // labthumb [capture prefix]: the lab Space's thumbnail in Mission Control's
    // expanded Spaces bar on the built-in display, found by SpacesLab's teal
    // (the bar's layout depends on the Spaces present, so `bar` can miss).
    // Prints "<x> <y> <w>x<h>" (centre, event coordinates; size in points) for
    // exactly one teal region of thumbnail size between 40 and 210 pt from the
    // top; otherwise "none ..." and exit 1, so the caller never clicks blind.
    guard let s = screen("builtin") else { print("none no-builtin"); exit(1) }
    let r = cgRect(s), top: CGFloat = 40, bottom: CGFloat = 210
    let path = arg(1).isEmpty ? NSTemporaryDirectory() + "spacesctl-labthumb.png" : "\(arg(1))-labthumb.png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(bottom))", path]
    try? p.run(); p.waitUntilExit()
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else {
        print("none capture-failed"); exit(1)
    }
    let scale = CGFloat(rep.pixelsWide) / r.width
    func isTeal(_ x: CGFloat, _ y: CGFloat) -> Bool {
        guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return false }
        return c.greenComponent > 0.45 && c.blueComponent > 0.5 && c.redComponent < 0.45
    }
    // Columns (2 pt apart) with at least 50 pt of teal, grouped into runs.
    var runs: [(CGFloat, CGFloat)] = [], start: CGFloat? = nil, last: CGFloat = -10
    for x in stride(from: CGFloat(0), to: r.width, by: 2) {
        var n = 0
        for y in stride(from: top, to: bottom, by: 2) where isTeal(x, y) { n += 1 }
        if n >= 25 {
            if start == nil || x - last > 4 { if let s0 = start { runs.append((s0, last)) }; start = x }
            last = x
        }
    }
    if let s0 = start { runs.append((s0, last)) }
    let thumbs = runs.filter { $0.1 - $0.0 >= 90 && $0.1 - $0.0 <= 260 }
    // Runs under 20 pt are the blue selection ring of the current Space.
    guard thumbs.count == 1, runs.filter({ $0.1 - $0.0 >= 20 }).count == 1, let t = thumbs.first else {
        print("none runs=\(runs.map { "\(Int($0.0))-\(Int($0.1))" })"); exit(1)
    }
    var rows: [CGFloat] = []
    for y in stride(from: top, to: bottom, by: 2) {
        var n = 0, m = 0
        for x in stride(from: t.0, through: t.1, by: 4) { m += 1; if isTeal(x, y) { n += 1 } }
        if n * 2 >= m { rows.append(y) }
    }
    guard let y0 = rows.first, let y1 = rows.last, y1 - y0 >= 50, y1 - y0 <= 140, y1 < bottom - 4 else {
        print("none rows=\(rows.first.map { Int($0) } ?? -1)-\(rows.last.map { Int($0) } ?? -1)"); exit(1)
    }
    print("\(Int(r.minX + (t.0 + t.1) / 2)) \(Int(r.minY + (y0 + y1) / 2)) \(Int(t.1 - t.0))x\(Int(y1 - y0))")

case "drag":
    let p1 = CGPoint(x: Double(arg(1)) ?? 0, y: Double(arg(2)) ?? 0)
    let p2 = CGPoint(x: Double(arg(3)) ?? 0, y: Double(arg(4)) ?? 0)
    mouse(.mouseMoved, p1); ms(200)
    mouse(.leftMouseDown, p1); ms(700)
    for i in 1...60 {
        let t = Double(i) / 60
        mouse(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)); ms(30)
    }
    for _ in 0..<10 { mouse(.leftMouseDragged, p2); ms(50) }
    mouse(.leftMouseUp, p2)

case "move":
    mouse(.mouseMoved, CGPoint(x: Double(arg(1)) ?? 0, y: Double(arg(2)) ?? 0))

case "click":
    let p = CGPoint(x: Double(arg(1)) ?? 0, y: Double(arg(2)) ?? 0)
    mouse(.mouseMoved, p); ms(80); mouse(.leftMouseDown, p); ms(80); mouse(.leftMouseUp, p)

default:
    print("usage: spacesctl cmd|cmdtab|key|dock|front|space|waitshown|activate|watch|alerts|mcstate|waitmc|mcwindow|wincenter|shot|onscreen|bar|drag|click (see source)")
}
