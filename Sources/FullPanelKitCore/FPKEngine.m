// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// History: earlier, unpublished versions of this file contained portions
// adapted from UTM's Platform/macOS/Display/VMDisplayWindow.swift (Copyright
// © 2026 Turing Software, LLC, Apache-2.0): the arming conditions, the
// menu-bar alpha commit, the fullscreen titlebar-window handling, and the
// menu-bar reveal and presentation-options logic.
// Those portions were removed or replaced by a later redesign (by authors who
// had read them; not a clean-room implementation). See docs/PROVENANCE.md.
//
// FullPanel engine. Extracted from the hardware-tested FullPanel Notch Probe
// v0.4 (commit 4660e21, tag fullpanel-reveal-hardware-tested), FPWindow.m and
// the event forwarding in its main.swift; docs/HARDWARE_BASELINE.md maps it.
//
//   (1) whole-display geometry: the menu-bar reservation hook
//       (FPKAppKitHooks.m) tells AppKit the window does not reserve the band,
//       so AppKit lays it out over the display itself; the entry is accepted
//       once verified (P1). Earlier versions used a
//       `_frameForFullScreenMode` override plus frame guards, now removed.
//   (2) SkyLight menu-bar overlay for the window's own fullscreen Space
//   (3) reveal sensing (titlebar window) + presentation reconciler
//   (4) compositor-verified Mission Control / Space return
//
// Until 0.2 this code lived in FullPanelWindow.m with the window as `self`.
// It moved here unchanged except that the window is now `window` (a weak
// reference loaded once per method), so the same engine can drive a
// FullPanelWindow or an existing window attached with FullPanelSession.
//
// Fullscreen is always AppKit's own: -toggleFullScreen: creates the Space.
//
// Designed in the redesign described in docs/PROVENANCE.md:
//   - entry preparation at willEnterFullScreen for every entry (no
//     -toggleFullScreen: wrapper; measured entry order);
//   - a capability check (FPKFallbackForCapabilities);
//   - a reconciler: observed facts -> FPKIntentForFacts -> one apply step for
//     the menu-bar overlay (FPKMenuBarOverlay.m), the presentation options
//     and the titlebar window's mouse handling;
//   - reveal sensing through AppKit's titlebar window (FPKFullScreenTitlebar.m),
//     with a pointer-zone latch (FPKPointerZoneAt, FPKRevealRequestAfterMove).
// The Mission Control return recovery, adoption, display release and
// presentation ownership are FullPanelKit's own and unchanged in behaviour;
// they now drive the reconciler.

#if !__has_feature(objc_arc)
#error FullPanelKitCore must be compiled with ARC (-fobjc-arc).
#endif

#import "FPKEngine.h"
#import "FPKAppKitHooks.h"
#import "FPKDecisions.h"
#import "FPKSupport.h"
#import "FPKMenuBarOverlay.h"
#import "FPKFullScreenTitlebar.h"
#import "FullPanelWindow.h"

static char kFPKSystemPresentationContext;

