// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// FullPanelKit for Tauri: a C-ABI bridge from a Tauri window's NSWindow pointer
// (WebviewWindow::ns_window()) to FullPanelSession. The FullPanelKit engine is
// compiled unchanged from Sources/FullPanelKitCore; this file only resolves
// windows and forwards to the public FullPanelSession API.
//
// Every function returns a malloc'd UTF-8 JSON object, released with
// fpt_free(): {"ok": true, ...} or {"ok": false, "code": ..., "message": ...}.
//
// Safety rules kept here: main thread only; the pointer is never messaged until
// it has been found among NSApp.windows; no NSWindow-wide hooks (attachment is
// FullPanelSession's own per-class mechanism); the window's class, delegate and
// content view are never replaced.

#if !__has_feature(objc_arc)
#error fullpanel_tauri must be compiled with ARC (-fobjc-arc).
#endif

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <pthread.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#import "FullPanelKitCore.h"

// A comparison is an int in C, and @(int) serializes as 0/1; JSON needs a
// boolean NSNumber.
#define FPTBool(expr) ((expr) ? @YES : @NO)

// ---- Session bookkeeping ----------------------------------------------------------
//
// Sessions are owned by their windows (FullPanelSession's design). The bridge
// keeps weak references, for fpt_info(), and one NSWindowWillClose observer per
// attached window that detaches the session: Tauri never reopens a closed window.

@interface FPTAttachRecord : NSObject {
@public
    __weak NSWindow *_window;
    __weak FullPanelSession *_session;
    uintptr_t _windowAddress;
    NSString *_windowClass;
    id _closeObserver;
    BOOL _closedByWindow;
}
@end

@implementation FPTAttachRecord
@end

static NSMutableArray<FPTAttachRecord *> *gRecords;

static NSString *FPTHex(uintptr_t value) {
    return [NSString stringWithFormat:@"0x%lx", (unsigned long)value];
}

static uintptr_t FPTAddress(id object) {
    return (uintptr_t)(__bridge void *)object;
}

static NSDictionary *FPTRect(NSRect rect) {
    return @{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
             @"width": @(rect.size.width), @"height": @(rect.size.height)};
}

static BOOL FPTRectsNearlyEqual(NSRect a, NSRect b) {
    return fabs(a.origin.x - b.origin.x) <= 0.5 && fabs(a.origin.y - b.origin.y) <= 0.5 &&
           fabs(a.size.width - b.size.width) <= 0.5 && fabs(a.size.height - b.size.height) <= 0.5;
}

static FPTAttachRecord *FPTLiveRecordForWindow(NSWindow *window) {
    for (FPTAttachRecord *record in gRecords) {
        NSWindow *recorded = record->_window;
        if (recorded == window && record->_closeObserver) return record;
    }
    return nil;
}

static void FPTRemoveObserver(FPTAttachRecord *record) {
    if (record->_closeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:record->_closeObserver];
    }
    record->_closeObserver = nil;
}

static void FPTTrackAttachment(NSWindow *window, FullPanelSession *session) {
    if (!gRecords) gRecords = [NSMutableArray array];
    FPTAttachRecord *record = FPTLiveRecordForWindow(window);
    if (record) {
        record->_session = session;
        return;
    }
    record = [[FPTAttachRecord alloc] init];
    record->_window = window;
    record->_session = session;
    record->_windowAddress = FPTAddress(window);
    record->_windowClass = NSStringFromClass([window class]);
    __weak FPTAttachRecord *weakRecord = record;
    __weak NSWindow *weakWindow = window;
    record->_closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:window
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    NSWindow *strongWindow = weakWindow;
                    FPTAttachRecord *strongRecord = weakRecord;
                    if (strongWindow) [[FullPanelSession sessionForWindow:strongWindow] detach];
                    if (strongRecord) {
                        strongRecord->_closedByWindow = YES;
                        FPTRemoveObserver(strongRecord);
                    }
                }];
    [gRecords addObject:record];
}

// ---- JSON results ------------------------------------------------------------------

