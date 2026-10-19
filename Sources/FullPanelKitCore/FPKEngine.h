// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// History: in earlier, unpublished versions this file declared titlebar and
// menu-bar reveal / presentation state adapted from UTM's
// Platform/macOS/Display/VMDisplayWindow.swift (Copyright © 2026 Turing
// Software, LLC, Apache-2.0). The redesign removed that state; the engine
// keeps observed facts and the last applied system state for its reconciler
// (FPKIntentForFacts). See docs/PROVENANCE.md.
//
// Internal: the per-window FullPanel engine. Not public API.
//
// The engine is the hardware-tested FullPanelWindow engine moved into its own
// object so it can drive either a FullPanelWindow (which hosts it) or an
// existing window attached through FullPanelSession. Methods and instance
// variables keep their probe names; `self` (the window) became `window`.

#import <AppKit/AppKit.h>
#import "FullPanelTypes.h"
#import "FPKDecisions.h"

NS_ASSUME_NONNULL_BEGIN

@class FPKFullScreenTitlebar;

/// The object that publishes an engine's state: FullPanelWindow or
/// FullPanelSession. Called on the main thread, in the original KVO order.
@protocol FPKEngineHost <NSObject>
- (void)fpkEngineStateWillChange:(BOOL)stateChanged reason:(BOOL)reasonChanged;
- (void)fpkEngineStateDidChange:(BOOL)stateChanged reason:(BOOL)reasonChanged;
- (void)fpkEnginePostStateChange;
@end

@interface FPKEngine : NSObject {
@public
    // ---- Engine state (names kept from the hardware-tested probe) ----
    BOOL _fpArmed;
    BOOL _fpAccepted;
    BOOL _fpEnteringOrInside;
    BOOL _fpLost;
    NSString *_fpError;
    int32_t _fpLastSkyLightStatus;
    BOOL _fpReturnPending;
    unsigned _fpReturnChecksLeft;
    BOOL _fpReturnRearmed;   // the pending check restarted at the actual return
    BOOL _fpReturnFromAway;  // the pending check follows an actual return
    BOOL _fpReassertScheduled;   // presentation re-assert in flight
    // Return-transition tracking (diagnostics + early apply).
    BOOL _fpAway;            // left Space/key/active/visible since last commit
    double _fpAwayAtMs;
    double _fpReturnStartMs;
    int _fpLastCompositor;   // last traced compositor state; 2 = none yet
    // ---- Engagement and system state (reconciler) ----
    // Space whose menu-bar backdrop FullPanel overrides; 0 when none. The
    // value submitted last for it. Submitted, not visually verified.
    uint64_t _fpkOverlaySpace;
    BOOL _fpkOverlayBackdropVisible;
    // Facts. Latched per entry: deliberate reveals allowed (option).
    BOOL _fpkRevealSupported;
    // Pointer monitor, presentation KVO and titlebar companion are running.
    BOOL _fpkTracking;
    BOOL _fpkRevealRequested;             // FPKRevealRequestAfterMove
    BOOL _fpkRevealVisible;               // FPKFullScreenTitlebar
    BOOL _fpkReleasing;                   // return re-assert holds options released
    // Applied presentation: FullPanel's forced options are in effect, and the
    // options read just before this session first forced them.
    BOOL _fpkForcing;
    BOOL _fpkPresentationBeforeForcingValid;
    NSApplicationPresentationOptions _fpkPresentationBeforeForcing;
    FPKFullScreenTitlebar *_fpkTitlebar;
    id _fpkPointerMonitor;
    BOOL _fpkSavedAcceptsMouseMoved;
    BOOL _fpkObservingPresentation;
    NSString *_fpkLastTitlebarTrace;      // FullPanelTrace: changes only
    // AppKit's fullscreen presentation policy (with the application's own), seen
    // in native fullscreen before FullPanel forced its value; restored on detach
    // or disable while the window stays in fullscreen.
    BOOL _fpNativeFullScreenPresentationValid;
    NSApplicationPresentationOptions _fpNativeFullScreenPresentation;
    NSString *_fpLastPresentationRestore;  // diagnostics: requested and read-back result
    // Trace-only state sampler (FullPanelTrace): bounded, logs changes only.
    double _fpDiagUntilMs;
    BOOL _fpDiagRunning;
    NSString *_fpDiagLast;

