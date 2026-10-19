// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// AppKit demo content. In FullPanel fullscreen the strips left and right of
// the camera housing are drawn and clickable; everything else stays in the
// ordinary content area below them. Positions come from FullPanelKit's public
// layout API. Nothing is drawn to stand in for the housing itself.

import AppKit
import Combine
import FullPanelKit

final class DemoView: NSView {
    private let model: DemoModel
    private var modelSink: AnyCancellable?

    // Beside the housing: one native button per strip; a click anywhere else
    // in a strip also counts.
    private let leftButton = NSButton(title: "+1", target: nil, action: nil)
    private let rightButton = NSButton(title: "+1", target: nil, action: nil)

    // Card in the ordinary content area.
    private let stack = NSStackView()
    private let statusDot = StatusDot()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let fullScreenButton = NSButton(title: "Enter Full Screen", target: nil, action: nil)
    private let fullPanelSwitch = NSSwitch()
    private let switchHint = NSTextField(wrappingLabelWithString: "")
    private let clicksLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private static let cardWidth: CGFloat = 500
    private static let cardPadding: CGFloat = 28

    /// Expanding rings at recent click locations inside the strips.
    private var pulses: [(point: NSPoint, start: CFTimeInterval)] = []
    private var pulseTimer: Timer?

    override var isFlipped: Bool { true }   // top-left origin, like FullPanelLayout

    init(frame: NSRect, model: DemoModel) {
        self.model = model
        super.init(frame: frame)
        for button in [leftButton, rightButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.appearance = NSAppearance(named: .aqua)   // legible on the light strips
            button.target = self
            button.isHidden = true
            addSubview(button)
        }
        leftButton.action = #selector(leftPressed(_:))
        rightButton.action = #selector(rightPressed(_:))
        buildCard()
        modelSink = model.objectWillChange.sink { [weak self] in
            // objectWillChange fires before the change lands.
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // ---- Card -----------------------------------------------------------------

    private func buildCard() {
        let title = NSTextField(labelWithString: "FullPanel Demo")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = secondary("Native macOS fullscreen that also uses the display area "
                                 + "beside the MacBook camera housing.", size: 13)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.spacing = 8
        let status = NSStackView(views: [statusRow, detailLabel])
        status.orientation = .vertical
        status.alignment = .leading
        status.spacing = 3

        fullScreenButton.bezelStyle = .rounded
        fullScreenButton.controlSize = .large
        fullScreenButton.target = self
        fullScreenButton.action = #selector(toggleFullScreen(_:))
        fullPanelSwitch.target = self
        fullPanelSwitch.action = #selector(fullPanelSwitched(_:))
        let switchLabel = NSTextField(labelWithString: "Use FullPanel")
        let switchRow = NSStackView(views: [fullPanelSwitch, switchLabel])
        switchRow.spacing = 8
        let controls = NSStackView(views: [fullScreenButton, NSView(), switchRow])
        controls.distribution = .fill
        switchHint.font = .systemFont(ofSize: 11)
        switchHint.textColor = .secondaryLabelColor

        let steps = secondary("""
            1.  Enter fullscreen: Control-Command-F, or the green window button.
            2.  Click the coloured strips beside the camera. Each click is counted.
            3.  Move the pointer to the very top edge: the menu bar slides in.
            4.  Swipe up with three fingers for Mission Control, or swipe between Spaces.
            5.  Press Control-Command-F again: the window returns to its place.
            """, size: 13, color: .labelColor)

        clicksLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clicksLabel.textColor = .secondaryLabelColor
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetPressed(_:))
        let clicksRow = NSStackView(views: [clicksLabel, resetButton])
        clicksRow.spacing = 10

        let views: [NSView] = [title, subtitle, status, separator(), controls, switchHint,
                               separator(), heading("Try it"), steps, clicksRow]
        stack.setViews(views, in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(6, after: controls)
        stack.setCustomSpacing(6, after: views[7])
        stack.translatesAutoresizingMaskIntoConstraints = true
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.cardWidth).isActive = true
        }
        for view in [subtitle, detailLabel, switchHint, steps, controls] {
            view.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        }
        addSubview(stack)
        refresh()
    }

