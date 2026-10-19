// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).

import AppKit
import FullPanelKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model: WindowModel
    @Environment(\.openWindow) private var openWindow

    init(role: WindowModel.Role) {
        _model = StateObject(wrappedValue: WindowModel(role: role))
    }

    private var attached: Bool { model.role == .attached }
    private var isAppKit: Bool { [.appkit, .appkitControl, .appkitSubclass].contains(model.role) }
    private var layout: FullPanelLayout { model.layout }

    var body: some View {
        ZStack(alignment: .topLeading) {
            (attached ? Color(red: 0.07, green: 0.10, blue: 0.18)
                      : model.role == .appkit || model.role == .appkitSubclass ? Color(red: 0.12, green: 0.10, blue: 0.20)
                      : Color(white: 0.16))

            if let area = layout.leftArea {
                side("LEFT", model.leftClicks, Color(red: 0.06, green: 0.88, blue: 0.38)) {
                    model.leftClicks += 1
                }
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
            }
            if let area = layout.rightArea {
                side("RIGHT", model.rightClicks, Color(red: 0.15, green: 0.75, blue: 1)) {
                    model.rightClicks += 1
                }
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
            }
            // Nothing is drawn for the housing itself; `layout.cameraHousing`
            // is listed in the diagnostics below.

            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The window covers the whole display in FullPanel; SwiftUI must not
        // push the content below the housing.
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 540)
        .background(WindowAttacher { model.windowDidChange($0) })
        .onAppear {
            // Only SwiftUI scene windows have a working openWindow action.
            guard !isAppKit else { return }
            let open = openWindow
            DemoRegistry.shared.openWindow = { open(id: $0) }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleText)
                .font(.title3.bold())
            Text(explanationText)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Text("FullPanel: \(stateText)")
            if layout.fallbackReason != .none {
                Text("Fallback: \(layout.fallbackReason.summary)")
            }
            if let error = model.lastError { Text("Attach error: \(error)").foregroundColor(.orange) }

            sectionLabel("This window")
            HStack {
                Button(model.window?.styleMask.contains(.fullScreen) == true
                       ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
                Button(model.session == nil ? "Attach" : "Detach") {
                    model.session == nil ? model.attach() : model.detach()
                }
                Toggle("FullPanel enabled", isOn: Binding(get: { model.isEnabled },
                                                          set: { model.isEnabled = $0 }))
                    .disabled(model.session == nil)
            }
            .font(.system(size: 13))
            sectionLabel("Open another window")
            HStack {
                Button("SwiftUI + session") { openWindow(id: SceneID.fullPanel) }
                Button("Ordinary SwiftUI") { openWindow(id: SceneID.ordinary) }
                Button("FullPanelWindow") { LegacyWindow.open() }
                Button("Plain NSWindow (rejected)") { AppKitWindows.openPair() }
            }
            .font(.system(size: 13))

            Divider()
            sectionLabel("Diagnostics")
            Toggle("KVO probe (frame, styleMask, collectionBehavior, contentView)",
                   isOn: Binding(get: { model.isKVOEnabled }, set: { model.setKVO($0) }))
                .font(.system(size: 13))
            Text(diagnosticsText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
        .foregroundColor(.white)
        .padding(20)
        .frame(maxWidth: 720, alignment: .leading)
        .background(Color.black.opacity(0.35))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
            .padding(.top, 4)
    }

    private var explanationText: String {
        switch model.role {
        case .attached:
            return "SwiftUI created this window. FullPanelSession.attach(to:) adds FullPanel to it without "
                + "replacing or subclassing it. Enter fullscreen and click the green and blue strips beside the camera."
        case .ordinary:
            return "Same SwiftUI window class, never attached: its fullscreen stays ordinary macOS fullscreen."
        case .appkit:
            return "A plain NSWindow cannot be attached; FullPanelSession refuses it with an error and leaves it unchanged."
        case .appkitControl:
            return "Untouched control window for comparison."
        case .appkitSubclass:
            return "The supported AppKit path: the application's own NSWindow subclass, with FullPanelSession attached."
        }
    }

    private var titleText: String {
        switch model.role {
        case .attached: return "FullPanelSession on a SwiftUI WindowGroup window"
        case .ordinary: return "Ordinary SwiftUI window (never attached)"
        case .appkit: return "AppKit NSWindow + NSWindowController + delegate (attach must be rejected)"
        case .appkitControl: return "AppKit NSWindow — untouched control (never attached)"
        case .appkitSubclass: return "AppKit NSWindow subclass + NSWindowController + delegate, FullPanelSession attached"
        }
    }

    private var stateText: String {
        guard model.session != nil else { return "not attached" }
        switch layout.state {
        case .disabled: return "attached, disabled"
        case .inactive: return "enabled, not in fullscreen"
        case .active: return "ACTIVE — content beside the camera housing"
        case .fallback: return "standard fullscreen (fallback)"
        @unknown default: return "unknown"
        }
    }

    private var diagnosticsText: String {
        let d = model.diagnostics
        let g = model.session?.geometry
        var lines = [
            "window      \(d["windowPointer"] ?? "-")  \(d["windowClass"] ?? "-")",
            "runtime     \(d["windowRuntimeClass"] ?? "-")",
            "delegate    \(d["delegateClass"] ?? "-")  controller \(d["windowControllerClass"] ?? "-")",
            "attached    \(d["attached"] ?? false)  geometry \(d["geometry"] ?? "-")",
            "frame       \(d["windowFrame"] ?? "-")  fullscreen \(d["inFullScreen"] ?? false)",
            "screen      \(d["screenFrame"] ?? "-")",
        ]
        if let g {
            lines.append("housing     inset \(Int(g.topInset))pt  rect \(NSStringFromRect(g.cameraHousingRect))")
            lines.append("aux L/R     \(NSStringFromRect(g.auxiliaryLeftArea)) / \(NSStringFromRect(g.auxiliaryRightArea))")
        }
        if model.session != nil {
            lines.append("armed \(d["armed"] ?? "-") accepted \(d["frameAccepted"] ?? "-") space \(d["fullscreenSpaceID"] ?? "-") compositor \(d["compositorState"] ?? "-")")
            lines.append("menu override \(d["menuBarOverrideSubmitted"] ?? "-")  reveal \(d["revealActive"] ?? "-")  presentation 0x\(String((d["appPresentationOptionsRaw"] as? Int) ?? 0, radix: 16))")
        }
        if let events = d["delegateEvents"] { lines.append("delegate ev \(events)") }
        if let kvo = d["kvo"] { lines.append("kvo         \(kvo)") }
        lines.append("clicks      left \(model.leftClicks)  right \(model.rightClicks)")
        return lines.joined(separator: "\n")
    }

    private func side(_ label: String, _ count: Int, _ color: Color,
                      action: @escaping () -> Void) -> some View {
        HStack {
            Text("\(label) \(count)").font(.system(size: 13, weight: .semibold, design: .monospaced))
            Spacer()
            Text("click +1").font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .foregroundColor(.black)
        .background(color)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