static BOOL fpInFullScreen(NSWindow *w) {
    return (w.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

// Engines currently forcing the app-global presentation options.
static NSHashTable<FPKEngine *> *fpForcingEngines(void) {
    static NSHashTable *engines;
    if (!engines) engines = [NSHashTable weakObjectsHashTable];
    return engines;
}

static BOOL fpCoversScreen(NSWindow *w) {
    return w.screen && FPKRectsNearlyEqual(NSRectToCGRect(w.frame),
                                           NSRectToCGRect(w.screen.frame));
}

// FullPanel applies only beside a camera housing (FPKScreenReleasesSession).
// Both are NO without a screen: during a display reconfiguration a window can
// briefly have none, which is neither.
static BOOL fpScreenHasHousing(NSWindow *w) {
    NSScreen *screen = w.screen;
    return screen && screen.safeAreaInsets.top > 0;
}

static BOOL fpScreenWithoutHousing(NSWindow *w) {
    NSScreen *screen = w.screen;
    return screen && screen.safeAreaInsets.top <= 0;
}

// Diagnostic FullPanelSimulateNoReservation (default NO): entries behave as
// on a macOS without the reservation methods (the fallback test).
static BOOL fpSimulateNoReservation(void) {
    return FPKOption(@"FullPanelSimulateNoReservation", NO);
}

BOOL FPKReservationGeometryAvailable(void) {
    return !fpSimulateNoReservation() && FPKMenuBarReservationAvailable();
}

@implementation FPKEngine {
    __weak NSWindow *_window;
    __weak id<FPKEngineHost> _host;
}

- (instancetype)initWithWindow:(NSWindow *)window host:(id<FPKEngineHost>)host {
    if ((self = [super init])) {
        _window = window;
        _host = host;
        _fpLastCompositor = 2;
        _fpkState = FullPanelStateDisabled;
        _fpkFallbackReason = FullPanelFallbackReasonNone;
    }
    return self;
}

- (NSWindow *)window { return _window; }
- (FullPanelState)state { return _fpkState; }
- (FullPanelFallbackReason)fallbackReason { return _fpkFallbackReason; }
- (BOOL)styleSyncPending { return _fpkStyleSyncPending; }

// Lifecycle signals the probe's app delegate forwarded by hand. They are
// observed here so integrating applications do not have to.
- (void)installLifecycleObservers {
    NSWindow *window = _window;
    if (!window || _fpkObservers) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSMutableArray *tokens = [NSMutableArray array];
    __weak FPKEngine *weakSelf = self;
    void (^observe)(NSNotificationName, id, void (^)(FPKEngine *)) =
        ^(NSNotificationName name, id object, void (^handler)(FPKEngine *)) {
            [tokens addObject:[center addObserverForName:name object:object queue:nil
                                              usingBlock:^(NSNotification *note) {
                FPKEngine *strongSelf = weakSelf;
                if (strongSelf) handler(strongSelf);
            }]];
        };

    observe(NSWindowDidBecomeKeyNotification, window, ^(FPKEngine *e) {
        if (!e->_enabled) return;
        [e fullPanelNoteEvent:@"didBecomeKey"];
        [e fullPanelReapplyMenuIfNeeded];
    });
    observe(NSWindowDidResignKeyNotification, window, ^(FPKEngine *e) {
        if (e->_enabled) [e fullPanelNoteEvent:@"didResignKey"];
    });
    observe(NSApplicationDidBecomeActiveNotification, nil, ^(FPKEngine *e) {
        if (!e->_enabled) return;
        [e fullPanelNoteEvent:@"appDidBecomeActive"];
        [e fullPanelReapplyMenuIfNeeded];
    });
    observe(NSApplicationDidResignActiveNotification, nil, ^(FPKEngine *e) {
        if (e->_enabled) [e fullPanelNoteEvent:@"appDidResignActive"];
    });
    observe(NSWindowDidChangeOcclusionStateNotification, window, ^(FPKEngine *e) {
        if (!e->_enabled) return;
        [e fullPanelNoteEvent:@"occlusionChanged"];
        NSWindow *w = e->_window;
        if (fpInFullScreen(w) && (w.occlusionState & NSWindowOcclusionStateVisible)) {
            [e fullPanelReapplyMenuIfNeeded];
        }
    });
    observe(NSWindowWillEnterFullScreenNotification, window, ^(FPKEngine *e) {
        [e fpkTraceWindowState:@"willEnterFullScreen"];
        [e fpkWillEnterFullScreen];
    });
    observe(NSWindowDidEnterFullScreenNotification, window, ^(FPKEngine *e) {
        FPKTrace(@"didEnterFullScreen", nil);
        if (e->_enabled) [e fullPanelDidEnterFullScreen];
        [e fpkUpdateState];
        [e fpkTraceWindowState:@"didEnterFullScreen"];
    });
    observe(NSWindowWillExitFullScreenNotification, window, ^(FPKEngine *e) {
        FPKTrace(@"willExitFullScreen", nil);
        e->_fpkUnpreparedEntryAllowed = NO;   // reservation requests now belong to the exit
        e->_fpkExitTransition = YES;
        [e fullPanelWillExitFullScreen];
        e->_fpkExitTransition = NO;
        [e fpkUpdateStateInFullScreen:NO];
        [e fpkTraceWindowState:@"willExitFullScreen"];
    });
    observe(NSWindowDidExitFullScreenNotification, window, ^(FPKEngine *e) {
        FPKTrace(@"didExitFullScreen", nil);
        e->_fpkUnpreparedEntryAllowed = e->_enabled;   // windowed again
        if (e->_fpkStyleSyncPending) [e fpkSyncStyle];
        [e fpkUpdateStateInFullScreen:NO];
        [e fpkTraceWindowState:@"didExitFullScreen"];
    });
    observe(NSWindowWillCloseNotification, window, ^(FPKEngine *e) {
        FPKTrace(@"willClose", nil);
        [e fullPanelWillExitFullScreen];
        [e fpkUpdateStateInFullScreen:NO];
        [e fpkTraceWindowState:@"willClose"];
    });
    observe(NSApplicationWillTerminateNotification, nil, ^(FPKEngine *e) {
        // Restore menu-bar alpha and presentation options on Command-Q too.
        [e fullPanelWillExitFullScreen];
    });
    observe(NSWindowDidResizeNotification, window, ^(FPKEngine *e) {
        if (e->_enabled && fpInFullScreen(e->_window)) [e fullPanelReapplyMenuIfNeeded];
    });
    observe(NSWindowDidMoveNotification, window, ^(FPKEngine *e) {
        if (e->_enabled && fpInFullScreen(e->_window)) [e fullPanelReapplyMenuIfNeeded];
    });
    observe(NSWindowDidChangeScreenNotification, window, ^(FPKEngine *e) {
        [e fpkTraceWindowState:@"didChangeScreen"];
        [e fpkScreenChanged];
        if (e->_enabled && fpInFullScreen(e->_window)) [e fullPanelReapplyMenuIfNeeded];
        [e fpkPostStateChange];   // geometry may differ on the new screen
    });
    observe(NSApplicationDidChangeScreenParametersNotification, nil, ^(FPKEngine *e) {
        [e fpkTraceWindowState:@"screenParameters"];
        [e fpkScreenChanged];   // a display added, removed or rearranged
        [e fpkPostStateChange];
    });

    NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
    [tokens addObject:[workspace addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                                             object:nil queue:nil
                                         usingBlock:^(NSNotification *note) {
        FPKEngine *e = weakSelf;
        if (!e) return;
        if (e->_enabled) [e fullPanelNoteEvent:@"activeSpaceChanged"];
        [e fullPanelReapplyMenuIfNeeded];   // self-gated
    }]];
    _fpkObservers = tokens;
}

- (void)fpkRemoveLifecycleObservers {
    NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
    for (id token in _fpkObservers) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        [workspace removeObserver:token];
    }
    _fpkObservers = nil;
}

- (void)teardown {
    [self fpkRemoveLifecycleObservers];
    [self fullPanelWillExitFullScreen];
    [self fpkTraceWindowState:@"teardown"];
}

// ---- Enable ----------------------------------------------------------------------

- (BOOL)enabled { return _enabled; }

- (void)setEnabled:(BOOL)enabled {
    if (enabled == _enabled) return;
    _enabled = enabled;
    // Enabled on a windowed window: any later entry began after this point.
    _fpkUnpreparedEntryAllowed = enabled && _window && !fpInFullScreen(_window);
    // The reservation hook must be in place before AppKit asks this window's
    // entry, including an entry that begins inside this call (P2).
    if (enabled && FPKReservationGeometryAvailable()) {
        (void)FPKInstallMenuBarReservationHook(NULL);
    }
    // Probe behavior: turning FullPanel off restores system state at once.
    if (!enabled) [self fullPanelWillExitFullScreen];
    if (enabled) [self fpkNoteEntryAlreadyUnderway];
    [self fpkSyncStyle];
    [self fpkUpdateState];
}

// Enabled (or attached and enabled) once this window's fullscreen entry has
// begun. The entry is not adopted in place; it stays ordinary fullscreen, and
// the next entry is a FullPanel entry. Nothing is toggled here: fullscreen
// belongs to the host. With the former frame override WindowServer fixed the
// window's bounds at AppKit's first fullscreen-frame request of the entry
// (macOS 27, MacBook Pro 14": every re-layout path tried was moved back to
// the camera-safe tile). AppKit does re-lay out a fullscreen window when the
// reservation answer changes (detach in fullscreen), so adoption in place may
// now be possible; it is untested, and not attempted.
- (void)fpkNoteEntryAlreadyUnderway {
    NSWindow *window = _window;
    if (!window || !FPKEntryAlreadyUnderway(fpInFullScreen(window), _fpEnteringOrInside)) return;
    _fpkUnpreparedEntryAllowed = NO;
    _fpkEntryPreparedBy = nil;
    _fpkAdoption = @"Enabled after this fullscreen entry began; the window keeps its camera-safe "
                   @"frame in this fullscreen Space. FullPanel applies from the next entry.";
    _fpError = _fpkAdoption;
    FPKTrace(@"adopt-unavailable", [NSString stringWithFormat:
             @"frame=%@ space=%llu onActiveSpace=%d", NSStringFromRect(window.frame),
             (unsigned long long)FPKFullscreenSpaceOfWindow(window), window.isOnActiveSpace]);
    NSLog(@"FullPanelKit: %@", _fpkAdoption);
}

// ---- Style (hardware-tested configuration) ---------------------------------------

// The probe's FullPanel mode used a full-size content view, a transparent
// titlebar and the fullScreenPrimary collection behavior.
- (void)fpkSyncStyle {
    NSWindow *window = _window;
    if (!window) return;
    if (fpInFullScreen(window)) { _fpkStyleSyncPending = YES; return; }
    _fpkStyleSyncPending = NO;
    if (_enabled && !_fpkStyleApplied) {
        _fpkSavedFullSizeContent = (window.styleMask & NSWindowStyleMaskFullSizeContentView) != 0;
        _fpkSavedTitlebarTransparent = window.titlebarAppearsTransparent;
        _fpkSavedFullScreenPrimary =
            (window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0;
        window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        window.titlebarAppearsTransparent = YES;
        window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
        _fpkStyleApplied = YES;
    } else if (!_enabled && _fpkStyleApplied) {
        if (!_fpkSavedFullSizeContent) window.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
        window.titlebarAppearsTransparent = _fpkSavedTitlebarTransparent;
        if (!_fpkSavedFullScreenPrimary) {
            window.collectionBehavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
        }
        _fpkStyleApplied = NO;
    }
}

// ---- State reporting ------------------------------------------------------------------

- (void)fpkUpdateState { [self fpkUpdateStateInFullScreen:fpInFullScreen(_window)]; }

- (void)fpkUpdateStateInFullScreen:(BOOL)inFullScreen {
    // Whole display beside a housing: a fullscreen Space moved to a display
    // without one is ordinary fullscreen there (FPKScreenReleasesSession).
    BOOL housing = !fpScreenWithoutHousing(_window);
    FullPanelState state = FPKResolveState(_enabled, inFullScreen, _fpArmed,
                                           _fpAccepted, fpCoversScreen(_window) && housing);
    // Fallback: this session's reason. Inactive: keep the last session's
    // reason for status UI. Active / Disabled: none.
    FullPanelFallbackReason reason = FullPanelFallbackReasonNone;
    if (state == FullPanelStateFallback) {
        reason = FPKFullScreenFallbackReason(_fpkSessionReason, housing);
    } else if (state == FullPanelStateInactive) {
        reason = _fpkFallbackReason;
    }
    BOOL stateChanged = state != _fpkState;
    BOOL reasonChanged = reason != _fpkFallbackReason;
    id<FPKEngineHost> host = _host;
    if (stateChanged || reasonChanged) [host fpkEngineStateWillChange:stateChanged reason:reasonChanged];
    _fpkState = state;
    _fpkFallbackReason = reason;
    if (stateChanged || reasonChanged) [host fpkEngineStateDidChange:stateChanged reason:reasonChanged];
    if (stateChanged || reasonChanged) {
        FPKTrace(@"state", [NSString stringWithFormat:@"state=%ld reason=%ld",
                            (long)state, (long)reason]);
        [self fpkPostStateChange];
    }
}

- (void)fpkPostStateChange {
    [_host fpkEnginePostStateChange];
}

// ---- Fullscreen entry --------------------------------------------------------------

// Every native entry posts willEnterFullScreen before AppKit lays out the
// fullscreen window (measured on macOS 27: probe
// RevealSignals, entry order). State restoration enters through AppKit's
// _enterFullScreenModeForRestoration… and posts it too, without
// -toggleFullScreen:. The style mask does not contain FullScreen yet here.
- (void)fpkWillEnterFullScreen {
    NSWindow *window = _window;
    FPKTrace(@"willEnterFullScreen", [NSString stringWithFormat:@"fs=%d enabled=%d",
             fpInFullScreen(window), _enabled]);
    if (window && !fpInFullScreen(window)) [self fpkPrepareForEntry:@"willEnterFullScreen"];
}

// The callers decide that an entry may be prepared: windowed for
// willEnterFullScreen, FPKReservationRequestPreparesEntry for a reservation
// request (the style mask already has FullScreen then).
- (void)fpkPrepareForEntry:(NSString *)path {
    NSWindow *window = _window;
    _fpkUnpreparedEntryAllowed = NO;
    if (window) {
        _fpkEntryPreparedBy = path;
        _fpkAdoption = nil;
        _fpEnteringOrInside = YES;
        _fpAccepted = NO;
        _fpLost = NO;
        _fpArmed = NO;
        _fpError = @"";
        _fpLastSkyLightStatus = 0;
        _fpReturnPending = NO;
        _fpReturnChecksLeft = 0;
        _fpReturnFromAway = NO;
        _fpReassertScheduled = NO;
        _fpAway = NO;
        _fpLastCompositor = 2;
        _fpkLastTitlebarTrace = nil;
        _fpkRevealSupported = NO;
        _fpkRevealRequested = NO;
        _fpkRevealVisible = NO;
        _fpkReleasing = NO;
        _fpkScreenReleased = NO;
        _fpkSessionReason = FullPanelFallbackReasonNone;
        _fpkReservationEntry = NO;
        _fpkEntryRejected = NO;
        _fpkLastReservationTrace = nil;
        _fpkForceWhileAway = NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(fpCheckSpaceReturn)
                                                   object:nil];
        CGFloat inset = window.screen.safeAreaInsets.top;
        if (_enabled) {
            // The reservation hook (installed once per process), only beside
            // a housing. Without it the entry is ordinary fullscreen; there is
            // no other whole-display mechanism to fall back to.
            NSString *why = nil;
            BOOL reservation = NO;
            if (inset > 0) {
                if (fpSimulateNoReservation()) {
                    why = @"simulated (FullPanelSimulateNoReservation)";
                } else {
                    reservation = FPKInstallMenuBarReservationHook(&why);
                }
            }
            FPKCapabilities capabilities = {
                .band = inset > 0,
                .geometry = reservation,
                .menuBarOverlay = FPKMenuBarOverlayAvailable(),
                .menuBarPinned = [[NSUserDefaults standardUserDefaults]
                                  boolForKey:@"AppleMenuBarVisibleInFullscreen"],
            };
            FullPanelFallbackReason reason = FPKFallbackForCapabilities(capabilities);
            if (reason == FullPanelFallbackReasonNone) {
                _fpArmed = YES;
                // Latched per entry. Off: the options stay forced while the
                // window is key and no reveal is possible.
                _fpkRevealSupported = FPKOption(@"FullPanelRevealIntegration", YES);
                FPKTrace(@"reveal-support", _fpkRevealSupported ? @"on" : @"off");
                _fpkReservationEntry = YES;
                _fpkForceWhileAway = FPKOption(@"FullPanelForceWhileAway", NO);
                FPKTrace(@"geometry", @"reservation");
            } else if (inset > 0 && reason == FullPanelFallbackReasonAppKitUnavailable) {
                _fpkSessionReason = reason;
                _fpError = FullPanelFallbackReasonDescription(reason);
                NSLog(@"FullPanelKit: using standard fullscreen: %@ (%@)", _fpError,
                      why ?: @"menu-bar reservation unavailable");
            } else if (inset > 0) {
                _fpkSessionReason = reason;
                _fpError = FullPanelFallbackReasonDescription(reason);
                NSLog(@"FullPanelKit: using standard fullscreen: %@", _fpError);
            } else {
                _fpkSessionReason = reason;
                FPKTrace(@"fallback", FullPanelFallbackReasonDescription(reason));
            }
        }
        FPKTrace(@"entry-prepared", [NSString stringWithFormat:@"by=%@ armed=%d enabled=%d inset=%.0f",
                 path, _fpArmed, _enabled, inset]);
    }
}

// ---- Menu-bar reservation ---------------------------------------------------------

- (BOOL)fpkClaimsMenuBarBand {
    NSWindow *window = _window;
    return _fpkReservationEntry && _enabled && _fpArmed && _fpEnteringOrInside && !_fpLost &&
           !_fpkScreenReleased && !_fpkEntryRejected && fpScreenHasHousing(window);
}

// P2. An entry whose willEnterFullScreen the engine did not receive
// (attached and enabled inside that notification: an observer added during a
// notification does not receive it) is prepared here. Allowed only when
// FullPanel was enabled while the window was windowed and no entry, exit or
// in-fullscreen enable happened since, so this request starts a new entry.
// Never for an existing fullscreen session. Measured on macOS 27.0.1
// (SpacesLab -attachAt willEnter): AppKit asks once before the style mask has
// FullScreen, which is not prepared and does not fix the layout, then again
// with it, before the window's fullscreen frame is final; and once during the
// exit, which the windowed style mask keeps from preparing anything.
- (BOOL)fpkAnswerReservationRequest {
    NSWindow *window = _window;
    _fpkReservationRequests++;
    BOOL inFullScreen = window && fpInFullScreen(window);
    BOOL prepared = NO;
    if (window && FPKReservationRequestPreparesEntry(_fpkUnpreparedEntryAllowed, _enabled,
                                                     _fpEnteringOrInside, inFullScreen)) {
        [self fpkPrepareForEntry:@"reservationRequest"];
        prepared = YES;
    }
    BOOL claims = [self fpkClaimsMenuBarBand];
    if (FPKTraceEnabled()) {
        NSString *line = [NSString stringWithFormat:
            @"win=%ld fs=%d entering=%d armed=%d unpreparedAllowed=%d rejected=%d answer=%@",
            (long)window.windowNumber, inFullScreen, _fpEnteringOrInside, _fpArmed,
            _fpkUnpreparedEntryAllowed, _fpkEntryRejected, claims ? @"NO (band claimed)" : @"AppKit's YES"];
        if (prepared || ![line isEqualToString:_fpkLastReservationTrace]) {
            _fpkLastReservationTrace = line;
            FPKTrace(@"reservation", prepared ? [line stringByAppendingString:@" prepared"] : line);
        }
    }
    return claims;
}

// P1. There is no frame answer that could accept the entry: it is accepted
// once the window is seen covering its display beside the
// housing. At didEnterFullScreen the verdict is final (`definitive`), also
// for an entry accepted earlier: fullscreen events during the entry animation
// accept it as soon as the window covers the display (measured: about 0.6 s
// before didEnterFullScreen), as the former frame answer did. A restored entry
// whose didEnterFullScreen was not delivered is accepted at its next
// fullscreen event, never rejected there.
- (void)fpkVerifyEntry:(NSString *)why definitive:(BOOL)definitive {
    if (!_fpkReservationEntry || _fpkEntryRejected) return;
    if (_fpAccepted && !definitive) return;
    NSWindow *window = _window;
    FPKEntryVerdict verdict = FPKVerifyReservationEntry(_fpArmed && _fpEnteringOrInside && !_fpLost,
                                                        window && fpInFullScreen(window),
                                                        fpCoversScreen(window), fpScreenHasHousing(window),
                                                        definitive);
    if (verdict == FPKEntryVerdictPending) return;
    if (verdict == FPKEntryVerdictAccepted && _fpAccepted) return;   // confirmed at didEnterFullScreen
    _fpAccepted = verdict == FPKEntryVerdictAccepted;
    _fpkEntryRejected = verdict == FPKEntryVerdictRejected;
    FPKTrace(@"entry-verified", [NSString stringWithFormat:@"%@ why=%@ frame=%@ screen=%@",
             verdict == FPKEntryVerdictAccepted ? @"accepted" : @"rejected", why,
             NSStringFromRect(window.frame), NSStringFromRect(window.screen.frame)]);
}

// ---- Engagement and reconciliation -------------------------------------------------
//
// One place applies FullPanel's system state: the menu-bar overlay for the
// window's fullscreen Space, the application presentation options and the
// titlebar window's mouse handling. Entry, returns, reveals, pointer moves and
// system changes only update facts and reconcile; release undoes everything.

// The overlay belongs to this window's own native fullscreen Space, and only
// while it is the active Space and the window covers a display with a band.
- (BOOL)fpkOverlayEligible {
    NSWindow *window = _window;
    return _fpArmed && _fpAccepted && _fpEnteringOrInside && !_fpLost && !_fpkScreenReleased &&
           fpInFullScreen(window) && window.isOnActiveSpace && fpCoversScreen(window) &&
           !fpScreenWithoutHousing(window);
}

// Submits the overlay for the window's current fullscreen Space (again, for a
// return: WindowServer may have reset it) and starts tracking. YES when
// submitted; a submission is not visual proof.
- (BOOL)fpkEngage:(NSString *)why {
    if (![self fpkOverlayEligible]) return NO;
    uint64_t space = FPKFullscreenSpaceOfWindow(_window);
    if (!space) {
        _fpError = @"No verified native fullscreen Space ID yet";
        _fpLastSkyLightStatus = -12;
        return NO;
    }
    if (_fpkOverlaySpace && _fpkOverlaySpace != space) {
        (void)FPKMenuBarOverlaySet(_fpkOverlaySpace, YES, NULL);   // that Space looks native again
    }
    _fpkOverlaySpace = space;
    [self fpkStartTracking];
    if (![self fpkApplyIntent:why submitOverlay:YES]) {
        _fpError = [NSString stringWithFormat:@"Could not submit SkyLight alpha override, Space=%llu",
                    (unsigned long long)space];
        NSLog(@"FullPanelKit: %@", _fpError);
        return NO;
    }
    _fpError = @"";
    return YES;
}

- (FPKFacts)fpkFacts {
    return (FPKFacts){
        .tracking = _fpkTracking && _fpkOverlaySpace != 0,
        .key = _window.isKeyWindow,
        .onActiveSpace = _window.isOnActiveSpace,
        .revealSupported = _fpkRevealSupported,
        .revealRequested = _fpkRevealRequested,
        .revealVisible = _fpkRevealVisible,
        .releasing = _fpkReleasing,
        .forcing = _fpkForcing,
    };
}

// Applies FPKIntentForFacts. The overlay is submitted when its value changes,
// or always with `submitOverlay`. NO only when a needed submission failed.
- (BOOL)fpkApplyIntent:(NSString *)why submitOverlay:(BOOL)submitOverlay {
    FPKFacts facts = [self fpkFacts];
    FPKIntent intent = FPKIntentForFacts(facts);
    // Diagnostic (FullPanelForceWhileAway): while the Space is away but the
    // window is still key (Mission Control opening), force instead of leaving
    // the options to the system's transition, as an earlier version did.
    if (_fpkForceWhileAway && facts.tracking && !facts.onActiveSpace && facts.key &&
        !facts.releasing && !(facts.revealSupported && (facts.revealRequested || facts.revealVisible))) {
        intent.presentation = FPKPresentationForce;
    }
    BOOL submitted = YES;
    if (facts.tracking && (submitOverlay || intent.backdropVisible != _fpkOverlayBackdropVisible)) {
        int32_t status = 0;
        submitted = FPKMenuBarOverlaySet(_fpkOverlaySpace, intent.backdropVisible, &status);
        _fpLastSkyLightStatus = status;   // raw, undocumented; may be nonzero
        if (submitted) _fpkOverlayBackdropVisible = intent.backdropVisible;
    }
    [self fpkApplyPresentation:intent.presentation why:why];
    _fpkTitlebar.passThrough = facts.tracking && intent.titlebarPassThrough;
    [self fpkTraceTitlebar:why];
    return submitted;
}

- (void)fpkReconcile:(NSString *)why {
    (void)[self fpkApplyIntent:why submitOverlay:NO];
}

static const NSApplicationPresentationOptions kFPKForcedPresentation =
    NSApplicationPresentationFullScreen | NSApplicationPresentationHideMenuBar |
    NSApplicationPresentationHideDock;

- (void)fpkApplyPresentation:(FPKPresentationIntent)intent why:(NSString *)why {
    if (intent == FPKPresentationForce) {
        if (!_fpkForcing && !_fpkPresentationBeforeForcingValid) {
            _fpkPresentationBeforeForcing = NSApp.presentationOptions;
            _fpkPresentationBeforeForcingValid = YES;
        }
        [self fpNoteNativePresentationBeforeForcing:kFPKForcedPresentation];
        _fpkForcing = YES;
        if (NSApp.presentationOptions != kFPKForcedPresentation) {
            FPKTrace(@"presentation", [NSString stringWithFormat:@"force 0x%lx why=%@",
                                       (unsigned long)kFPKForcedPresentation, why]);
            [NSApp setPresentationOptions:kFPKForcedPresentation];
        }
    } else if (intent == FPKPresentationRelax && _fpkForcing) {
        // Still in the session: AppKit's own fullscreen policy, so the menu bar
        // can be revealed. Not while another FullPanel window owns the options.
        _fpkForcing = NO;
        [fpForcingEngines() removeObject:self];
        for (FPKEngine *other in fpForcingEngines()) {
            if ([other fpForcesPresentationForKeyFullScreenWindow]) return;
        }
        NSApplicationPresentationOptions relaxed = _fpNativeFullScreenPresentationValid
            ? _fpNativeFullScreenPresentation
            : (NSApplicationPresentationOptions)FPKRelaxedPresentationOptions(_fpkPresentationBeforeForcing);
        if (NSApp.presentationOptions != relaxed) {
            FPKTrace(@"presentation", [NSString stringWithFormat:@"relax 0x%lx why=%@",
                                       (unsigned long)relaxed, why]);
            [NSApp setPresentationOptions:relaxed];
        }
    }
}

// ---- Mission Control / Space return -------------------------------------------------

// Mission Control's large thumbnail can restore the Space before the window's
// compositor bounds settle. Wait for the observed WindowServer bounds (at most
// ~2 s) rather than re-submitting SkyLight on arbitrary timeouts. This is not a
// geometry restore: if the strip was lost, only a fresh fullscreen entry can
// safely request it again.
- (void)fpCheckSpaceReturn {
    if (!_fpReturnPending) return;
    NSWindow *window = _window;
    if (!_fpArmed || !_fpEnteringOrInside || _fpLost || !fpInFullScreen(window)) {
        _fpReturnPending = NO;
        FPKTrace(@"return-check-abandoned", nil);
        return;
    }
    NSScreen *screen = window.screen;
    if (screen && !fpCoversScreen(window)) {
        FPKTrace(@"return-frame-differs", [NSString stringWithFormat:@"%@ vs %@",
                 NSStringFromRect(window.frame), NSStringFromRect(screen.frame)]);
        // Do not force a frame update (WindowServer can permanently remove the
        // strip from this fullscreen session).
    }
    int settled = FPKCompositorState(window);
    if (settled != _fpLastCompositor) {   // state changes only, not every poll
        _fpLastCompositor = settled;
        FPKTrace(@"compositor", [NSString stringWithFormat:
                 @"state=%d sinceCheckStartMs=%.1f key=%d onSpace=%d",
                 settled, FPKNowMs() - _fpReturnStartMs,
                 window.isKeyWindow, window.isOnActiveSpace]);
        [self fpkTraceTitlebar:@"compositor"];
    }
    if (FPKReturnIsReady(screen && fpCoversScreen(window), window.isOnActiveSpace,
                         window.isKeyWindow, settled, _fpReturnChecksLeft)) {
        BOOL committed = [self fpkEngage:@"return"];
        if (committed) _fpAway = NO;   // this return is complete
        FPKTrace(@"return-ready", [NSString stringWithFormat:
                 @"compositor=%d committed=%d space=%llu fromAway=%d sinceCheckStartMs=%.1f",
                 settled, committed, (unsigned long long)FPKFullscreenSpaceOfWindow(window),
                 _fpReturnFromAway, FPKNowMs() - _fpReturnStartMs]);
        if (committed && FPKReturnNeedsPresentationReassert(_fpReturnFromAway,
                _fpkTracking && _fpkRevealSupported, _fpkForcing, _fpkRevealVisible,
                _fpReassertScheduled)) {
            [self fpReassertPresentationAfterReturn];
        }
        _fpReturnFromAway = NO;
        _fpReturnPending = NO;
        return;
    }
    if (_fpReturnChecksLeft-- == 0) {
        FPKTrace(@"return-unresolved", [NSString stringWithFormat:
                 @"frame=%@ screen=%@ compositor=%d key=%d active=%d sinceCheckStartMs=%.1f; no frame forced",
                 NSStringFromRect(window.frame), NSStringFromRect(screen.frame), settled,
                 window.isKeyWindow, window.isOnActiveSpace, FPKNowMs() - _fpReturnStartMs]);
        _fpReturnPending = NO;
        return;
    }
    [self performSelector:@selector(fpCheckSpaceReturn) withObject:nil
               afterDelay:1.0/60.0 inModes:FPKReturnCheckModes()];
}

// Once per return, after the Space settled: release the forced presentation,
// re-force it on the next run-loop turn, then submit the overlay again on the
// turn after that, the order a top-edge reveal ends with. See
// FPKReturnNeedsPresentationReassert. Three main-queue turns; nothing repeats.
// The steps only change the `releasing` fact and reconcile.
- (void)fpReassertPresentationAfterReturn {
    _fpReassertScheduled = YES;
    _fpkReleasing = YES;
    [self fpkReconcile:@"reassert-release"];
    FPKTrace(@"reassert-release", [NSString stringWithFormat:@"app=0x%lx",
             (unsigned long)NSApp.presentationOptions]);
    __weak FPKEngine *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        FPKEngine *e = weakSelf;
        if (!e) return;
        e->_fpkReleasing = NO;
        if (!e->_fpReassertScheduled || !e->_fpkTracking || !e->_fpkOverlaySpace) {
            e->_fpReassertScheduled = NO;
            return;
        }
        [e fpkReconcile:@"reassert-force"];   // forced again unless a reveal is wanted
        FPKTrace(@"reassert-force", [NSString stringWithFormat:@"app=0x%lx",
                 (unsigned long)NSApp.presentationOptions]);
        dispatch_async(dispatch_get_main_queue(), ^{
            FPKEngine *e2 = weakSelf;
            if (!e2) return;
            BOOL live = e2->_fpReassertScheduled && e2->_fpkTracking && e2->_fpkOverlaySpace;
            e2->_fpReassertScheduled = NO;
            if (!live) return;
            (void)[e2 fpkApplyIntent:@"reassert-commit" submitOverlay:YES];
            FPKTrace(@"reassert-commit", nil);
        });
    });
}

