// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

import AppKit
import CoreGraphics

/// Camera-housing layout in a window's content coordinates with a TOP-LEFT
/// origin (SwiftUI's coordinate space for a view filling the window).
///
/// Use it to place content beside the camera housing and to keep important
/// content out of `cameraHousing`.
public struct FullPanelLayout: Equatable {
    /// FullPanel state of the window this layout belongs to.
    public var state: FullPanelState
    /// Why the current or last fullscreen session used standard fullscreen.
    public var fallbackReason: FullPanelFallbackReason
    /// Size of the window's content area.
    public var contentSize: CGSize
    /// Display area left of the camera housing, clipped to the content area.
    /// `nil` when it is not inside the window (e.g. windowed mode).
    public var leftArea: CGRect?
    /// Display area right of the camera housing, clipped to the content area.
    public var rightArea: CGRect?
    /// Physical camera-housing exclusion zone, clipped to the content area.
    public var cameraHousing: CGRect?
    /// Height of the housing band at the top of the display (0 if none).
    public var topInset: CGFloat

    /// `true` when FullPanel is active and both side areas are inside the window.
    public var isActive: Bool { state == .active && leftArea != nil && rightArea != nil }

    public init(state: FullPanelState = .disabled,
                fallbackReason: FullPanelFallbackReason = .none,
                contentSize: CGSize = .zero,
                leftArea: CGRect? = nil, rightArea: CGRect? = nil,
                cameraHousing: CGRect? = nil, topInset: CGFloat = 0) {
        self.state = state
        self.fallbackReason = fallbackReason
        self.contentSize = contentSize
        self.leftArea = leftArea
        self.rightArea = rightArea
        self.cameraHousing = cameraHousing
        self.topInset = topInset
    }

    /// Builds a layout from display geometry (AppKit global coordinates) and
    /// the window frame. Assumes the content view fills the window frame,
    /// which FullPanelWindow and an enabled FullPanelSession guarantee by
    /// using a full-size content view.
    public init(geometry: FullPanelDisplayGeometry?, windowFrame: CGRect,
                state: FullPanelState, fallbackReason: FullPanelFallbackReason) {
        let size = windowFrame.size
        let bounds = CGRect(origin: .zero, size: size)
        func local(_ screenRect: CGRect) -> CGRect? {
            guard !screenRect.isEmpty else { return nil }
            // AppKit global (bottom-left) -> window-local top-left.
            let r = CGRect(x: screenRect.minX - windowFrame.minX,
                           y: windowFrame.maxY - screenRect.maxY,
                           width: screenRect.width, height: screenRect.height)
            let clipped = r.intersection(bounds)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
        self.init(state: state, fallbackReason: fallbackReason, contentSize: size,
                  leftArea: geometry.flatMap { local($0.auxiliaryLeftArea) },
                  rightArea: geometry.flatMap { local($0.auxiliaryRightArea) },
                  cameraHousing: geometry.flatMap { local($0.cameraHousingRect) },
                  topInset: geometry?.topInset ?? 0)
    }
}

extension FullPanelWindow {
    /// Current layout in this window's content coordinates (top-left origin).
    public var fullPanelLayout: FullPanelLayout {
        FullPanelLayout(geometry: fullPanelGeometry, windowFrame: frame,
                        state: fullPanelState, fallbackReason: fullPanelFallbackReason)
    }
}

extension FullPanelSession {
    /// Current layout in the attached window's content coordinates (top-left
    /// origin). Empty once the window is gone.
    public var layout: FullPanelLayout {
        guard let window else { return FullPanelLayout(state: state, fallbackReason: fallbackReason) }
        return FullPanelLayout(geometry: geometry, windowFrame: window.frame,
                               state: state, fallbackReason: fallbackReason)
    }
}
