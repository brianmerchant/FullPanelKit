// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

// Plain CoreFoundation types only, so the pure decision logic in
// FPKDecisions.h stays independent of AppKit.
#include <CoreFoundation/CoreFoundation.h>

CF_ASSUME_NONNULL_BEGIN

/// Coarse FullPanel state for one window.
typedef CF_ENUM(long, FullPanelState) {
    /// `fullPanelEnabled` is NO. The window behaves exactly like NSWindow.
    FullPanelStateDisabled = 0,
    /// Enabled, but the window is not in a FullPanel fullscreen session
    /// (windowed, or between sessions).
    FullPanelStateInactive = 1,
    /// Native fullscreen Space whose window frame covers the whole display,
    /// including the areas beside the camera housing.
    FullPanelStateActive = 2,
    /// Native fullscreen, but ordinary AppKit fullscreen is being used.
    /// See `fullPanelFallbackReason`.
    FullPanelStateFallback = 3,
} CF_SWIFT_NAME(FullPanelState);

/// Why a fullscreen session is using ordinary AppKit fullscreen.
typedef CF_ENUM(long, FullPanelFallbackReason) {
    FullPanelFallbackReasonNone = 0,
    /// The window's screen has no camera housing (safeAreaInsets.top == 0),
    /// e.g. an external display. Ordinary fullscreen is correct here.
    FullPanelFallbackReasonNoCameraHousing = 1,
    /// The private AppKit fullscreen layout method is missing, its Objective-C
    /// type encoding changed, or other code replaced it; the entry is ordinary
    /// fullscreen.
    FullPanelFallbackReasonAppKitUnavailable = 2,
    /// The private SkyLight menu-bar functions could not be resolved.
    FullPanelFallbackReasonSkyLightUnavailable = 3,
    /// System Settings: "Always show menu bar in full screen" is on.
    FullPanelFallbackReasonMenuBarAlwaysShown = 4,
    /// AppKit did not give the window the whole display (e.g. Split View).
    FullPanelFallbackReasonFrameNotAccepted = 5,
} CF_SWIFT_NAME(FullPanelFallbackReason);

CF_ASSUME_NONNULL_END