- (void)fullPanelDidEnterFullScreen {
    [self fpkVerifyEntry:@"didEnterFullScreen" definitive:YES];
    if (!_fpArmed || !_fpAccepted || !fpCoversScreen(_window)) {
        if (_fpArmed) {
            _fpError = @"Window did not reach whole-screen frame";
            _fpkSessionReason = FullPanelFallbackReasonFrameNotAccepted;
        }
        FPKTrace(@"enter-not-covering", _fpError);
        return;
    }
    // Entering fullscreen is not a Mission Control return: submit once now.
    // The entry's own Space change marked the window away; that is not a
    // return either, so no presentation re-assert for it.
    _fpAway = NO;
    _fpReturnFromAway = NO;
    [self fpkEngage:@"didEnter"];
    [self fpDiagKick];
}

- (void)fullPanelReapplyMenuIfNeeded {
    NSWindow *window = _window;
    if (!_fpArmed || !_fpEnteringOrInside || _fpkScreenReleased || !fpInFullScreen(window)) return;
    if (!_fpAccepted) {
        [self fpkVerifyEntry:@"reapply" definitive:NO];
        if (_fpAccepted) [self fpkUpdateState];
    }
    // Sampled before early apply, which clears _fpAway.
    BOOL wasAway = _fpAway;
    // Coalesce notifications during Mission Control's animations. A later
    // didBecomeKey / appDidBecomeActive starts a fresh bounded check if the
    // earlier one expired before the user clicked a thumbnail.
    [self fpEarlyApplyIfEligible];
    if (_fpReturnPending) {
        // A check started while Mission Control was still open must not use
        // up the budget for the actual return: restart it once, here.
        if (FPKReturnCheckShouldRearm(true, wasAway, window.isKeyWindow, window.isOnActiveSpace,
                (window.occlusionState & NSWindowOcclusionStateVisible) != 0,
                _fpReturnRearmed)) {
            FPKTrace(@"return-check-rearm", [NSString stringWithFormat:
                     @"usedMs=%.1f checksLeft=%u", FPKNowMs() - _fpReturnStartMs,
                     _fpReturnChecksLeft]);
            _fpReturnRearmed = YES;
            _fpReturnFromAway = YES;
            _fpReturnChecksLeft = FPKReturnCheckBudget;
            _fpReturnStartMs = FPKNowMs();
            _fpLastCompositor = 2;
        }
        return;
    }
    _fpReturnPending = YES;
    _fpReturnRearmed = NO;
    _fpReturnFromAway = wasAway;
    _fpReturnChecksLeft = FPKReturnCheckBudget;
    _fpReturnStartMs = FPKNowMs();
    _fpLastCompositor = 2;
    FPKTrace(@"return-check-start", [NSString stringWithFormat:@"away=%d", _fpAway]);
    [self fpDiagKick];
    [self performSelector:@selector(fpCheckSpaceReturn)
               withObject:nil afterDelay:0.016 inModes:FPKReturnCheckModes()];
}

