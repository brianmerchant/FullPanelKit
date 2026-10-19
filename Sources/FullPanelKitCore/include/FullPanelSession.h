// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

#import <AppKit/AppKit.h>
#import "FullPanelTypes.h"
#import "FullPanelDisplayGeometry.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted (object = the FullPanelSession) whenever `state`, `fallbackReason`,
/// `isEnabled`, `isAttached` or the window's screen may have changed. Always
/// posted on the main thread.
FOUNDATION_EXPORT NSNotificationName const FullPanelSessionStateDidChangeNotification
    NS_SWIFT_NAME(FullPanelSession.stateDidChangeNotification);

FOUNDATION_EXPORT NSErrorDomain const FullPanelSessionErrorDomain;

/// Why `+attachToWindow:error:` refused a window.
typedef NS_ERROR_ENUM(FullPanelSessionErrorDomain, FullPanelSessionError) {
    /// Called off the main thread.
    FullPanelSessionErrorNotMainThread = 1,
    /// The window is a FullPanelWindow; use its own `fullPanelEnabled`.
    FullPanelSessionErrorFullPanelWindow = 2,
    /// The window's class is one of AppKit's own (NSWindow, NSPanel, ...).
    /// Attaching to AppKit's own window classes is not supported. Create the
    /// window as a FullPanelWindow, or as your own NSWindow subclass, instead.
    FullPanelSessionErrorUnsupportedWindowClass = 3,
    /// Not returned by this version: attaching installs nothing on the
    /// window's class. Kept so that existing code that handles it compiles.
    FullPanelSessionErrorHookInstallationFailed = 4,
} NS_SWIFT_NAME(FullPanelSessionError);

/// FullPanel for an existing window that FullPanelKit did not create, such as a
/// SwiftUI `WindowGroup` window. The window keeps its identity, class,
/// delegate, window controller and scene.
///
///     let session = try FullPanelSession.attach(to: window)
///     session.isEnabled = true
///
/// Fullscreen is the same genuine AppKit fullscreen Space and the same engine
/// as FullPanelWindow, with the same fallback to ordinary fullscreen.
///
/// Ownership and lifetime:
///  - The window owns its session. Keeping a reference is optional;
///    `+sessionForWindow:` returns it again. The session holds the window weakly,
///    so there is no retain cycle.
///  - At most one session per window. Attaching again returns the same session
///    while it is attached.
///  - `-detach` restores the menu bar, presentation options and window style,
///    and removes every observer. A detached session is inert. Attach again for
///    a new session.
///  - When the window closes, system state is restored, as for FullPanelWindow;
///    the session stays attached in case the window is shown again. When the
///    window deallocates, the session detaches (`isAttached` becomes NO, with
///    KVO and a state notification) and is released unless you still hold it.
///
/// How it works: attaching changes nothing about the window's class. Its class,
/// runtime class and method implementations stay as they are; the session is
/// an associated object of the window and observes its notifications. While a
/// FullPanel entry is under way, FullPanelKit answers AppKit's private
/// "reserve the menu-bar band?" question for this window's fullscreen content
/// controller with NO, so AppKit lays the window out over the whole display
/// itself. That answer comes from one replacement of a method of AppKit's
/// fullscreen content controller class, installed at the first enable in the
/// process and passing AppKit's own answer through for every other window.
///
/// Requirements (see docs/ATTACHMENT.md):
///  - Main thread only.
///  - Enable before the window's fullscreen entry begins. Any native entry
///    works: -toggleFullScreen: (the green button, View ▸ Enter Full Screen,
///    Control-Command-F) and AppKit's own, such as restoring a window into
///    fullscreen at launch. A window already in fullscreen is not adopted in
///    place: the session reports `.fallback` with `diagnostics()["adoption"]`,
///    and FullPanel applies from the next entry. See docs/RESTORED_FULLSCREEN.md.
///  - The window's delegate is not changed, and FullPanelKit does not answer
///    `window:willUseFullScreenContentSize:`.
NS_SWIFT_NAME(FullPanelSession)
@interface FullPanelSession : NSObject

/// Attaches FullPanel to `window`, or returns its existing session. The session
/// starts disabled.
+ (nullable FullPanelSession *)attachToWindow:(NSWindow *)window
                                        error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(attach(to:));

/// The attached session of `window`, if any.
+ (nullable FullPanelSession *)sessionForWindow:(NSWindow *)window
    NS_SWIFT_NAME(session(for:));

/// YES when this process can use FullPanel at all (same check as
/// FullPanelWindow.fullPanelSystemSupportAvailable).
+ (BOOL)systemSupportAvailable;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The attached window, or nil once it has been deallocated.
@property (nonatomic, readonly, weak, nullable) NSWindow *window;

/// NO after `-detach` (KVO-compliant).
@property (nonatomic, readonly, getter=isAttached) BOOL attached;

/// Opt in to FullPanel for this window. Default NO. Same semantics as
/// FullPanelWindow.fullPanelEnabled: enabling applies `.fullSizeContentView`,
/// a transparent titlebar and `.fullScreenPrimary`, and disabling restores the
/// previous values (after fullscreen exits, if it is in fullscreen). Disabling
/// during a FullPanel session restores the menu bar at once. Setting it on a
/// detached session does nothing. KVO-compliant.
@property (nonatomic, getter=isEnabled) BOOL enabled;

/// Current state (KVO-compliant; also see FullPanelSessionStateDidChangeNotification).
@property (nonatomic, readonly) FullPanelState state;

/// Why the current or last fullscreen session fell back; None otherwise.
@property (nonatomic, readonly) FullPanelFallbackReason fallbackReason;

/// YES while the window is in a native fullscreen Space covering the whole
/// display, including the camera-housing band.
@property (nonatomic, readonly, getter=isActive) BOOL active;

/// Geometry of the window's current screen, or nil when it has no screen.
@property (nonatomic, readonly, nullable) FullPanelDisplayGeometry *geometry;

/// Converts a rect in global screen coordinates (e.g. from `geometry`) into
/// `view`'s coordinate space.
- (NSRect)convertScreenRect:(NSRect)screenRect toView:(NSView *)view
    NS_SWIFT_NAME(convertScreenRect(_:to:));

/// Restores the menu bar and presentation state immediately. The session does
/// this itself on fullscreen exit, close, detach and application termination.
- (void)restoreSystemState;

/// Detaches from the window: disables FullPanel, restores system state and
/// window style, and removes all observers. Idempotent. If the window is in
/// fullscreen, it keeps its current frame until it leaves fullscreen.
- (void)detach;

/// Diagnostics snapshot (the FullPanelWindow keys plus attachment details).
/// Values are informational; keys may change.
- (NSDictionary<NSString *, id> *)diagnostics;

@end

NS_ASSUME_NONNULL_END