    private func secondary(_ text: String, size: CGFloat, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.isSelectable = false
        return label
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func refresh() {
        let fullScreen = model.isFullScreen
        statusDot.color = model.statusColor
        statusLabel.stringValue = model.statusTitle
        detailLabel.stringValue = model.statusDetail
        fullScreenButton.title = fullScreen ? "Exit Full Screen" : "Enter Full Screen"
        fullPanelSwitch.state = model.isFullPanelEnabled ? .on : .off
        fullPanelSwitch.isEnabled = !fullScreen
        switchHint.stringValue = fullScreen
            ? "Leave fullscreen to switch between FullPanel and ordinary fullscreen."
            : "Turn off to compare with ordinary macOS fullscreen, which keeps the "
              + "window below the camera housing."
        clicksLabel.stringValue = "Clicks beside the camera: left \(model.leftClicks), right \(model.rightClicks)"
        needsLayout = true
        needsDisplay = true
    }

    // ---- Actions --------------------------------------------------------------

    @objc private func toggleFullScreen(_ sender: Any?) { model.toggleFullScreen() }
    @objc private func fullPanelSwitched(_ sender: NSSwitch) { model.isFullPanelEnabled = sender.state == .on }
    @objc private func resetPressed(_ sender: Any?) { model.resetClicks() }

    @objc private func leftPressed(_ sender: NSButton) {
        model.leftClicks += 1
        pulse(at: NSPoint(x: sender.frame.midX, y: sender.frame.midY))
    }

    @objc private func rightPressed(_ sender: NSButton) {
        model.rightClicks += 1
        pulse(at: NSPoint(x: sender.frame.midX, y: sender.frame.midY))
    }

    // A click anywhere in a strip counts too, with a ring where it landed.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = model.layout
        if layout.leftArea?.contains(point) == true {
            model.leftClicks += 1
            pulse(at: point)
        } else if layout.rightArea?.contains(point) == true {
            model.rightClicks += 1
            pulse(at: point)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func pulse(at point: NSPoint) {
        pulses.append((point, CACurrentMediaTime()))
        needsDisplay = true
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.pulses.removeAll { now - $0.start > Self.pulseDuration }
                self.needsDisplay = true
                if self.pulses.isEmpty { self.pulseTimer?.invalidate(); self.pulseTimer = nil }
            }
        }
    }

    private static let pulseDuration: CFTimeInterval = 0.5

    // ---- Layout ---------------------------------------------------------------

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Top of the ordinary content area: below the housing band in FullPanel,
    /// below the (transparent) titlebar in a window.
    private var contentTop: CGFloat {
        let layout = model.layout
        let band = layout.isActive ? layout.topInset : 0
        let titlebar = window.map { $0.frame.height - $0.contentLayoutRect.maxY } ?? 0
        return max(band, titlebar)
    }

    private var cardRect: NSRect {
        let size = stack.fittingSize
        let width = Self.cardWidth + 2 * Self.cardPadding
        let height = size.height + 2 * Self.cardPadding
        let top = contentTop
        let y = top + max(16, (bounds.height - top - height) / 2)
        return NSRect(x: max(16, (bounds.width - width) / 2), y: y, width: width, height: height)
    }

    override func layout() {
        super.layout()
        let layout = model.layout
        place(leftButton, in: layout.leftArea)
        place(rightButton, in: layout.rightArea)
        let card = cardRect
        stack.frame = card.insetBy(dx: Self.cardPadding, dy: Self.cardPadding)
    }