// Records a return-related signal: traces it and tracks whether the window has
// left its fullscreen Space/key state since the last menu-bar commit. Never
// changes frames or Spaces by itself.
- (void)fullPanelNoteEvent:(NSString *)event {
    NSWindow *window = _window;
    BOOL key = window.isKeyWindow;
    BOOL appActive = NSApp.isActive;
    BOOL onSpace = window.isOnActiveSpace;
    BOOL visible = (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    if (FPKTraceEnabled()) {
        FPKTrace(event, [NSString stringWithFormat:
                 @"key=%d appActive=%d onSpace=%d visible=%d fs=%d compositor=%d away=%d",
                 key, appActive, onSpace, visible, fpInFullScreen(window),
                 FPKCompositorState(window), _fpAway]);
        [self fpkTraceTitlebar:event];
        [self fpDiagKick];
    }
    if (_fpkTracking) {
        // Keyness, activation or visibility changed; AppKit may also have
        // recreated its titlebar window. When the window's visibility or Space
        // changes, the overlay is submitted again even if its value did not
        // change, also while the Space is shown inside Mission Control: a band
        // submitted only after the return stays black for longer than 0.4 s
        // (measured A/B, Tools/BehaviorProbes/mc-escape-check.sh).
        [_fpkTitlebar refresh];
        BOOL resubmit = [event isEqualToString:@"occlusionChanged"] ||
                        [event isEqualToString:@"activeSpaceChanged"];
        (void)[self fpkApplyIntent:event submitOverlay:resubmit];
    }
    if (!_fpArmed || !_fpAccepted || !_fpEnteringOrInside || _fpLost ||
        !fpInFullScreen(window) || !_fpkOverlaySpace) return;
    if (!_fpAway && (!key || !appActive || !onSpace || !visible)) {
        _fpAway = YES;
        _fpAwayAtMs = FPKNowMs();
        FPKTrace(@"away", event);
    }
}

// Submit the menu-bar alpha once per return transition, before WindowServer
// bounds settle (hardware-tested default; FullPanelEarlyApply=NO disables it).
// The compositor-verified commit in fpCheckSpaceReturn still runs afterwards
// and remains authoritative. Never changes frames or presentation options.
- (void)fpEarlyApplyIfEligible {
    if (!_fpAway || !FPKOption(@"FullPanelEarlyApply", YES)) return;
    NSWindow *window = _window;
    if (!_fpArmed || !_fpAccepted || !_fpEnteringOrInside || _fpLost ||
        !fpInFullScreen(window) || !fpCoversScreen(window) ||
        !(window.occlusionState & NSWindowOcclusionStateVisible) ||
        !window.isOnActiveSpace || !window.isKeyWindow || !_fpkOverlaySpace) return;
    uint64_t sid = FPKFullscreenSpaceOfWindow(window);
    if (sid != _fpkOverlaySpace) return;
    if (_fpkRevealVisible) return;   // revealed on purpose
    _fpAway = NO;   // coalesce: at most one early commit per return transition
    int32_t rc = 0;
    if (FPKMenuBarOverlaySet(sid, NO, &rc)) _fpkOverlayBackdropVisible = NO;
    _fpLastSkyLightStatus = rc;
    FPKTrace(@"early-commit", [NSString stringWithFormat:
             @"space=%llu sinceAwayMs=%.1f", (unsigned long long)sid,
             FPKNowMs() - _fpAwayAtMs]);
}

// ---- Reveal tracking ---------------------------------------------------------------
//
// While engaged: AppKit's titlebar window tells whether a reveal is on screen
// (FPKFullScreenTitlebar), a local monitor follows the pointer for the
// top-edge request, and changes to the system presentation options (KVO, as
// documented for currentSystemPresentationOptions) trigger a reconcile.

- (void)fpkStartTracking {
    NSWindow *window = _window;
    if (_fpkTracking || !window) return;
    _fpkTracking = YES;
    _fpkRevealRequested = NO;
    __weak FPKEngine *weakSelf = self;
    if (!_fpkTitlebar) {
        _fpkTitlebar = [[FPKFullScreenTitlebar alloc] initWithWindow:window onChange:^{
            [weakSelf fpkRevealVisibilityChanged];
        }];
    }
    _fpkTitlebar.hidesContentWhilePassingThrough = FPKOption(@"FullPanelHideTitlebarContent", NO);
    [_fpkTitlebar start];
    _fpkRevealVisible = _fpkRevealSupported && _fpkTitlebar.revealVisible;
    if (_fpkRevealSupported) {
        _fpkSavedAcceptsMouseMoved = window.acceptsMouseMovedEvents;
        window.acceptsMouseMovedEvents = YES;
        _fpkPointerMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
            (NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
             NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged)
            handler:^NSEvent *(NSEvent *event) {
                [weakSelf fpkPointerMoved];
                return event;
            }];
    }
    [NSApp addObserver:self forKeyPath:@"currentSystemPresentationOptions" options:0
               context:&kFPKSystemPresentationContext];
    _fpkObservingPresentation = YES;
    FPKTrace(@"tracking-start", [NSString stringWithFormat:@"space=%llu reveal=%d source=%@",
             (unsigned long long)_fpkOverlaySpace, _fpkRevealSupported, _fpkTitlebar.source]);
}

