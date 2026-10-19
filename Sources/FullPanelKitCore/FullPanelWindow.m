// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// History: earlier, unpublished versions of this file contained
// -toggleFullScreen: and -setFrame:display: overrides adapted from UTM's
// Platform/macOS/Display/VMDisplayWindow.swift (Copyright © 2026 Turing
// Software, LLC, Apache-2.0). The redesign removed the -toggleFullScreen:
// override (entries are prepared at willEnterFullScreen) and turned
// -setFrame:display: into one of five frame guards; the guards, the
// fullscreen-frame override and the forwarding delegate were later removed:
// AppKit's own layout holds the display (FPKAppKitHooks.m).
// See docs/PROVENANCE.md.
//
// FullPanelWindow: an NSWindow subclass hosting the FullPanel engine
// (FPKEngine.m). It overrides no NSWindow method other than its initializers
// and -dealloc, and keeps the application's delegate as is.
//
// Fullscreen is always AppKit's own: -toggleFullScreen: creates the Space.

#if !__has_feature(objc_arc)
#error FullPanelKitCore must be compiled with ARC (-fobjc-arc).
#endif

#import "FullPanelWindow+Engine.h"
#import "FPKMenuBarOverlay.h"

NSNotificationName const FullPanelWindowStateDidChangeNotification =
    @"FullPanelWindowStateDidChangeNotification";

NSString *FullPanelFallbackReasonDescription(FullPanelFallbackReason reason) {
    switch (reason) {
        case FullPanelFallbackReasonNone: return @"None";
        case FullPanelFallbackReasonNoCameraHousing:
            return @"This display has no camera housing; using standard fullscreen.";
        case FullPanelFallbackReasonAppKitUnavailable:
            return @"Private AppKit fullscreen layout API unavailable on this macOS version.";
        case FullPanelFallbackReasonSkyLightUnavailable:
            return @"Private SkyLight menu-bar API unavailable on this macOS version.";
        case FullPanelFallbackReasonMenuBarAlwaysShown:
            return @"\"Always show menu bar in full screen\" is on; FullPanel is disabled.";
        case FullPanelFallbackReasonFrameNotAccepted:
            return @"AppKit did not give the window the whole display (e.g. Split View).";
    }
    return @"Unknown";
}

@implementation FullPanelWindow {
    BOOL _fpkInitialized;
}

// ---- Initialization ------------------------------------------------------------

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing defer:(BOOL)flag {
    self = [super initWithContentRect:contentRect styleMask:style backing:backing defer:flag];
    if (self) [self fpkCommonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self fpkCommonInit];
    return self;
}

- (void)fpkCommonInit {
    if (_fpkInitialized) return;
    _fpkInitialized = YES;
    _fpkEngine = [[FPKEngine alloc] initWithWindow:self host:self];
    [_fpkEngine installLifecycleObservers];
}

// ---- Public API ------------------------------------------------------------------

+ (BOOL)fullPanelSystemSupportAvailable {
    return FPKReservationGeometryAvailable() && FPKMenuBarOverlayAvailable();
}

- (BOOL)fullPanelEnabled { return _fpkEngine.enabled; }

- (void)setFullPanelEnabled:(BOOL)enabled { _fpkEngine.enabled = enabled; }

- (FullPanelState)fullPanelState { return _fpkEngine.state; }
- (FullPanelFallbackReason)fullPanelFallbackReason { return _fpkEngine.fallbackReason; }
- (BOOL)isFullPanelActive { return _fpkEngine.state == FullPanelStateActive; }

+ (NSSet<NSString *> *)keyPathsForValuesAffectingFullPanelActive {
    return [NSSet setWithObject:@"fullPanelState"];
}

- (nullable FullPanelDisplayGeometry *)fullPanelGeometry {
    NSScreen *screen = self.screen;
    return screen ? [[FullPanelDisplayGeometry alloc] initWithScreen:screen] : nil;
}

- (NSRect)fullPanelConvertScreenRect:(NSRect)screenRect toView:(NSView *)view {
    return [view convertRect:[self convertRectFromScreen:screenRect] fromView:nil];
}

- (void)fullPanelRestoreSystemState {
    [_fpkEngine fullPanelWillExitFullScreen];
    [_fpkEngine fpkUpdateState];
}

- (NSDictionary<NSString *, id> *)fullPanelDiagnostics {
    return [_fpkEngine diagnostics];
}

// ---- Engine host --------------------------------------------------------------------

- (void)fpkEngineStateWillChange:(BOOL)stateChanged reason:(BOOL)reasonChanged {
    if (stateChanged) [self willChangeValueForKey:@"fullPanelState"];
    if (reasonChanged) [self willChangeValueForKey:@"fullPanelFallbackReason"];
}

- (void)fpkEngineStateDidChange:(BOOL)stateChanged reason:(BOOL)reasonChanged {
    if (reasonChanged) [self didChangeValueForKey:@"fullPanelFallbackReason"];
    if (stateChanged) [self didChangeValueForKey:@"fullPanelState"];
}

- (void)fpkEnginePostStateChange {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:FullPanelWindowStateDidChangeNotification object:self];
}

- (void)dealloc {
    [_fpkEngine teardown];
}

@end
