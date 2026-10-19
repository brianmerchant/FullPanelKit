// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// History: earlier, unpublished versions of this file contained portions
// adapted from UTM's Platform/macOS/Display/VMDisplayWindow.swift (Copyright
// © 2026 Turing Software, LLC, Apache-2.0): the SkyLight layer and the
// fullscreen titlebar-window class test. The redesign removed both: the
// SkyLight override is FPKMenuBarOverlay.m, and the titlebar window is found
// through its parent window (FPKFullScreenTitlebar.m). See docs/PROVENANCE.md.
//
// Options, tracing and read-only WindowServer queries. Extracted from
// FullPanel Notch Probe v0.4 (4660e21), FPWindow.m.

#if !__has_feature(objc_arc)
#error FullPanelKitCore must be compiled with ARC (-fobjc-arc).
#endif

#import "FPKSupport.h"
#import "FPKDecisions.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach_time.h>

BOOL FPKOption(NSString *key, BOOL defaultValue) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return value ? [[NSUserDefaults standardUserDefaults] boolForKey:key] : defaultValue;
}

BOOL FPKTraceEnabled(void) { return FPKOption(@"FullPanelTrace", NO); }

double FPKNowMs(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

void FPKTrace(NSString *event, NSString *_Nullable detail) {
    if (!FPKTraceEnabled()) return;
    NSLog(@"FULLPANEL TRACE t=%.3f ev=%@ %@", FPKNowMs(), event, detail ?: @"");
}

// Off, a Dock click or Command-Tab activates the application (its menu bar)
// without leaving the current Space, for any fullscreen window: Preview, a
// plain AppKit window and FullPanel windows alike (macOS 27). The system
// default is on.
BOOL FPKSpacesSwitchOnActivate(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleSpacesSwitchOnActivate"];
    return value ? [value boolValue] : YES;
}

// Common modes let return checks run while AppKit is in a tracking or other
// non-default run-loop mode during the transition.
NSArray<NSRunLoopMode> *FPKReturnCheckModes(void) {
    return FPKOption(@"FullPanelLegacyModes", NO) ? @[NSDefaultRunLoopMode]
                                                  : @[NSRunLoopCommonModes];
}

// ---- SkyLight ------------------------------------------------------------

// The SkyLight menu-bar override moved to FPKMenuBarOverlay.m.

// ---- WindowServer --------------------------------------------------------

// Read WindowServer's actual window bounds. Mission Control may animate its
// presentation without changing NSWindow.frame. Nothing is changed.
NSRect FPKWindowServerBounds(NSWindow *w, BOOL *found) {
    if (found) *found = NO;
    if (!w || w.windowNumber <= 0) return NSZeroRect;
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
                                                  (CGWindowID)w.windowNumber);
    if (!info) return NSZeroRect;
    NSRect result = NSZeroRect;
    for (NSDictionary *entry in (__bridge NSArray *)info) {
        NSNumber *number = entry[(__bridge NSString *)kCGWindowNumber];
        if (number.integerValue != w.windowNumber) continue;
        NSDictionary *rect = entry[(__bridge NSString *)kCGWindowBounds];
        CGRect bounds;
        if (rect && CGRectMakeWithDictionaryRepresentation(
                         (__bridge CFDictionaryRef)rect, &bounds)) {
            result = NSRectFromCGRect(bounds);
            if (found) *found = YES;
        }
        break;
    }
    CFRelease(info);
    return result;
}

int FPKCompositorState(NSWindow *w) {
    NSScreen *primary = [NSScreen screens].firstObject;
    if (!primary || !w || !w.screen) return -1;
    BOOL found = NO;
    NSRect actual = FPKWindowServerBounds(w, &found);
    if (!found) return -1;
    return FPKCompositorMatchesFrame(NSRectToCGRect(actual), NSRectToCGRect(w.frame),
                                     NSMaxY(primary.frame)) ? 1 : 0;
}

NSString *FPKMenuBarLayerDescription(void) {
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!info) return @"none";
    NSMutableString *out = [NSMutableString string];
    for (NSDictionary *entry in (__bridge NSArray *)info) {
        NSString *owner = entry[(__bridge NSString *)kCGWindowOwnerName];
        NSString *name = entry[(__bridge NSString *)kCGWindowName] ?: @"";
        NSInteger layer = [entry[(__bridge NSString *)kCGWindowLayer] integerValue];
        BOOL menubar = layer == kCGMainMenuWindowLevel && [owner isEqualToString:@"Window Server"];
        BOOL shield = [name hasPrefix:@"Display Safe Area"];
        if (!menubar && !shield) continue;
        CGRect b = CGRectZero;
        NSDictionary *rect = entry[(__bridge NSString *)kCGWindowBounds];
        if (rect) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)rect, &b);
        [out appendFormat:@" [%@ a=%.2f %.0f,%.0f %.0fx%.0f]", shield ? @"shield" : @"menubar",
            [entry[(__bridge NSString *)kCGWindowAlpha] doubleValue],
            b.origin.x, b.origin.y, b.size.width, b.size.height];
    }
    CFRelease(info);
    return out.length ? out : @" none";
}