// Undoes fpkStartTracking, including the titlebar window's mouse handling.
- (void)fpkStopTracking {
    if (_fpkPointerMonitor) {
        [NSEvent removeMonitor:_fpkPointerMonitor];
        _fpkPointerMonitor = nil;
        _window.acceptsMouseMovedEvents = _fpkSavedAcceptsMouseMoved;
    }
    if (_fpkObservingPresentation) {
        @try {
            [NSApp removeObserver:self forKeyPath:@"currentSystemPresentationOptions"
                          context:&kFPKSystemPresentationContext];
        } @catch (NSException *exception) {
            (void)exception;
        }
        _fpkObservingPresentation = NO;
    }
    [_fpkTitlebar stop];
    if (_fpkTracking) FPKTrace(@"tracking-stop", nil);
    _fpkTracking = NO;
    _fpkRevealRequested = NO;
    _fpkRevealVisible = NO;
}

- (void)fpkPointerMoved {
    NSWindow *window = _window;
    NSScreen *screen = window.screen;
    if (!_fpkTracking || !window.isKeyWindow || !screen) return;
    FPKPointerZone zone = FPKPointerZoneAt([NSEvent mouseLocation].y, NSMaxY(screen.frame),
                                           screen.safeAreaInsets.top);
    BOOL requested = FPKRevealRequestAfterMove(_fpkRevealRequested, zone, _fpkRevealVisible);
    if (requested == _fpkRevealRequested) return;
    _fpkRevealRequested = requested;
    FPKTrace(@"reveal-request", requested ? @"top edge" : @"back in content");
    [self fpkReconcile:@"pointer"];
}