    // ---- Library state (not in the probe) ----
    BOOL _enabled;                        // fullPanelEnabled / FullPanelSession.isEnabled
    FullPanelState _fpkState;
    FullPanelFallbackReason _fpkFallbackReason;   // published
    FullPanelFallbackReason _fpkSessionReason;    // current entry attempt
    NSMutableArray *_fpkObservers;        // notification tokens
    BOOL _fpkStyleApplied;                // our style changes are in effect
    BOOL _fpkStyleSyncPending;            // apply after fullscreen exit
    BOOL _fpkSavedFullSizeContent;
    BOOL _fpkSavedTitlebarTransparent;
    BOOL _fpkSavedFullScreenPrimary;
    // Enabled while windowed (or windowed again after an exit) and no entry
    // prepared since: the entry's reservation request may prepare it (P2).
    BOOL _fpkUnpreparedEntryAllowed;
    NSString *_fpkEntryPreparedBy;        // diagnostics: path that prepared this entry
    NSString *_fpkAdoption;               // diagnostics: entry under way when enabled
    // The fullscreen Space is on a screen without a camera housing: system
    // state released, entry still armed (FPKScreenReleasesSession).
    BOOL _fpkScreenReleased;
    NSString *_fpkLastWindowStateTrace;   // FullPanelTrace: log changes only
    // Inside willExitFullScreen: AppKit's exit transition owns the
    // presentation options and applies the windowed ones after the exit.
    BOOL _fpkExitTransition;
    // Latched when the entry is prepared and armed: the menu-bar reservation
    // hook answers NO for this window, AppKit's own layout holds the display,
    // and the entry is accepted once verified (P1). NO: ordinary fullscreen.
    BOOL _fpkReservationEntry;
    // The entry did not reach the whole display at didEnterFullScreen (e.g.
    // Split View); the hook stops claiming the band.
    BOOL _fpkEntryRejected;
    NSUInteger _fpkReservationRequests;   // diagnostics
    NSString *_fpkLastReservationTrace;   // FullPanelTrace: changes only
    // Regression diagnostics, latched per entry (default NO): keep the
    // options forced while the Space is away and the window is still key
    // (FullPanelForceWhileAway), and hide the titlebar window's content while
    // it passes clicks through (FullPanelHideTitlebarContent).
    BOOL _fpkForceWhileAway;
}

- (instancetype)initWithWindow:(NSWindow *)window
                          host:(id<FPKEngineHost>)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, weak, nullable) NSWindow *window;
@property (nonatomic) BOOL enabled;
@property (nonatomic, readonly) FullPanelState state;
@property (nonatomic, readonly) FullPanelFallbackReason fallbackReason;
@property (nonatomic, readonly) BOOL styleSyncPending;

- (void)installLifecycleObservers;
/// Removes observers and restores system state. Idempotent; safe after the
/// window is gone.
- (void)teardown;

/// The reservation hook's call for this window's fullscreen content
/// controller, after AppKit answered YES. Prepares an entry whose
/// willEnterFullScreen the engine did not receive (P2), then returns YES when
/// the window claims the band (AppKit is told NO).
- (BOOL)fpkAnswerReservationRequest;
- (void)fullPanelWillExitFullScreen;
/// The window's screen (or the display configuration) changed: releases or
/// resumes FullPanel for a fullscreen Space on a screen with(out) a housing.
- (void)fpkScreenChanged;
/// FullPanelTrace only: one structured line of window, screen, Space and
/// presentation state, logged when it differs from the previous one.
- (void)fpkTraceWindowState:(NSString *)why;
- (void)fpkSyncStyle;
- (void)fpkUpdateState;
- (NSDictionary<NSString *, id> *)diagnostics;

@end

/// The engine driving `window`: its FullPanelWindow engine or its attached
/// session's engine. nil for every other window.
FPKEngine *_Nullable FPKEngineForWindow(NSWindow *window);
/// YES when an entry can use the menu-bar reservation hook now
/// (FPKMenuBarReservationAvailable, unless FullPanelSimulateNoReservation);
/// NO means entries are ordinary fullscreen.
BOOL FPKReservationGeometryAvailable(void);
/// The attached session's engine only (nil for FullPanelWindow and others).
FPKEngine *_Nullable FPKAttachedEngineForWindow(id window);

NS_ASSUME_NONNULL_END