// NSJSONSerialization accepts only strings, finite numbers, NSNull, arrays and
// dictionaries with string keys; diagnostics may hold other values.
static id FPTJSONSafe(id value) {
    if (!value || value == [NSNull null]) return [NSNull null];
    if ([value isKindOfClass:[NSNumber class]]) {
        double d = [value doubleValue];
        return (isfinite(d)) ? value : [NSNull null];
    }
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *)value) out[[key description]] = FPTJSONSafe(value[key]);
        return out;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSArray *)value) [out addObject:FPTJSONSafe(item)];
        return out;
    }
    if ([value isKindOfClass:[NSValue class]] && strcmp([value objCType], @encode(NSRect)) == 0) {
        return FPTRect([value rectValue]);
    }
    return [value description];
}

static char *FPTJSON(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:FPTJSONSafe(object)
                                                   options:NSJSONWritingSortedKeys
                                                     error:NULL];
    if (!data) data = [@"{\"ok\":false,\"code\":\"ERR_FULLPANEL_JSON\",\"message\":\"serialization failed\"}"
                       dataUsingEncoding:NSUTF8StringEncoding];
    char *out = malloc(data.length + 1);
    if (!out) return NULL;
    memcpy(out, data.bytes, data.length);
    out[data.length] = '\0';
    return out;
}

static char *FPTOk(NSDictionary *fields) {
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    result[@"ok"] = @YES;
    return FPTJSON(result);
}

static char *FPTFail(NSString *code, NSString *message) {
    return FPTJSON(@{@"ok": @NO, @"code": code, @"message": message});
}

// ---- Window resolution -------------------------------------------------------------

static BOOL FPTOnMainThread(void) {
    return pthread_main_np() && [NSThread isMainThread];
}

// The pointer from WebviewWindow::ns_window() is compared with the live windows
// by address before it is used, so a stale or foreign pointer is reported
// instead of being messaged.
static NSWindow *FPTResolveWindow(const void *pointer, char **failure) {
    if (!FPTOnMainThread()) {
        *failure = FPTFail(@"ERR_FULLPANEL_THREAD", @"must be called on the macOS main thread");
        return nil;
    }
    if (!pointer) {
        *failure = FPTFail(@"ERR_FULLPANEL_HANDLE", @"NSWindow pointer is null");
        return nil;
    }
    for (NSWindow *window in NSApp.windows) {
        if ((const void *)(__bridge void *)window == pointer) return window;
    }
    *failure = FPTFail(@"ERR_FULLPANEL_NO_WINDOW",
                       [NSString stringWithFormat:@"no live NSWindow at %@ (window closed?)",
                        FPTHex((uintptr_t)pointer)]);
    return nil;
}

// ---- Window facts --------------------------------------------------------------------

static NSString *FPTImageName(Class cls) {
    const char *image = cls ? class_getImageName(cls) : NULL;
    return image ? @(image) : @"";
}

static NSDictionary *FPTClassFacts(NSWindow *window) {
    Class cls = [window class];
    NSMutableArray *chain = [NSMutableArray array];
    for (Class c = cls; c; c = class_getSuperclass(c)) [chain addObject:NSStringFromClass(c)];
    NSString *image = FPTImageName(cls);
    // The same rules FullPanelSession applies in +attachToWindow:error:.
    NSString *reason = @"";
    if ([window isKindOfClass:[FullPanelWindow class]]) {
        reason = @"FullPanelWindow (use fullPanelEnabled)";
    } else if ([image containsString:@"/AppKit.framework/"]) {
        reason = @"AppKit-owned class; FullPanelSession does not support AppKit's own window classes";
    }
    return @{
        @"windowClass": NSStringFromClass(cls),
        @"windowRuntimeClass": NSStringFromClass(object_getClass(window)),
        // Empty for a class registered at run time (objc_allocateClassPair),
        // which is how Tao creates TaoWindow.
        @"windowClassImage": image,
        @"windowClassRegisteredAtRuntime": FPTBool(image.length == 0),
        @"superclassChain": chain,
        @"isTaoWindow": FPTBool(strcmp(class_getName(cls), "TaoWindow") == 0),
        @"eligibleForAttachment": FPTBool(reason.length == 0),
        @"ineligibleReason": reason,
    };
}

