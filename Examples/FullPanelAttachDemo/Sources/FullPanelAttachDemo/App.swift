// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// FullPanelAttachDemo — SwiftUI creates every window here. FullPanelKit is
// attached to the existing NSWindow through FullPanelSession; no window is
// replaced or subclassed by the demo.

import AppKit
import FullPanelKit
import SwiftUI

enum SceneID {
    /// Windows that attach FullPanel on appearance.
    static let fullPanel = "fullpanel"
    /// Ordinary windows: same SwiftUI window class, never attached.
    static let ordinary = "ordinary"
}

@main
struct FullPanelAttachDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: SceneID.fullPanel) {
            ContentView(role: .attached)
        }
        WindowGroup("Ordinary Window", id: SceneID.ordinary) {
            ContentView(role: .ordinary)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before state restoration, so a restored window's entry is recorded.
        if let scenario = UserDefaults.standard.string(forKey: "FullPanelAttachScenario") {
            ScenarioTest.shared = ScenarioTest(name: scenario)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("FullPanelAttachDemo: started. FullPanel system support: %@",
              FullPanelSession.systemSupportAvailable() ? "yes" : "no")
        if UserDefaults.standard.bool(forKey: "FullPanelAttachOpenAppKit") {
            AppKitWindows.openPair()
        }
        if let test = ScenarioTest.shared {
            Task { @MainActor in await test.run() }
        } else if UserDefaults.standard.bool(forKey: "FullPanelAttachAutotest") {
            Task { @MainActor in await Autotest().run() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
