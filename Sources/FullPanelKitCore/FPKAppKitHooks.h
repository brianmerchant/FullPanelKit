// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
// Internal: the private AppKit hook. Not public API.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when AppKit's fullscreen content controller implements
/// `-reservesSpaceForMenuBarInFullScreen` itself and has `-window`, both with
/// the expected encodings, and no other code has replaced the method (before
/// installation: its implementation lies outside AppKit's image; after: it is
/// no longer FullPanelKit's). Does not install anything (capability check, P3).
BOOL FPKMenuBarReservationAvailable(void);
/// Replaces AppKit's answer to "does this fullscreen window leave the menu-bar
/// band free?" for windows whose engine claims the band
/// (-fpkAnswerReservationRequest); every other window, and every call off the
/// main thread, keeps AppKit's answer. The method belongs to an AppKit class,
/// so the replacement is process-wide and permanent once installed; it is
/// never restored. No window class is changed. Thread-safe and idempotent:
/// the installation runs once per process. NO, with a reason, when the methods
/// differ from macOS 27's, or when other code replaced the method before or
/// after the installation (FPKAppKitHooks.m explains both).
BOOL FPKInstallMenuBarReservationHook(NSString *_Nullable *_Nullable reason);
/// YES while FullPanelKit's replacement is installed and still in place.
BOOL FPKMenuBarReservationHookInstalled(void);

NS_ASSUME_NONNULL_END