static NSDictionary *FPTStyleFacts(NSWindow *window) {
    NSWindowStyleMask mask = window.styleMask;
    NSButton *close = [window standardWindowButton:NSWindowCloseButton];
    return @{
        @"styleMaskRaw": @(mask),
        @"titled": FPTBool((mask & NSWindowStyleMaskTitled) != 0),
        @"resizable": FPTBool((mask & NSWindowStyleMaskResizable) != 0),
        @"fullSizeContentView": FPTBool((mask & NSWindowStyleMaskFullSizeContentView) != 0),
        @"fullScreen": FPTBool((mask & NSWindowStyleMaskFullScreen) != 0),
        @"titlebarAppearsTransparent": @(window.titlebarAppearsTransparent),
        @"titleHidden": FPTBool(window.titleVisibility == NSWindowTitleHidden),
        @"collectionBehaviorRaw": @(window.collectionBehavior),
        @"fullScreenPrimary":
            FPTBool((window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0),
        @"closeButtonFrame": close ? FPTRect([close convertRect:close.bounds toView:nil])
                                   : [NSNull null],
    };
}

// WindowServer bounds through public CoreGraphics (Quartz, top-left origin).
static NSDictionary *FPTWindowServerFacts(NSWindow *window) {
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    NSRect bounds = NSZeroRect;
    BOOL found = NO;
    if (window.windowNumber > 0) {
        NSArray *infos = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionIncludingWindow, (CGWindowID)window.windowNumber));
        NSDictionary *boundsDict = infos.firstObject[(__bridge NSString *)kCGWindowBounds];
        CGRect rect;
        if (boundsDict &&
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &rect)) {
            bounds = NSRectFromCGRect(rect);
            found = YES;
        }
    }
    facts[@"windowServerBoundsFound"] = @(found);
    facts[@"windowServerBounds"] = FPTRect(bounds);
    NSNumber *displayID = window.screen.deviceDescription[@"NSScreenNumber"];
    if (displayID) {
        NSRect display = NSRectFromCGRect(CGDisplayBounds(displayID.unsignedIntValue));
        facts[@"displayQuartzBounds"] = FPTRect(display);
        facts[@"windowServerCoversDisplay"] = FPTBool(found && FPTRectsNearlyEqual(bounds, display));
    } else {
        facts[@"displayQuartzBounds"] = [NSNull null];
        facts[@"windowServerCoversDisplay"] = @NO;
    }
    NSScreen *primary = NSScreen.screens.firstObject;
    NSRect frame = window.frame;
    NSRect quartzFrame = NSMakeRect(NSMinX(frame), NSMaxY(primary.frame) - NSMaxY(frame),
                                    NSWidth(frame), NSHeight(frame));
    facts[@"windowServerMatchesFrame"] = FPTBool(found && FPTRectsNearlyEqual(bounds, quartzFrame));
    return facts;
}