- (void)fpkRevealVisibilityChanged {
    BOOL visible = _fpkRevealSupported && _fpkTitlebar.revealVisible;
    if (visible == _fpkRevealVisible) return;
    _fpkRevealVisible = visible;
    NSScreen *screen = _window.screen;
    if (!visible && screen) {
        // The reveal has gone: the request stands only if the pointer has not
        // left the band.
        FPKPointerZone zone = FPKPointerZoneAt([NSEvent mouseLocation].y, NSMaxY(screen.frame),
                                               screen.safeAreaInsets.top);
        _fpkRevealRequested = FPKRevealRequestAfterMove(_fpkRevealRequested, zone, NO);
    }
    [self fpkReconcile:visible ? @"reveal-shown" : @"reveal-gone"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == &kFPKSystemPresentationContext) {
        if (FPKTraceEnabled()) {
            FPKTrace(@"systemPresentation", [NSString stringWithFormat:@"current=0x%lx app=0x%lx",
                     (unsigned long)NSApp.currentSystemPresentationOptions,
                     (unsigned long)NSApp.presentationOptions]);
            [self fpDiagKick];
        }
        // After the change has been delivered everywhere: reconcile once.
        __weak FPKEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf fpkReconcile:@"system-presentation"];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

// FullPanelTrace only: the titlebar companion's state when it changed.
- (void)fpkTraceTitlebar:(NSString *)why {
    if (!FPKTraceEnabled() || !_fpkTitlebar) return;
    NSString *line = [_fpkTitlebar traceDescription];
    if ([line isEqualToString:_fpkLastTitlebarTrace]) return;
    _fpkLastTitlebarTrace = line;
    FPKTrace(@"titlebar", [NSString stringWithFormat:@"why=%@ %@", why, line]);
}

// ---- Presentation baseline / restore ----------------------------------------------

// Called just before FullPanel forces its options. Records AppKit's fullscreen
// policy (FPKIsNativeFullScreenPresentation): the early force at the SkyLight
// commit still sees the windowed value and is skipped; at didEnterFullScreen
// AppKit has applied its own policy, which FullPanel then replaces.
- (void)fpNoteNativePresentationBeforeForcing:(NSApplicationPresentationOptions)forced {
    [fpForcingEngines() addObject:self];
    NSWindow *window = _window;
    NSApplicationPresentationOptions current = NSApp.presentationOptions;
    if (!FPKIsNativeFullScreenPresentation(window && fpInFullScreen(window), current, forced)) return;
    if (!_fpNativeFullScreenPresentationValid || _fpNativeFullScreenPresentation != current) {
        FPKTrace(@"presentation-native", [NSString stringWithFormat:@"0x%lx", (unsigned long)current]);
    }
    _fpNativeFullScreenPresentation = current;
    _fpNativeFullScreenPresentationValid = YES;
}

- (BOOL)fpForcesPresentationForKeyFullScreenWindow {
    NSWindow *window = _window;
    return _fpkForcing && window.isKeyWindow && fpInFullScreen(window);
}

// FullPanel stops forcing (reveal teardown, disable, detach, exit, close).
// See FPKPresentationRestoreTarget; the result is read back, since a request
// is not proof that AppKit applied it.
- (void)fpRestorePresentation:(NSApplicationPresentationOptions)windowed why:(NSString *)why {
    [fpForcingEngines() removeObject:self];
    NSWindow *window = _window;
    BOOL inFullScreen = window && fpInFullScreen(window);
    BOOL otherOwner = NO;
    for (FPKEngine *other in fpForcingEngines()) {
        if ([other fpForcesPresentationForKeyFullScreenWindow]) { otherOwner = YES; break; }
    }
    unsigned long target = 0;
    if (!FPKPresentationRestoreTarget(inFullScreen, _fpNativeFullScreenPresentationValid,
                                      _fpNativeFullScreenPresentation, windowed, otherOwner, &target)) {
        _fpLastPresentationRestore = [NSString stringWithFormat:@"%@ skipped: %@", why,
            otherOwner ? @"another FullPanel window owns the options"
                       : @"no native fullscreen policy recorded"];
        FPKTrace(@"presentation-restore", _fpLastPresentationRestore);
        return;
    }
    if (NSApp.presentationOptions != target) [NSApp setPresentationOptions:target];
    NSApplicationPresentationOptions result = NSApp.presentationOptions;
    _fpLastPresentationRestore = [NSString stringWithFormat:@"%@ requested=0x%lx result=0x%lx fullscreen=%d",
                                  why, target, (unsigned long)result, inFullScreen];
    FPKTrace(@"presentation-restore", _fpLastPresentationRestore);
    if (result == target) return;
    if (_fpkExitTransition) {
        // Expected: AppKit keeps its fullscreen options until the exit ends,
        // then applies the windowed ones itself (macOS 27: 0x40A read back
        // here on every exit; 0 after didExitFullScreen).
        FPKTrace(@"presentation-restore", @"deferred to AppKit's exit transition");
        return;
    }
    NSLog(@"FullPanelKit: presentation restore not applied: %@", _fpLastPresentationRestore);
}

// ---- Exit / restore --------------------------------------------------------------

- (void)fullPanelWillExitFullScreen {
    [self fpkReleaseSystemState:@"exit-reset" endingEntry:YES];
    _fpNativeFullScreenPresentationValid = NO;   // re-read at the next entry
    _fpEnteringOrInside = NO;
    _fpArmed = NO;
    _fpAccepted = NO;
    _fpLost = NO;
    _fpkScreenReleased = NO;
    _fpkReservationEntry = NO;
    _fpkEntryRejected = NO;
}

// Puts back what FullPanel changed outside the window: the menu-bar overlay,
// presentation options, the titlebar window's mouse handling, the pointer
// monitor and KVO; stops pending return work. `endingEntry` NO (screen
// release) keeps the entry armed and the reveal-support latch, so the next
// commit beside the housing starts tracking again.
- (void)fpkReleaseSystemState:(NSString *)why endingEntry:(BOOL)endingEntry {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(fpCheckSpaceReturn)
                                               object:nil];
    _fpReturnPending = NO;
    _fpReturnChecksLeft = 0;
    _fpReturnFromAway = NO;
    _fpReassertScheduled = NO;
    _fpAway = NO;
    _fpLastCompositor = 2;
    FPKTrace(why, nil);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fpDiagSample)
                                               object:nil];
    _fpDiagRunning = NO;
    _fpDiagLast = nil;
    _fpkReleasing = NO;
    [self fpkStopTracking];
    if (endingEntry) _fpkTitlebar = nil;
    _fpkLastTitlebarTrace = nil;
    if (_fpkOverlaySpace) {
        (void)FPKMenuBarOverlaySet(_fpkOverlaySpace, YES, NULL);
        FPKTrace(@"overlay-restored", [NSString stringWithFormat:@"space=%llu",
                 (unsigned long long)_fpkOverlaySpace]);
        _fpkOverlaySpace = 0;
    }
    _fpkOverlayBackdropVisible = YES;
    if (_fpkForcing) {
        _fpkForcing = NO;
        // Inside fullscreen the restore uses AppKit's recorded native policy;
        // outside it, the options read before FullPanel first forced its own.
        [self fpRestorePresentation:_fpkPresentationBeforeForcingValid
                                    ? _fpkPresentationBeforeForcing : NSApp.presentationOptions
                                why:why];
    }
    _fpkPresentationBeforeForcingValid = NO;
    [fpForcingEngines() removeObject:self];
}

