// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
// Internal: AppKit's fullscreen titlebar window for one FullPanel window. Not public API.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// In native fullscreen, AppKit puts a window's titlebar (and toolbar) into a
/// separate child window that slides in with the menu bar. This object is the
/// only part of FullPanelKit that touches that window:
///
/// - **Reveal sensing.** AppKit fades the titlebar window from alpha 0 to 1
///   while a menu-bar reveal is on screen and back to 0 when it has gone
///   (measured with Tools/BehaviorProbes/RevealSignals). Its `alphaValue` is
///   observed with KVO, so there is no polling and no method replacement.
///   A reveal starts only while AppKit also intends the menu bar to be shown
///   (`+[NSMenu menuBarVisible]`): with "Always show toolbar in full screen"
///   the titlebar window is opaque without a reveal. Without a titlebar
///   window, `menuBarVisible` alone is used.
/// - **Pass-through.** The titlebar window lies over the band. While no reveal
///   is on screen it ignores the mouse, so clicks reach the content beside the
///   camera housing. Its original setting is restored on `-stop`.
///
/// Main thread only.
@interface FPKFullScreenTitlebar : NSObject

- (instancetype)initWithWindow:(NSWindow *)window
                      onChange:(void (^)(void))onChange NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// YES while a menu-bar reveal is on screen over the window's Space.
@property (nonatomic, readonly) BOOL revealVisible;
/// The titlebar window currently followed, if any.
@property (nonatomic, readonly, nullable) NSWindow *titlebarWindow;
/// "titlebar-alpha" or "menu-intent" (no titlebar window found).
@property (nonatomic, readonly) NSString *source;
/// Whether pass-through is requested; applied to the current (and any
/// recreated) titlebar window.
@property (nonatomic) BOOL passThrough;
/// Regression diagnostic (FullPanelHideTitlebarContent, default NO): while
/// passing clicks through, also hide the titlebar window's frame view, as
/// an earlier version did. Set before -start.
@property (nonatomic) BOOL hidesContentWhilePassingThrough;

/// Begins following the window's titlebar window. Idempotent.
- (void)start;
/// Stops observing and restores the titlebar window's mouse handling.
/// Idempotent; safe when the windows are gone.
- (void)stop;
/// Re-finds the titlebar window (AppKit can recreate it, for example around
/// Mission Control) and re-reads the reveal state. Cheap.
- (void)refresh;
/// One line for FullPanelTrace.
- (NSString *)traceDescription;

@end

NS_ASSUME_NONNULL_END