// The deepest WKWebView in the window (Wry installs one per webview).
static NSView *FPTFindWebView(NSView *root) {
    Class wk = NSClassFromString(@"WKWebView");
    if (!root || !wk) return nil;
    NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        NSView *view = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([view isKindOfClass:wk]) return view;
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

// A screen rect in the window's top-left content coordinates (CSS pixels of a
// webview that fills the window).
static NSDictionary *FPTTopLeftInWindow(NSWindow *window, NSRect screenRect) {
    if (NSIsEmptyRect(screenRect)) return (NSDictionary *)[NSNull null];
    NSRect frame = window.frame;
    return FPTRect(NSMakeRect(NSMinX(screenRect) - NSMinX(frame),
                              NSMaxY(frame) - NSMaxY(screenRect),
                              NSWidth(screenRect), NSHeight(screenRect)));
}

static NSDictionary *FPTGeometryFacts(NSWindow *window, FullPanelSession *session) {
    FullPanelDisplayGeometry *geometry =
        session.geometry ?: (window.screen ? [[FullPanelDisplayGeometry alloc] initWithScreen:window.screen] : nil);
    if (!geometry) return (NSDictionary *)[NSNull null];
    return @{
        @"screenFrame": FPTRect(geometry.screenFrame),
        @"topInset": @(geometry.topInset),
        @"hasCameraHousing": @(geometry.hasCameraHousing),
        @"hasAuxiliaryAreas": @(geometry.hasAuxiliaryAreas),
        @"auxiliaryLeftArea": FPTRect(geometry.auxiliaryLeftArea),
        @"auxiliaryRightArea": FPTRect(geometry.auxiliaryRightArea),
        @"cameraHousingRect": FPTRect(geometry.cameraHousingRect),
        @"leftInWindow": FPTTopLeftInWindow(window, geometry.auxiliaryLeftArea),
        @"rightInWindow": FPTTopLeftInWindow(window, geometry.auxiliaryRightArea),
        @"housingInWindow": FPTTopLeftInWindow(window, geometry.cameraHousingRect),
    };
}

static NSString *FPTStateName(FullPanelState state) {
    switch (state) {
        case FullPanelStateDisabled: return @"Disabled";
        case FullPanelStateInactive: return @"Inactive";
        case FullPanelStateActive: return @"Active";
        case FullPanelStateFallback: return @"Fallback";
    }
    return @"Unknown";
}

static NSDictionary *FPTStateFacts(FullPanelSession *session) {
    if (!session) return @{@"attached": @NO, @"enabled": @NO, @"stateName": @"NoSession"};
    return @{
        @"attached": @(session.isAttached),
        @"enabled": @(session.isEnabled),
        @"state": @(session.state),
        @"stateName": FPTStateName(session.state),
        @"active": @(session.isActive),
        @"fallbackReason": @(session.fallbackReason),
    };
}

static NSDictionary *FPTNativeFacts(NSWindow *window) {
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    [facts addEntriesFromDictionary:FPTClassFacts(window)];
    [facts addEntriesFromDictionary:FPTStyleFacts(window)];
    [facts addEntriesFromDictionary:FPTWindowServerFacts(window)];
    NSScreen *screen = window.screen;
    NSView *contentView = window.contentView;
    NSView *webView = FPTFindWebView(contentView);
    facts[@"windowAddress"] = FPTHex(FPTAddress(window));
    facts[@"windowNumber"] = @(window.windowNumber);
    facts[@"delegateClass"] = window.delegate ? NSStringFromClass([(id)window.delegate class]) : @"";
    facts[@"contentViewClass"] = contentView ? NSStringFromClass([contentView class]) : @"";
    facts[@"contentViewBounds"] = FPTRect(contentView.bounds);
    facts[@"webViewClass"] = webView ? NSStringFromClass([webView class]) : @"";
    facts[@"webViewFrameInWindow"] =
        webView ? FPTRect([webView convertRect:webView.bounds toView:nil]) : [NSNull null];
    facts[@"windowFrame"] = FPTRect(window.frame);
    facts[@"visible"] = @(window.isVisible);
    facts[@"onActiveSpace"] = @(window.isOnActiveSpace);
    facts[@"isKey"] = @(window.isKeyWindow);
    facts[@"level"] = @(window.level);
    facts[@"screenFrame"] = screen ? FPTRect(screen.frame) : [NSNull null];
    facts[@"screenName"] = screen.localizedName ?: @"";
    facts[@"frameCoversScreen"] = FPTBool(screen && FPTRectsNearlyEqual(window.frame, screen.frame));
    // What a style change that keeps the content rect would do to this frame
    // (the 32-point growth seen with ElectronNSWindow; expected 0 here).
    NSRect frame = window.frame;
    NSRect derived = [window frameRectForContentRect:[window contentRectForFrameRect:frame]];
    facts[@"frameConversionGrowth"] = @(NSHeight(derived) - NSHeight(frame));
    facts[@"appPresentationOptionsRaw"] = @(NSApp.presentationOptions);
    return facts;
}

// ---- Exports ------------------------------------------------------------------------

int fpt_is_main_thread(void) {
    return FPTOnMainThread() ? 1 : 0;
}

void fpt_free(char *json) {
    free(json);
}

// Bridge identity and the weakly tracked attachments (main thread).
char *fpt_info(void) {
    if (!FPTOnMainThread()) {
        return FPTFail(@"ERR_FULLPANEL_THREAD", @"must be called on the macOS main thread");
    }
    NSMutableArray *records = [NSMutableArray array];
    NSUInteger liveSessions = 0;
    for (FPTAttachRecord *record in gRecords) {
        FullPanelSession *session = record->_session;
        NSWindow *window = record->_window;
        if (session.isAttached) liveSessions++;
        [records addObject:@{
            @"windowAddress": FPTHex(record->_windowAddress),
            @"windowClass": record->_windowClass ?: @"",
            @"windowAlive": FPTBool(window != nil),
            @"sessionAlive": FPTBool(session != nil),
            @"sessionAttached": @(session.isAttached),
            @"closedByWindow": @(record->_closedByWindow),
            @"observing": FPTBool(record->_closeObserver != nil),
        }];
    }
    return FPTOk(@{
        @"fullPanelSessionImage": FPTImageName([FullPanelSession class]),
        @"systemSupportAvailable": @([FullPanelSession systemSupportAvailable]),
        @"liveSessions": @(liveSessions),
        @"records": records,
        @"appWindowCount": @(NSApp.windows.count),
    });
}

char *fpt_attach(const void *ns_window) {
    char *failure = NULL;
    NSWindow *window = FPTResolveWindow(ns_window, &failure);
    if (!window) return failure;
    BOOL already = [FullPanelSession sessionForWindow:window] != nil;
    NSError *error = nil;
    FullPanelSession *session = [FullPanelSession attachToWindow:window error:&error];
    if (!session) {
        return FPTJSON(@{@"ok": @NO, @"code": @"ERR_FULLPANEL_ATTACH",
                         @"message": error.localizedDescription ?: @"attach failed",
                         @"sessionError": @(error.code), @"window": FPTClassFacts(window)});
    }
    FPTTrackAttachment(window, session);
    return FPTOk(@{@"alreadyAttached": @(already), @"state": FPTStateFacts(session),
                   @"window": FPTClassFacts(window)});
}

char *fpt_set_enabled(const void *ns_window, int enabled) {
    char *failure = NULL;
    NSWindow *window = FPTResolveWindow(ns_window, &failure);
    if (!window) return failure;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    if (!session) return FPTFail(@"ERR_FULLPANEL_NOT_ATTACHED", @"window has no FullPanelSession");
    session.enabled = enabled != 0;
    return FPTOk(@{@"state": FPTStateFacts(session)});
}

char *fpt_detach(const void *ns_window) {
    char *failure = NULL;
    NSWindow *window = FPTResolveWindow(ns_window, &failure);
    if (!window) return failure;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    [session detach];
    FPTAttachRecord *record = FPTLiveRecordForWindow(window);
    if (record) FPTRemoveObserver(record);
    return FPTOk(@{@"wasAttached": FPTBool(session != nil),
                   @"state": FPTStateFacts([FullPanelSession sessionForWindow:window])});
}

char *fpt_state(const void *ns_window) {
    char *failure = NULL;
    NSWindow *window = FPTResolveWindow(ns_window, &failure);
    if (!window) return failure;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    return FPTOk(@{@"state": FPTStateFacts(session),
                   @"geometry": FPTGeometryFacts(window, session)});
}

char *fpt_diagnostics(const void *ns_window) {
    char *failure = NULL;
    NSWindow *window = FPTResolveWindow(ns_window, &failure);
    if (!window) return failure;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    return FPTOk(@{
        @"state": FPTStateFacts(session),
        @"geometry": FPTGeometryFacts(window, session),
        @"native": FPTNativeFacts(window),
        @"session": session ? [session diagnostics] : [NSNull null],
    });
}
