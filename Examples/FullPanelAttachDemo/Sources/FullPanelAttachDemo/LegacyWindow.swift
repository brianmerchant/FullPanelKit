// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// Regression check for the original API in the same process: a FullPanelWindow
// created by the application (not by SwiftUI).

import AppKit
import FullPanelKit
import SwiftUI

@MainActor
enum LegacyWindow {
    private(set) static var current: FullPanelWindow?

    @discardableResult
    static func open() -> FullPanelWindow {
        if let current { current.makeKeyAndOrderFront(nil); return current }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let rect = NSRect(x: screen.frame.midX - 360, y: screen.frame.midY - 220, width: 720, height: 440)
        let window = FullPanelWindow(contentRect: rect) { LegacyView() }
        window.title = "FullPanelWindow (legacy API)"
        window.isReleasedWhenClosed = false
        window.fullPanelEnabled = true
        window.makeKeyAndOrderFront(nil)
        current = window
        return window
    }

    static func close() {
        current?.close()
        current = nil
    }
}

private struct LegacyView: View {
    @Environment(\.fullPanel) private var fullPanel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.20, green: 0.08, blue: 0.16)
            if let area = fullPanel.leftArea {
                Color.green.frame(width: area.width, height: area.height).offset(x: area.minX, y: area.minY)
            }
            if let area = fullPanel.rightArea {
                Color.cyan.frame(width: area.width, height: area.height).offset(x: area.minX, y: area.minY)
            }
            Text("FullPanelWindow (legacy API): \(String(describing: fullPanel.state))")
                .font(.system(.title3, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
