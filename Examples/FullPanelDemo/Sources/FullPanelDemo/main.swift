// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// FullPanelDemo — uses only FullPanelKit's public API for fullscreen.

import AppKit
import FullPanelKit

@MainActor
final class DemoApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: FullPanelWindow!
    private let model = DemoModel()
    private let useSwiftUI = UserDefaults.standard.bool(forKey: "FullPanelDemoSwiftUI")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        let screen = FullPanelDisplayGeometry.screensWithCameraHousing().first
            ?? NSScreen.main ?? NSScreen.screens[0]
        let rect = NSRect(x: screen.frame.midX - 480, y: screen.frame.midY - 310,
                          width: 960, height: 620)
        if useSwiftUI {
            window = FullPanelWindow(contentRect: rect) { [model] in DemoSwiftUIView(model: model) }
        } else {
            window = FullPanelWindow(contentRect: rect,
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered, defer: false)
            let view = DemoView(frame: NSRect(origin: .zero, size: rect.size), model: model)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
        }
        window.title = "FullPanel Demo" + (useSwiftUI ? " (SwiftUI)" : "")
            + (UserDefaults.standard.string(forKey: "FullPanelDemoLabel").map { " \($0)" } ?? "")
        window.minSize = NSSize(width: 700, height: 560)
        window.delegate = self          // ordinary app delegate; FullPanel needs nothing from it
        window.fullPanelEnabled = true
        model.attach(to: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("FullPanelDemo: started (%@). Control-Command-F enters native fullscreen.",
              useSwiftUI ? "SwiftUI" : "AppKit")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func setupMenu() {
        let bar = NSMenu()
        let appMenu = submenu(of: bar, "FullPanel Demo")
        appMenu.addItem(withTitle: "About FullPanel Demo",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FullPanel Demo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FullPanel Demo",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let viewMenu = submenu(of: bar, "View")
        add(viewMenu, "Enter Full Screen", #selector(toggleFullscreen(_:)), "f", [.control, .command])
        add(viewMenu, "Use FullPanel", #selector(toggleFullPanel(_:)), "e", [.command])

        let windowMenu = submenu(of: bar, "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Developer tools stay out of the window itself.
        let developerMenu = submenu(of: bar, "Developer")
        add(developerMenu, "Write Diagnostics Report", #selector(writeReport(_:)), "r", [.command])
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windowMenu
    }

    private func submenu(of bar: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        bar.addItem(item)
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     _ key: String, _ mods: NSEvent.ModifierFlags) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
    }

    @objc private func toggleFullscreen(_ sender: Any?) { window.toggleFullScreen(sender) }

    @objc private func toggleFullPanel(_ sender: Any?) {
        model.isFullPanelEnabled.toggle()
    }

    @objc private func writeReport(_ sender: Any?) {
        var report = window.fullPanelDiagnostics()
        report["timestamp"] = ISO8601DateFormatter().string(from: Date())
        report["demoUI"] = useSwiftUI ? "SwiftUI" : "AppKit"
        report["leftClicks"] = model.leftClicks
        report["rightClicks"] = model.rightClicks
        report["note"] = "Verify physical pixels, clicks, Mission Control return and menu-bar reveal visually."
        do {
            let data = try JSONSerialization.data(withJSONObject: report,
                                                  options: [.prettyPrinted, .sortedKeys])
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            let dest = dir.appendingPathComponent("FullPanelDemo-report.json")
            try data.write(to: dest, options: .atomic)
            NSLog("FullPanelDemo: report saved to %@", dest.path)
        } catch {
            NSLog("FullPanelDemo: report failed: %@", error.localizedDescription)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFullPanel(_:)) {
            item.state = window?.fullPanelEnabled == true ? .on : .off
        } else if item.action == #selector(toggleFullscreen(_:)) {
            item.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
        }
        return true
    }
}


let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { DemoApp() }   // top-level code runs on the main thread
app.delegate = delegate
app.run()
