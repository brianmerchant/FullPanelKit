// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Provenance: replaces the SkyLight portion of FPKSupport.m that earlier,
// unpublished versions adapted from UTM (Apache-2.0; see docs/PROVENANCE.md).
// Written from SkyLight's platform facts by an author who had read the
// adapted code. What it shares with that code is dictated by SkyLight: the
// symbol names, their signatures, the constants and the create/set/commit
// order.
//
// The fullscreen menu bar has an opaque backdrop over the camera-housing band.
// SkyLight can override that backdrop's alpha for one Space, in a
// transaction. Nothing else in FullPanelKit talks to SkyLight.

#if !__has_feature(objc_arc)
#error FullPanelKitCore must be compiled with ARC (-fobjc-arc).
#endif

#import "FPKMenuBarOverlay.h"
#import "FPKSupport.h"
#import <dlfcn.h>
#import <stddef.h>

// Values from public reverse-engineered headers (CGSInternal; yabai, MIT):
// the mask that includes every kind of Space a window can be on, and the
// type SkyLight reports for a native fullscreen Space.
static const int32_t kSpacesOfAnyKind = 0x7;
static const int32_t kFullscreenSpaceType = 4;
// Commit mode passed to SLSTransactionCommit: apply now, not batched with the
// next window-server update (as tested on hardware).
static const int32_t kCommitNow = 1;

typedef struct {
    int32_t (*connection)(void);
    CFArrayRef (*copySpacesForWindows)(int32_t, int32_t, CFArrayRef);
    int32_t (*spaceType)(int32_t, uint64_t);
    CFTypeRef (*transactionCreate)(int32_t);
    void (*transactionSetMenuBarAlpha)(CFTypeRef, uint64_t, float);
    int32_t (*transactionCommit)(CFTypeRef, int32_t);
} FPKSkyLight;

static FPKSkyLight sky;

// One table, filled all-or-nothing: a partial SkyLight is no SkyLight.
static const struct { const char *symbol; size_t offset; } kSkyLightSymbols[] = {
    { "SLSMainConnectionID", offsetof(FPKSkyLight, connection) },
    { "SLSCopySpacesForWindows", offsetof(FPKSkyLight, copySpacesForWindows) },
    { "SLSSpaceGetType", offsetof(FPKSkyLight, spaceType) },
    { "SLSTransactionCreate", offsetof(FPKSkyLight, transactionCreate) },
    { "SLSTransactionSetMenuBarSystemOverrideAlpha", offsetof(FPKSkyLight, transactionSetMenuBarAlpha) },
    { "SLSTransactionCommit", offsetof(FPKSkyLight, transactionCommit) },
};

BOOL FPKMenuBarOverlayAvailable(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                             RTLD_LAZY | RTLD_LOCAL);
        if (!image) return;
        FPKSkyLight resolved = {0};
        size_t count = sizeof(kSkyLightSymbols) / sizeof(kSkyLightSymbols[0]);
        for (size_t i = 0; i < count; i++) {
            void *address = dlsym(image, kSkyLightSymbols[i].symbol);
            if (!address) {
                NSLog(@"FullPanelKit: SkyLight symbol unavailable: %s", kSkyLightSymbols[i].symbol);
                return;
            }
            memcpy((char *)&resolved + kSkyLightSymbols[i].offset, &address, sizeof(address));
        }
        sky = resolved;
        available = YES;
    });
    return available;
}

uint64_t FPKSpaceOfWindow(NSWindow *window) {
    NSInteger number = window.windowNumber;
    if (number <= 0 || !FPKMenuBarOverlayAvailable()) return 0;
    CFArrayRef spaces = sky.copySpacesForWindows(sky.connection(), kSpacesOfAnyKind,
                                                 (__bridge CFArrayRef)@[@(number)]);
    if (!spaces) return 0;
    NSArray *list = CFBridgingRelease(spaces);
    // A window on several Spaces (all-Spaces windows) has no single Space to
    // override; neither has one on none.
    if (list.count != 1 || ![list.firstObject isKindOfClass:[NSNumber class]]) return 0;
    return [list.firstObject unsignedLongLongValue];
}

BOOL FPKSpaceIsFullscreen(uint64_t space) {
    return space && FPKMenuBarOverlayAvailable() &&
           sky.spaceType(sky.connection(), space) == kFullscreenSpaceType;
}

uint64_t FPKFullscreenSpaceOfWindow(NSWindow *window) {
    uint64_t space = FPKSpaceOfWindow(window);
    return FPKSpaceIsFullscreen(space) ? space : 0;
}

BOOL FPKMenuBarOverlaySet(uint64_t space, BOOL backdropVisible, int32_t *status) {
    if (!space || !FPKMenuBarOverlayAvailable()) {
        if (status) *status = -10;
        return NO;
    }
    CFTypeRef transaction = sky.transactionCreate(sky.connection());
    if (!transaction) {
        if (status) *status = -11;
        return NO;
    }
    sky.transactionSetMenuBarAlpha(transaction, space, backdropVisible ? 1.0f : 0.0f);
    int32_t result = sky.transactionCommit(transaction, kCommitNow);
    CFRelease(transaction);
    if (status) *status = result;
    // The result is undocumented; nonzero values are recorded, not treated
    // as failure.
    FPKTrace(@"overlay", [NSString stringWithFormat:@"space=%llu backdrop=%@ result=%d",
                          (unsigned long long)space, backdropVisible ? @"opaque" : @"clear", result]);
    return YES;
}
