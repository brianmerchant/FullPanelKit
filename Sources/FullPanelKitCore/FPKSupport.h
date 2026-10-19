// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
// Internal: options, diagnostics and read-only WindowServer queries.
// Nothing in this header is public API.

#import <AppKit/AppKit.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// ---- Options -------------------------------------------------------------
// The hardware-tested configuration is the default. These user-defaults keys
// (in the host application's defaults domain) exist only for on-hardware A/B
// diagnosis and are read live, exactly like the probe:
//   FullPanelTrace              default NO   timestamped diagnostics via NSLog
//   FullPanelEarlyApply         default YES  one early SkyLight commit per return
//   FullPanelRevealIntegration  default YES  AppKit menu-bar reveal integration
//   FullPanelLegacyModes        default NO   return checks in default run-loop
//                                            mode only
BOOL FPKOption(NSString *key, BOOL defaultValue);
BOOL FPKTraceEnabled(void);
void FPKTrace(NSString *event, NSString *_Nullable detail);
double FPKNowMs(void);
NSArray<NSRunLoopMode> *FPKReturnCheckModes(void);
/// Desktop & Dock > "When switching to an application, switch to a Space with
/// open windows for the application" (AppleSpacesSwitchOnActivate), as AppKit
/// reads it in this process. Diagnostics only: FullPanel never changes it.
BOOL FPKSpacesSwitchOnActivate(void);

// The private SkyLight menu-bar override lives in FPKMenuBarOverlay.h.

// ---- WindowServer (public CoreGraphics) -----------------------------------
NSRect FPKWindowServerBounds(NSWindow *window, BOOL *_Nullable found);
/// 1: WindowServer bounds match the AppKit frame; 0: still being animated by
/// Mission Control; -1: unknown.
int FPKCompositorState(NSWindow *window);

/// Diagnostics only (FullPanelTrace): WindowServer's own menu-bar layer
/// windows (layer 24) and safe-area shield windows as CGWindowList reports
/// them: on-screen flag, alpha and bounds. Read-only.
NSString *FPKMenuBarLayerDescription(void);

NS_ASSUME_NONNULL_END
