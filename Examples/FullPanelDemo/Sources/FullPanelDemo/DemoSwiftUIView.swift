// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// SwiftUI variant (launch with -FullPanelDemoSwiftUI YES). Same engine and
// same content as DemoView; the layout arrives through the \.fullPanel
// environment value. Nothing is drawn to stand in for the housing itself.

import FullPanelKit
import SwiftUI

struct DemoSwiftUIView: View {
    @Environment(\.fullPanel) private var fullPanel
    @ObservedObject var model: DemoModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)

            if let area = fullPanel.leftArea {
                Strip(caption: "LEFT OF CAMERA", clicks: $model.leftClicks,
                      color: Color(.sRGB, red: 0.20, green: 0.80, blue: 0.45))
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
            }
            if let area = fullPanel.rightArea {
                Strip(caption: "RIGHT OF CAMERA", clicks: $model.rightClicks,
                      color: Color(.sRGB, red: 0.25, green: 0.65, blue: 1.00))
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
            }

            card
                .padding(.top, fullPanel.isActive ? fullPanel.topInset : 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FullPanel Demo").font(.system(size: 26, weight: .bold))
                Text("Native macOS fullscreen that also uses the display area beside the MacBook camera housing.")
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: model.statusColor)).frame(width: 9, height: 9)
                    Text(model.statusTitle).fontWeight(.semibold)
                }
                Text(model.statusDetail).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Divider()

            HStack {
                Button(model.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") {
                    model.toggleFullScreen()
                }
                .controlSize(.large)
                Spacer()
                Toggle("Use FullPanel", isOn: Binding(get: { model.isFullPanelEnabled },
                                                      set: { model.isFullPanelEnabled = $0 }))
                    .toggleStyle(.switch)
                    .disabled(model.isFullScreen)
            }
            Text(model.isFullScreen
                 ? "Leave fullscreen to switch between FullPanel and ordinary fullscreen."
                 : "Turn off to compare with ordinary macOS fullscreen, which keeps the window below the camera housing.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Divider()

            Text("TRY IT").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(nsColor: .tertiaryLabelColor))
            VStack(alignment: .leading, spacing: 4) {
                Text("1.  Enter fullscreen: Control-Command-F, or the green window button.")
                Text("2.  Click the coloured strips beside the camera. Each click is counted.")
                Text("3.  Move the pointer to the very top edge: the menu bar slides in.")
                Text("4.  Swipe up with three fingers for Mission Control, or swipe between Spaces.")
                Text("5.  Press Control-Command-F again: the window returns to its place.")
            }
            HStack(spacing: 10) {
                Text("Clicks beside the camera: left \(model.leftClicks), right \(model.rightClicks)")
                    .font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                Button("Reset") { model.resetClicks() }.controlSize(.small)
            }
        }
        .font(.system(size: 13))
        .frame(width: 500, alignment: .leading)
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor)))
        .fixedSize()
    }
}

/// A strip beside the housing: solid colour, a faint diagonal pattern, the
/// click count, a native button and a ring wherever a click lands.
private struct Strip: View {
    let caption: String
    @Binding var clicks: Int
    let color: Color
    @State private var pulses: [Pulse] = []

    private struct Pulse: Identifiable {
        let id = UUID()
        let point: CGPoint
    }

    var body: some View {
        ZStack(alignment: .leading) {
            color
            Stripes().stroke(Color.white.opacity(0.18), lineWidth: 3)
            HStack(spacing: 0) {
                Text(caption).font(.system(size: 11, weight: .bold)).kerning(0.8)
                    .foregroundColor(.black.opacity(0.8))
                Text("   \(clicks) \(clicks == 1 ? "click" : "clicks")  ·  click anywhere here")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(.black.opacity(0.75))
                Spacer()
                Button("+1") { clicks += 1 }.controlSize(.small)
                    .environment(\.colorScheme, .light)   // legible on the light strips
            }
            .padding(.horizontal, 16)
            ForEach(pulses) { pulse in
                PulseRing().position(pulse.point).allowsHitTesting(false)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
            clicks += 1
            let pulse = Pulse(point: tap.location)
            pulses.append(pulse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pulses.removeAll { $0.id == pulse.id }
            }
        })
    }
}

private struct PulseRing: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(Color.white.opacity(expanded ? 0 : 0.55))
            .overlay(Circle().stroke(Color.white.opacity(expanded ? 0 : 1), lineWidth: 2))
            .frame(width: expanded ? 80 : 12, height: expanded ? 80 : 12)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { expanded = true } }
    }
}

private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 12
        }
        return path
    }
}