// ---- Screen changes -----------------------------------------------------------------

// A fullscreen Space that moves to a display without a camera housing (Mission
// Control drag, display arrangement or removal) is ordinary fullscreen there:
// without this, the return check committed the menu-bar alpha and forced
// HideMenuBar | HideDock on that display (Dock unreachable in the Space; macOS
// 27, Sidecar). Back beside the housing, the entry is still armed; AppKit's
// layout under the reservation hook gives the window the whole display again
// (display-mode round trip, macOS 27.0.1), and the return check commits the
// menu bar again once the window is key on the active Space.
- (void)fpkScreenChanged {
    NSWindow *window = _window;
    BOOL inFullScreen = window && fpInFullScreen(window);
    if (FPKScreenReleasesSession(_fpArmed && _fpEnteringOrInside, inFullScreen,
                                 !fpScreenWithoutHousing(window), _fpkScreenReleased)) {
        _fpkScreenReleased = YES;
        [self fpkReleaseSystemState:@"screen-release" endingEntry:NO];
    } else if (FPKScreenResumesSession(_fpkScreenReleased, inFullScreen, fpScreenHasHousing(window))) {
        _fpkScreenReleased = NO;
        FPKTrace(@"screen-resume", [NSString stringWithFormat:@"frame=%@ screen=%@",
                 NSStringFromRect(window.frame), NSStringFromRect(window.screen.frame)]);
        [self fullPanelReapplyMenuIfNeeded];   // commits once key on the active Space
    }
    if (inFullScreen) [self fpkUpdateState];
}

// ---- Window-state trace -------------------------------------------------------------

- (void)fpkTraceWindowState:(NSString *)why {
    if (!FPKTraceEnabled()) return;
    NSWindow *window = _window;
    NSString *line;
    if (!window) {
        line = [NSString stringWithFormat:@"window=gone enabled=%d armed=%d submitted=%llu forcing=%d",
                _enabled, _fpArmed, (unsigned long long)_fpkOverlaySpace, _fpkForcing];
    } else {
        NSScreen *screen = window.screen;
        NSNumber *display = screen.deviceDescription[@"NSScreenNumber"];
        line = [NSString stringWithFormat:
            @"win=%ld screen=%@%@ frame=%@ fs=%d key=%d main=%d visible=%d occVisible=%d "
            @"onSpace=%d space=%llu cb=0x%lx appActive=%d pres=0x%lx enabled=%d armed=%d "
            @"accepted=%d screenReleased=%d submitted=%llu state=%ld",
            (long)window.windowNumber, display ?: @"-", screen.safeAreaInsets.top > 0 ? @"/housing" : @"",
            NSStringFromRect(window.frame), fpInFullScreen(window), window.isKeyWindow,
            window.isMainWindow, window.isVisible,
            (window.occlusionState & NSWindowOcclusionStateVisible) != 0, window.isOnActiveSpace,
            (unsigned long long)FPKSpaceOfWindow(window), (unsigned long)window.collectionBehavior,
            NSApp.isActive, (unsigned long)NSApp.presentationOptions, _enabled, _fpArmed,
            _fpAccepted, _fpkScreenReleased, (unsigned long long)_fpkOverlaySpace, (long)_fpkState];
    }
    if ([line isEqualToString:_fpkLastWindowStateTrace]) return;
    _fpkLastWindowStateTrace = line;
    FPKTrace(@"window-state", [NSString stringWithFormat:@"why=%@ %@", why, line]);
}

// ---- Trace-only state sampler ------------------------------------------------------