    private func place(_ button: NSButton, in area: CGRect?) {
        guard let area, area.width > 160 else { button.isHidden = true; return }
        button.sizeToFit()
        let size = button.frame.size
        button.frame = NSRect(x: area.maxX - size.width - 16,
                              y: area.midY - size.height / 2,
                              width: size.width, height: size.height)
        button.isHidden = false
    }

    // ---- Drawing --------------------------------------------------------------

    // Optional instance label for multi-instance tests: -FullPanelDemoLabel A
    private let instanceLabel = UserDefaults.standard.string(forKey: "FullPanelDemoLabel")

    private static let leftColor = NSColor(srgbRed: 0.20, green: 0.80, blue: 0.45, alpha: 1)
    private static let rightColor = NSColor(srgbRed: 0.25, green: 0.65, blue: 1.00, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        switch instanceLabel {
        case "A": NSColor(calibratedRed: 0.30, green: 0.08, blue: 0.30, alpha: 1).setFill()
        case "B": NSColor(calibratedRed: 0.35, green: 0.22, blue: 0.04, alpha: 1).setFill()
        default: NSColor.windowBackgroundColor.setFill()
        }
        bounds.fill()
        if let label = instanceLabel {
            (label as NSString).draw(at: NSPoint(x: 40, y: bounds.midY - 120), withAttributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
                .font: NSFont.boldSystemFont(ofSize: 200)
            ])
        }

        let layout = model.layout
        if let left = layout.leftArea {
            drawStrip(left, color: Self.leftColor, caption: "LEFT OF CAMERA", clicks: model.leftClicks)
        }
        if let right = layout.rightArea {
            drawStrip(right, color: Self.rightColor, caption: "RIGHT OF CAMERA", clicks: model.rightClicks)
        }
        drawPulses(clippedTo: [layout.leftArea, layout.rightArea].compactMap { $0 })

        let card = cardRect
        let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A strip beside the housing: solid colour, a faint diagonal pattern so
    /// coverage is obvious at the edges, and the click count.
    private func drawStrip(_ area: NSRect, color: NSColor, caption: String, clicks: Int) {
        color.setFill()
        area.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: area).addClip()
        let stripes = NSBezierPath()
        var x = area.minX - area.height
        while x < area.maxX {
            stripes.move(to: NSPoint(x: x, y: area.maxY))
            stripes.line(to: NSPoint(x: x + area.height, y: area.minY))
            x += 12
        }
        NSColor.white.withAlphaComponent(0.18).setStroke()
        stripes.lineWidth = 3
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let text = NSMutableAttributedString(string: caption, attributes: [
            .foregroundColor: NSColor.black.withAlphaComponent(0.8),
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .kern: 0.8
        ])
        text.append(NSAttributedString(
            string: "   \(clicks) \(clicks == 1 ? "click" : "clicks")  ·  click anywhere here",
            attributes: [.foregroundColor: NSColor.black.withAlphaComponent(0.75),
                         .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]))
        let size = text.size()
        guard area.width > size.width + 24 else { return }
        text.draw(at: NSPoint(x: area.minX + 16, y: area.midY - size.height / 2))
    }

    private func drawPulses(clippedTo areas: [NSRect]) {
        guard !pulses.isEmpty, !areas.isEmpty else { return }
        let now = CACurrentMediaTime()
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath()
        for area in areas { clip.appendRect(area) }
        clip.addClip()
        for pulse in pulses {
            let t = CGFloat(min(1, (now - pulse.start) / Self.pulseDuration))
            let radius = 6 + 34 * t
            let ring = NSBezierPath(ovalIn: NSRect(x: pulse.point.x - radius, y: pulse.point.y - radius,
                                                   width: 2 * radius, height: 2 * radius))
            NSColor.white.withAlphaComponent(0.55 * (1 - t)).setFill()
            ring.fill()
            NSColor.white.withAlphaComponent(1 - t).setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Small coloured status indicator.
private final class StatusDot: NSView {
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 9, height: 9) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
