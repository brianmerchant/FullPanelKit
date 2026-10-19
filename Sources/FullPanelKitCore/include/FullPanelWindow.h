// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

#import <AppKit/AppKit.h>
#import "FullPanelTypes.h"
#import "FullPanelDisplayGeometry.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted (object = the FullPanelWindow) whenever `fullPanelState`,
/// `fullPanelFallbackReason` or the window's screen may have changed.
/// Always posted on the main thread.
FOUNDATION_EXPORT NSNotificationName const FullPanelWindowStateDidChangeNotification
    NS_SWIFT_NAME(FullPanelWindow.stateDidChangeNotification);

/// Human-readable description of a fallback reason (status UI, logs).
FOUNDATION_EXPORT NSString *FullPanelFallbackReasonDescription(FullPanelFallbackReason reason)
    NS_SWIFT_NAME(getter:FullPanelFallbackReason.summary(self:));

/// A native-fullscreen-capable window whose fullscreen frame covers the
/// entire display, including the regions beside a MacBook camera housing.
///
/// Use it exactly like NSWindow:
///
///     let window = FullPanelWindow(contentRect: rect,
///                                  styleMask: [.titled, .closable, .resizable],
///                                  backing: .buffered, defer: false)
///     window.fullPanelEnabled = true
///     window.toggleFullScreen(nil)
///
/// Fullscreen is always a genuine AppKit fullscreen Space (Mission Control,
/// Spaces, menu-bar reveal and exit work as usual). When FullPanel is not
/// possible — external display, Split View, missing private API, "always show
/// menu bar" — the window falls back to ordinary AppKit fullscreen and
/// reports why through `fullPanelState` / `fullPanelFallbackReason`.
///
/// The window observes its own fullscreen, key, occlusion, screen and Space
/// notifications; the application does not need to forward any events.
///
/// Requirements and limitations (see docs/COMPATIBILITY.md):
///  - Only FullPanelWindow (and subclasses) are affected. Other windows in the
///    process keep standard AppKit behavior. For a window you do not create
///    (e.g. SwiftUI WindowGroup), use FullPanelSession instead.
///  - Any native fullscreen entry works: `-toggleFullScreen:` (the green
///    button, View ▸ Enter Full Screen, Control-Command-F) and AppKit's own,
///    such as restoring the window into fullscreen at launch. Enable FullPanel
///    before the entry begins; a window already in fullscreen gets FullPanel
///    from its next entry (docs/RESTORED_FULLSCREEN.md).
///  - The window must be on the main thread, like any NSWindow.
///  - `delegate` is your own delegate object; FullPanelWindow does not wrap it
///    and does not answer `window:willUseFullScreenContentSize:`.
///  - FullPanelWindow overrides no frame setter and not `-toggleFullScreen:`;
///    a subclass that overrides `-toggleFullScreen:` must call super for the
///    window to enter fullscreen, as with any NSWindow.
NS_SWIFT_NAME(FullPanelWindow)
@interface FullPanelWindow : NSWindow

/// Opt in to FullPanel for this window. Default NO.
///
/// Enabling also sets `.fullSizeContentView`, a transparent titlebar and the
/// `.fullScreenPrimary` collection behavior (the hardware-tested
/// configuration); disabling restores the previous values. Style changes made
/// while the window is in fullscreen are applied after fullscreen exits.
///
/// Disabling while a FullPanel fullscreen session is running immediately
/// restores the menu bar and presentation options; the window keeps its
/// current frame until it leaves fullscreen.
@property (nonatomic) BOOL fullPanelEnabled;

/// Current state (KVO-compliant; also see FullPanelWindowStateDidChangeNotification).
@property (nonatomic, readonly) FullPanelState fullPanelState;

/// Why the current/last fullscreen session fell back; None otherwise.
@property (nonatomic, readonly) FullPanelFallbackReason fullPanelFallbackReason;

/// YES while the window is in a native fullscreen Space covering the whole
/// display including the camera-housing band.
@property (nonatomic, readonly, getter=isFullPanelActive) BOOL fullPanelActive;

/// Geometry of the window's current screen, or nil when it has no screen.
@property (nonatomic, readonly, nullable) FullPanelDisplayGeometry *fullPanelGeometry;

/// Converts a rect in global screen coordinates (e.g. from
/// `fullPanelGeometry`) into `view`'s coordinate space.
- (NSRect)fullPanelConvertScreenRect:(NSRect)screenRect toView:(NSView *)view
    NS_SWIFT_NAME(fullPanelConvertScreenRect(_:to:));

/// YES when this process can use FullPanel at all: AppKit's private
/// fullscreen layout method FullPanel relies on (the menu-bar reservation of
/// the fullscreen content controller) resolves with the expected encoding, and
/// SkyLight resolves. This does not check the display or the "always show menu
/// bar" setting. When it is NO, entries are ordinary fullscreen.
+ (BOOL)fullPanelSystemSupportAvailable;

/// Restores menu bar and presentation state immediately. The window calls this
/// itself on fullscreen exit, close and application termination; call it only
/// if you tear the window down by unusual means.
- (void)fullPanelRestoreSystemState;

/// Opt-in diagnostics snapshot (geometry, private-API readiness, Space ID,
/// compositor state). Values are informational; keys may change.
- (NSDictionary<NSString *, id> *)fullPanelDiagnostics;

@end

NS_ASSUME_NONNULL_END