// FullPanelTrace + FullPanelTraceSampler only. After a traced event, samples window, compositor,
// presentation and WindowServer menu-bar layer state at 30 Hz for 4 s and logs
// a line only when it changes. Never changes any state.
- (void)fpDiagKick {
    if (!FPKTraceEnabled() || !FPKOption(@"FullPanelTraceSampler", NO) ||
        !_fpEnteringOrInside || !_window) return;
    _fpDiagUntilMs = FPKNowMs() + 4000.0;
    if (_fpDiagRunning) return;
    _fpDiagRunning = YES;
    [self fpDiagSample];
}

- (void)fpDiagSample {
    NSWindow *window = _window;
    if (!FPKTraceEnabled() || !_fpEnteringOrInside || !window || FPKNowMs() > _fpDiagUntilMs) {
        _fpDiagRunning = NO;
        return;
    }
    BOOL found = NO;
    NSRect ws = FPKWindowServerBounds(window, &found);
    NSString *line = [NSString stringWithFormat:
        @"key=%d appActive=%d onSpace=%d visible=%d fs=%d covers=%d compositor=%d ws=%@ "
        @"space=%llu submitted=%llu pending=%d checksLeft=%u rearmed=%d away=%d "
        @"pres=0x%lx sysPres=0x%lx revealVisible=%d revealRequested=%d layers:%@",
        window.isKeyWindow, NSApp.isActive, window.isOnActiveSpace,
        (window.occlusionState & NSWindowOcclusionStateVisible) != 0, fpInFullScreen(window),
        fpCoversScreen(window), FPKCompositorState(window),
        found ? NSStringFromRect(ws) : @"-", (unsigned long long)FPKFullscreenSpaceOfWindow(window),
        (unsigned long long)_fpkOverlaySpace, _fpReturnPending, _fpReturnChecksLeft,
        _fpReturnRearmed, _fpAway, (unsigned long)NSApp.presentationOptions,
        (unsigned long)NSApp.currentSystemPresentationOptions, _fpkRevealVisible,
        _fpkRevealRequested, FPKMenuBarLayerDescription()];
    if (![line isEqualToString:_fpDiagLast]) {
        _fpDiagLast = line;
        FPKTrace(@"sample", line);
    }
    [self performSelector:@selector(fpDiagSample) withObject:nil
               afterDelay:1.0/30.0 inModes:@[NSRunLoopCommonModes]];
}

// ---- Diagnostics -------------------------------------------------------------------

static NSDictionary *fpRectDict(NSRect r) {
    return @{@"x": @(r.origin.x), @"y": @(r.origin.y),
             @"width": @(r.size.width), @"height": @(r.size.height)};
}

- (NSDictionary<NSString *, id> *)diagnostics {
    NSWindow *window = _window;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSScreen *screen = window.screen;
    d[@"fullPanelEnabled"] = @(_enabled);
    d[@"state"] = @(_fpkState);
    d[@"fallbackReason"] = @(_fpkFallbackReason);
    d[@"fallbackDescription"] = FullPanelFallbackReasonDescription(_fpkFallbackReason);
    d[@"nativeFullscreenStyleMask"] = @(fpInFullScreen(window));
    d[@"isOnActiveSpace"] = @(window.isOnActiveSpace);
    d[@"skyLightReady"] = @(FPKMenuBarOverlayAvailable());
    d[@"armed"] = @(_fpArmed);
    d[@"frameAccepted"] = @(_fpAccepted);
    // Keys kept from earlier versions; values come from the reconciler.
    d[@"revealIntegration"] = @(_fpkRevealSupported);
    d[@"revealActive"] = @(_fpkTracking);
    d[@"revealAllowed"] = @(_fpkRevealRequested);
    d[@"menuBarRevealed"] = @(_fpkRevealVisible);
    d[@"toolbarRevealed"] = @(_fpkTitlebar.revealVisible);
    d[@"revealSource"] = _fpkTracking ? _fpkTitlebar.source : @"";
    d[@"titlebarPassThrough"] = @(_fpkTitlebar.passThrough);
    d[@"presentationForcing"] = @(_fpkForcing);
    d[@"menuBarOverrideSubmitted"] = @(_fpkOverlaySpace != 0);
    d[@"returnCheckPending"] = @(_fpReturnPending);
    d[@"returnFromAway"] = @(_fpReturnFromAway);
    d[@"presentationReassertScheduled"] = @(_fpReassertScheduled);
    d[@"menuBarTransparencyVisuallyVerified"] = @NO;
    d[@"fullscreenSpaceID"] = @(window ? FPKFullscreenSpaceOfWindow(window) : 0);
    d[@"skyLightCommitRawReturn"] = @(_fpLastSkyLightStatus);
    d[@"compositorState"] = @(window ? FPKCompositorState(window) : -1);
    d[@"windowServerBounds"] = fpRectDict(window ? FPKWindowServerBounds(window, NULL) : NSZeroRect);
    d[@"windowFrame"] = fpRectDict(window.frame);
    d[@"appPresentationOptionsRaw"] = @(NSApp.presentationOptions);
    d[@"nativeFullScreenPresentationRaw"] = _fpNativeFullScreenPresentationValid
        ? @(_fpNativeFullScreenPresentation) : @(-1);
    d[@"lastPresentationRestore"] = _fpLastPresentationRestore ?: @"";
    d[@"lastError"] = _fpError ?: @"";
    d[@"entryPreparedBy"] = _fpkEntryPreparedBy ?: @"";
    d[@"adoption"] = _fpkAdoption ?: @"";
    d[@"screenReleased"] = @(_fpkScreenReleased);
    d[@"lifecycleObservers"] = @(_fpkObservers.count);
    // Activation and Space navigation inputs (Dock click, Command-Tab).
    d[@"windowNumber"] = @(window.windowNumber);
    d[@"collectionBehaviorRaw"] = @(window.collectionBehavior);
    d[@"isKeyWindow"] = @(window.isKeyWindow);
    d[@"isMainWindow"] = @(window.isMainWindow);
    d[@"isVisible"] = @(window.isVisible);
    d[@"appActive"] = @(NSApp.isActive);
    d[@"spacesSwitchOnActivate"] = @(FPKSpacesSwitchOnActivate());
    d[@"options"] = @{
        @"FullPanelTrace": @(FPKTraceEnabled()),
        @"FullPanelEarlyApply": @(FPKOption(@"FullPanelEarlyApply", YES)),
        @"FullPanelRevealIntegration": @(FPKOption(@"FullPanelRevealIntegration", YES)),
        @"FullPanelLegacyModes": @(FPKOption(@"FullPanelLegacyModes", NO)),
        @"FullPanelSimulateNoReservation": @(fpSimulateNoReservation()),
        @"FullPanelForceWhileAway": @(FPKOption(@"FullPanelForceWhileAway", NO)),
        @"FullPanelHideTitlebarContent": @(FPKOption(@"FullPanelHideTitlebarContent", NO)),
    };
    BOOL reservationAvailable = FPKReservationGeometryAvailable();
    d[@"reservationAvailable"] = @(reservationAvailable);
    d[@"reservationHookInstalled"] = @(FPKMenuBarReservationHookInstalled());
    d[@"geometry"] = _fpkReservationEntry ? @"reservation" : @"none";
    d[@"geometryAvailable"] = reservationAvailable ? @"reservation" : @"none";
    d[@"entryRejected"] = @(_fpkEntryRejected);
    d[@"reservationRequests"] = @(_fpkReservationRequests);
    if (screen) {
        d[@"screenName"] = screen.localizedName ?: @"";
        d[@"screenDisplayID"] = screen.deviceDescription[@"NSScreenNumber"] ?: @0;
        d[@"screenHasCameraHousing"] = @(screen.safeAreaInsets.top > 0);
        d[@"screenFrame"] = fpRectDict(screen.frame);
        d[@"screenSafeAreaTop"] = @(screen.safeAreaInsets.top);
        d[@"screenBackingScaleFactor"] = @(screen.backingScaleFactor);
        d[@"appKitFrameCoversDisplay"] = @(fpCoversScreen(window));
    }
    return d;
}

- (void)dealloc {
    // Hosts call -teardown; this only guarantees the NSApp KVO observation
    // and monitors never outlive the engine.
    [self teardown];
}

@end
