// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
// Internal: the fullscreen menu-bar backdrop override (private SkyLight). Not public API.

#import <AppKit/AppKit.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when every SkyLight function the override needs was found. Resolves
/// them on first use; never changes anything.
BOOL FPKMenuBarOverlayAvailable(void);

/// The one Space that holds `window`, or 0 (window not on screen, on no Space
/// or on several, or SkyLight unavailable).
uint64_t FPKSpaceOfWindow(NSWindow *window);

/// YES when `space` is a native fullscreen Space.
BOOL FPKSpaceIsFullscreen(uint64_t space);

/// The window's Space if it is a native fullscreen Space, otherwise 0.
uint64_t FPKFullscreenSpaceOfWindow(NSWindow *window);

/// Makes the menu-bar backdrop of fullscreen Space `space` opaque (YES, the
/// system's own look) or transparent (NO). YES means the request was
/// submitted, not that the change is visible. `status` receives SkyLight's raw
/// result, or -10 (no Space / SkyLight unavailable) or -11 (no transaction).
BOOL FPKMenuBarOverlaySet(uint64_t space, BOOL backdropVisible, int32_t *_Nullable status);

NS_ASSUME_NONNULL_END
