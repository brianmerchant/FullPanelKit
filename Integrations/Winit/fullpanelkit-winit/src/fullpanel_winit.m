// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// FullPanelKit for winit: a C-ABI bridge from the NSView of a raw-window-handle
// AppKitWindowHandle (winit's WinitView, the window's content view) to the
// owning NSWindow's FullPanelSession. The FullPanelKit engine is compiled
// unchanged from Sources/FullPanelKitCore; this file only resolves windows and
// forwards to the public FullPanelSession API.
//
// Every function returns a malloc'd UTF-8 JSON object, released with
// fpw_free(): {"ok": true, ...} or {"ok": false, "code": ..., "message": ...}.
//
// Safety rules kept here: main thread only; the view pointer is never messaged
// until it has been found in the view tree of a window in NSApp.windows; no
// NSWindow-wide hooks (attachment is FullPanelSession's own per-class
// mechanism); the window's class, delegate and content view are never replaced.

#if !__has_feature(objc_arc)
#error fullpanel_winit must be compiled with ARC (-fobjc-arc).
#endif

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#import "FullPanelKitCore.h"

// A comparison is an int in C, and @(int) serializes as 0/1; JSON needs a
// boolean NSNumber.
#define FPWBool(expr) ((expr) ? @YES : @NO)

// ---- Session bookkeeping ----------------------------------------------------------
//
// Sessions are owned by their windows (FullPanelSession's design). The bridge
// keeps weak references, for fpw_info(), and one NSWindowWillClose observer per
// attached window that detaches the session: winit closes the NSWindow when its
// Window is dropped and never reopens it.

@interface FPWAttachRecord : NSObject {
@public
    __weak NSWindow *_window;
    __weak FullPanelSession *_session;
    uintptr_t _windowAddress;
    NSString *_windowClass;
    id _closeObserver;
    BOOL _closedByWindow;
}
@end

@implementation FPWAttachRecord
@end

static NSMutableArray<FPWAttachRecord *> *gRecords;

static NSString *FPWHex(uintptr_t value) {
    return [NSString stringWithFormat:@"0x%lx", (unsigned long)value];
}

static uintptr_t FPWAddress(id object) {
    return (uintptr_t)(__bridge void *)object;
}

static NSDictionary *FPWRect(NSRect rect) {
    return @{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
             @"width": @(rect.size.width), @"height": @(rect.size.height)};
}

static BOOL FPWRectsNearlyEqual(NSRect a, NSRect b) {
    return fabs(a.origin.x - b.origin.x) <= 0.5 && fabs(a.origin.y - b.origin.y) <= 0.5 &&
           fabs(a.size.width - b.size.width) <= 0.5 && fabs(a.size.height - b.size.height) <= 0.5;
}

static FPWAttachRecord *FPWLiveRecordForWindow(NSWindow *window) {
    for (FPWAttachRecord *record in gRecords) {
        NSWindow *recorded = record->_window;
        if (recorded == window && record->_closeObserver) return record;
    }
    return nil;
}

static void FPWRemoveObserver(FPWAttachRecord *record) {
    if (record->_closeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:record->_closeObserver];
    }
    record->_closeObserver = nil;
}

static void FPWTrackAttachment(NSWindow *window, FullPanelSession *session) {
    if (!gRecords) gRecords = [NSMutableArray array];
    FPWAttachRecord *record = FPWLiveRecordForWindow(window);
    if (record) {
        record->_session = session;
        return;
    }
    record = [[FPWAttachRecord alloc] init];
    record->_window = window;
    record->_session = session;
    record->_windowAddress = FPWAddress(window);
    record->_windowClass = NSStringFromClass([window class]);
    __weak FPWAttachRecord *weakRecord = record;
    __weak NSWindow *weakWindow = window;
    record->_closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:window
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    NSWindow *strongWindow = weakWindow;
                    FPWAttachRecord *strongRecord = weakRecord;
                    if (strongWindow) [[FullPanelSession sessionForWindow:strongWindow] detach];
                    if (strongRecord) {
                        strongRecord->_closedByWindow = YES;
                        FPWRemoveObserver(strongRecord);
                    }
                }];
    [gRecords addObject:record];
}

// ---- JSON results ------------------------------------------------------------------

// NSJSONSerialization accepts only strings, finite numbers, NSNull, arrays and
// dictionaries with string keys; diagnostics may hold other values.
static id FPWJSONSafe(id value) {
    if (!value || value == [NSNull null]) return [NSNull null];
    if ([value isKindOfClass:[NSNumber class]]) {
        double d = [value doubleValue];
        return (isfinite(d)) ? value : [NSNull null];
    }
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *)value) out[[key description]] = FPWJSONSafe(value[key]);
        return out;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSArray *)value) [out addObject:FPWJSONSafe(item)];
        return out;
    }
    if ([value isKindOfClass:[NSValue class]] && strcmp([value objCType], @encode(NSRect)) == 0) {
        return FPWRect([value rectValue]);
    }
    return [value description];
}

static char *FPWJSON(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:FPWJSONSafe(object)
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

static char *FPWOk(NSDictionary *fields) {
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    result[@"ok"] = @YES;
    return FPWJSON(result);
}

static char *FPWFail(NSString *code, NSString *message) {
    return FPWJSON(@{@"ok": @NO, @"code": code, @"message": message});
}

// ---- Window resolution -------------------------------------------------------------

static BOOL FPWOnMainThread(void) {
    return pthread_main_np() && [NSThread isMainThread];
}

static NSView *FPWFindViewWithAddress(NSView *root, uintptr_t address) {
    if (!root) return nil;
    NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        NSView *view = stack.lastObject;
        [stack removeLastObject];
        if (FPWAddress(view) == address) return view;
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

// The ns_view from AppKitWindowHandle is compared by address with the views of
// the live windows before it is used, so a stale or foreign pointer is reported
// instead of being messaged. winit's handle is the content view (fast path);
// any other view in a window's tree also resolves to that window.
static NSWindow *FPWResolveWindow(const void *pointer, char **failure) {
    if (!FPWOnMainThread()) {
        *failure = FPWFail(@"ERR_FULLPANEL_THREAD", @"must be called on the macOS main thread");
        return nil;
    }
    if (!pointer) {
        *failure = FPWFail(@"ERR_FULLPANEL_HANDLE", @"NSView pointer is null");
        return nil;
    }
    uintptr_t address = (uintptr_t)pointer;
    NSArray<NSWindow *> *windows = NSApp.windows;
    for (NSWindow *window in windows) {
        if (FPWAddress(window.contentView) == address) return window;
    }
    for (NSWindow *window in windows) {
        NSView *contentView = window.contentView;
        if (FPWFindViewWithAddress(contentView.superview ?: contentView, address)) return window;
    }
    *failure = FPWFail(@"ERR_FULLPANEL_NO_WINDOW",
                       [NSString stringWithFormat:@"no live NSWindow owns the view %@ (window closed?)",
                        FPWHex(address)]);
    return nil;
}

// ---- Window facts --------------------------------------------------------------------

static NSString *FPWImageName(Class cls) {
    const char *image = cls ? class_getImageName(cls) : NULL;
    return image ? @(image) : @"";
}

static NSDictionary *FPWClassFacts(NSWindow *window) {
    Class cls = [window class];
    NSMutableArray *chain = [NSMutableArray array];
    for (Class c = cls; c; c = class_getSuperclass(c)) [chain addObject:NSStringFromClass(c)];
    NSString *image = FPWImageName(cls);
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
        // which is how objc2's declare_class! creates winit's WinitWindow.
        @"windowClassImage": image,
        @"windowClassRegisteredAtRuntime": FPWBool(image.length == 0),
        @"superclassChain": chain,
        @"isWinitWindow": FPWBool(strcmp(class_getName(cls), "WinitWindow") == 0),
        @"eligibleForAttachment": FPWBool(reason.length == 0),
        @"ineligibleReason": reason,
    };
}

static NSDictionary *FPWStyleFacts(NSWindow *window) {
    NSWindowStyleMask mask = window.styleMask;
    NSButton *close = [window standardWindowButton:NSWindowCloseButton];
    return @{
        @"styleMaskRaw": @(mask),
        @"titled": FPWBool((mask & NSWindowStyleMaskTitled) != 0),
        @"resizable": FPWBool((mask & NSWindowStyleMaskResizable) != 0),
        @"fullSizeContentView": FPWBool((mask & NSWindowStyleMaskFullSizeContentView) != 0),
        @"fullScreen": FPWBool((mask & NSWindowStyleMaskFullScreen) != 0),
        @"titlebarAppearsTransparent": @(window.titlebarAppearsTransparent),
        @"titleHidden": FPWBool(window.titleVisibility == NSWindowTitleHidden),
        @"collectionBehaviorRaw": @(window.collectionBehavior),
        @"fullScreenPrimary":
            FPWBool((window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0),
        @"closeButtonFrame": close ? FPWRect([close convertRect:close.bounds toView:nil])
                                   : [NSNull null],
    };
}

// WindowServer bounds through public CoreGraphics (Quartz, top-left origin).
static NSDictionary *FPWWindowServerFacts(NSWindow *window) {
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
    facts[@"windowServerBounds"] = FPWRect(bounds);
    NSNumber *displayID = window.screen.deviceDescription[@"NSScreenNumber"];
    if (displayID) {
        NSRect display = NSRectFromCGRect(CGDisplayBounds(displayID.unsignedIntValue));
        facts[@"displayQuartzBounds"] = FPWRect(display);
        facts[@"windowServerCoversDisplay"] = FPWBool(found && FPWRectsNearlyEqual(bounds, display));
    } else {
        facts[@"displayQuartzBounds"] = [NSNull null];
        facts[@"windowServerCoversDisplay"] = @NO;
    }
    NSScreen *primary = NSScreen.screens.firstObject;
    NSRect frame = window.frame;
    NSRect quartzFrame = NSMakeRect(NSMinX(frame), NSMaxY(primary.frame) - NSMaxY(frame),
                                    NSWidth(frame), NSHeight(frame));
    facts[@"windowServerMatchesFrame"] = FPWBool(found && FPWRectsNearlyEqual(bounds, quartzFrame));
    return facts;
}

// The content view's backing layer and its direct sublayers (softbuffer adds
// one sublayer and keeps it the size of the root layer), in window
// coordinates, so the suite can check that rendering covers the window.
static NSDictionary *FPWLayerFacts(NSView *view) {
    CALayer *layer = view.layer;
    if (!layer) return @{@"layerBacked": @NO};
    NSMutableArray *sublayers = [NSMutableArray array];
    for (CALayer *sublayer in layer.sublayers) {
        [sublayers addObject:@{
            @"class": NSStringFromClass([sublayer class]),
            @"frame": FPWRect(NSRectFromCGRect(sublayer.frame)),
            @"contentsScale": @(sublayer.contentsScale),
            @"hasContents": FPWBool(sublayer.contents != nil),
            @"hidden": @(sublayer.hidden),
        }];
    }
    return @{
        @"layerBacked": @YES,
        @"layerClass": NSStringFromClass([layer class]),
        @"layerBounds": FPWRect(NSRectFromCGRect(layer.bounds)),
        @"contentsScale": @(layer.contentsScale),
        @"sublayers": sublayers,
    };
}

// A screen rect in the window's top-left coordinates, in points (winit's
// logical pixels for a content view that fills the window).
static NSDictionary *FPWTopLeftInWindow(NSWindow *window, NSRect screenRect) {
    if (NSIsEmptyRect(screenRect)) return (NSDictionary *)[NSNull null];
    NSRect frame = window.frame;
    return FPWRect(NSMakeRect(NSMinX(screenRect) - NSMinX(frame),
                              NSMaxY(frame) - NSMaxY(screenRect),
                              NSWidth(screenRect), NSHeight(screenRect)));
}

static NSDictionary *FPWGeometryFacts(NSWindow *window, FullPanelSession *session) {
    FullPanelDisplayGeometry *geometry =
        session.geometry ?: (window.screen ? [[FullPanelDisplayGeometry alloc] initWithScreen:window.screen] : nil);
    if (!geometry) return (NSDictionary *)[NSNull null];
    return @{
        @"screenFrame": FPWRect(geometry.screenFrame),
        @"topInset": @(geometry.topInset),
        @"hasCameraHousing": @(geometry.hasCameraHousing),
        @"hasAuxiliaryAreas": @(geometry.hasAuxiliaryAreas),
        @"auxiliaryLeftArea": FPWRect(geometry.auxiliaryLeftArea),
        @"auxiliaryRightArea": FPWRect(geometry.auxiliaryRightArea),
        @"cameraHousingRect": FPWRect(geometry.cameraHousingRect),
        @"leftInWindow": FPWTopLeftInWindow(window, geometry.auxiliaryLeftArea),
        @"rightInWindow": FPWTopLeftInWindow(window, geometry.auxiliaryRightArea),
        @"housingInWindow": FPWTopLeftInWindow(window, geometry.cameraHousingRect),
        @"backingScaleFactor": @(window.backingScaleFactor),
    };
}

static NSString *FPWStateName(FullPanelState state) {
    switch (state) {
        case FullPanelStateDisabled: return @"Disabled";
        case FullPanelStateInactive: return @"Inactive";
        case FullPanelStateActive: return @"Active";
        case FullPanelStateFallback: return @"Fallback";
    }
    return @"Unknown";
}

static NSDictionary *FPWStateFacts(FullPanelSession *session) {
    if (!session) return @{@"attached": @NO, @"enabled": @NO, @"stateName": @"NoSession"};
    return @{
        @"attached": @(session.isAttached),
        @"enabled": @(session.isEnabled),
        @"state": @(session.state),
        @"stateName": FPWStateName(session.state),
        @"active": @(session.isActive),
        @"fallbackReason": @(session.fallbackReason),
    };
}

static NSDictionary *FPWNativeFacts(NSWindow *window, const void *handleView) {
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    [facts addEntriesFromDictionary:FPWClassFacts(window)];
    [facts addEntriesFromDictionary:FPWStyleFacts(window)];
    [facts addEntriesFromDictionary:FPWWindowServerFacts(window)];
    NSScreen *screen = window.screen;
    NSView *contentView = window.contentView;
    facts[@"windowAddress"] = FPWHex(FPWAddress(window));
    facts[@"windowNumber"] = @(window.windowNumber);
    facts[@"delegateClass"] = window.delegate ? NSStringFromClass([(id)window.delegate class]) : @"";
    facts[@"contentViewClass"] = contentView ? NSStringFromClass([contentView class]) : @"";
    facts[@"handleIsContentView"] = FPWBool(FPWAddress(contentView) == (uintptr_t)handleView);
    facts[@"contentViewFrameInWindow"] =
        contentView ? FPWRect([contentView convertRect:contentView.bounds toView:nil]) : [NSNull null];
    facts[@"contentViewBounds"] = FPWRect(contentView.bounds);
    facts[@"contentViewFlipped"] = @(contentView.isFlipped);
    facts[@"contentLayer"] = FPWLayerFacts(contentView);
    facts[@"backingScaleFactor"] = @(window.backingScaleFactor);
    facts[@"windowFrame"] = FPWRect(window.frame);
    facts[@"visible"] = @(window.isVisible);
    facts[@"onActiveSpace"] = @(window.isOnActiveSpace);
    facts[@"isKey"] = @(window.isKeyWindow);
    facts[@"level"] = @(window.level);
    facts[@"screenFrame"] = screen ? FPWRect(screen.frame) : [NSNull null];
    facts[@"screenName"] = screen.localizedName ?: @"";
    facts[@"frameCoversScreen"] = FPWBool(screen && FPWRectsNearlyEqual(window.frame, screen.frame));
    // What a style change that keeps the content rect would do to this frame
    // (the 32-point growth seen with ElectronNSWindow; expected 0 here).
    NSRect frame = window.frame;
    NSRect derived = [window frameRectForContentRect:[window contentRectForFrameRect:frame]];
    facts[@"frameConversionGrowth"] = @(NSHeight(derived) - NSHeight(frame));
    facts[@"appPresentationOptionsRaw"] = @(NSApp.presentationOptions);
    return facts;
}

// ---- Exports ------------------------------------------------------------------------

int fpw_is_main_thread(void) {
    return FPWOnMainThread() ? 1 : 0;
}

void fpw_free(char *json) {
    free(json);
}

// Bridge identity and the weakly tracked attachments (main thread).
char *fpw_info(void) {
    if (!FPWOnMainThread()) {
        return FPWFail(@"ERR_FULLPANEL_THREAD", @"must be called on the macOS main thread");
    }
    NSMutableArray *records = [NSMutableArray array];
    NSUInteger liveSessions = 0;
    for (FPWAttachRecord *record in gRecords) {
        FullPanelSession *session = record->_session;
        NSWindow *window = record->_window;
        if (session.isAttached) liveSessions++;
        [records addObject:@{
            @"windowAddress": FPWHex(record->_windowAddress),
            @"windowClass": record->_windowClass ?: @"",
            @"windowAlive": FPWBool(window != nil),
            @"sessionAlive": FPWBool(session != nil),
            @"sessionAttached": @(session.isAttached),
            @"closedByWindow": @(record->_closedByWindow),
            @"observing": FPWBool(record->_closeObserver != nil),
        }];
    }
    return FPWOk(@{
        @"fullPanelSessionImage": FPWImageName([FullPanelSession class]),
        @"systemSupportAvailable": @([FullPanelSession systemSupportAvailable]),
        @"liveSessions": @(liveSessions),
        @"records": records,
        @"appWindowCount": @(NSApp.windows.count),
    });
}

char *fpw_attach(const void *ns_view) {
    char *failure = NULL;
    NSWindow *window = FPWResolveWindow(ns_view, &failure);
    if (!window) return failure;
    BOOL already = [FullPanelSession sessionForWindow:window] != nil;
    NSError *error = nil;
    FullPanelSession *session = [FullPanelSession attachToWindow:window error:&error];
    if (!session) {
        return FPWJSON(@{@"ok": @NO, @"code": @"ERR_FULLPANEL_ATTACH",
                         @"message": error.localizedDescription ?: @"attach failed",
                         @"sessionError": @(error.code), @"window": FPWClassFacts(window)});
    }
    FPWTrackAttachment(window, session);
    return FPWOk(@{@"alreadyAttached": @(already), @"state": FPWStateFacts(session),
                   @"window": FPWClassFacts(window)});
}

char *fpw_set_enabled(const void *ns_view, int enabled) {
    char *failure = NULL;
    NSWindow *window = FPWResolveWindow(ns_view, &failure);
    if (!window) return failure;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    if (!session) return FPWFail(@"ERR_FULLPANEL_NOT_ATTACHED", @"window has no FullPanelSession");
    session.enabled = enabled != 0;
    return FPWOk(@{@"state": FPWStateFacts(session)});
}

char *fpw_detach(const void *ns_view) {
    char *failure = NULL;
    NSWindow *window = FPWResolveWindow(ns_view, &failure);
    if (!window) return failure;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    [session detach];
    FPWAttachRecord *record = FPWLiveRecordForWindow(window);
    if (record) FPWRemoveObserver(record);
    return FPWOk(@{@"wasAttached": FPWBool(session != nil),
                   @"state": FPWStateFacts([FullPanelSession sessionForWindow:window])});
}

char *fpw_state(const void *ns_view) {
    char *failure = NULL;
    NSWindow *window = FPWResolveWindow(ns_view, &failure);
    if (!window) return failure;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    return FPWOk(@{@"state": FPWStateFacts(session),
                   @"geometry": FPWGeometryFacts(window, session)});
}

char *fpw_diagnostics(const void *ns_view) {
    char *failure = NULL;
    NSWindow *window = FPWResolveWindow(ns_view, &failure);
    if (!window) return failure;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    return FPWOk(@{
        @"state": FPWStateFacts(session),
        @"geometry": FPWGeometryFacts(window, session),
        @"native": FPWNativeFacts(window, ns_view),
        @"session": session ? [session diagnostics] : [NSNull null],
    });
}

// ---- Test support -------------------------------------------------------------------
//
// For the automated suite only. Hit-tests the content view at a point in the
// window's top-left coordinates (points) and, when post is non-zero, posts a
// synthetic left mouse down and up there to the application's event queue. The
// events go through -[NSApplication sendEvent:] and -[NSWindow sendEvent:] to
// the hit view, as a real click does after WindowServer routing; they do not
// exercise WindowServer, the menu-bar reveal or the physical pointer.

char *fpw_test_click(const void *ns_view, double x, double y, int post) {
    char *failure = NULL;
    NSWindow *window = FPWResolveWindow(ns_view, &failure);
    if (!window) return failure;
    NSView *contentView = window.contentView;
    NSPoint windowPoint = NSMakePoint(x, NSHeight(window.frame) - y);
    NSView *hit = [contentView.superview ?: contentView hitTest:
                       [contentView.superview ?: contentView convertPoint:windowPoint fromView:nil]];
    if (post) {
        NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
        const NSEventType types[] = {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp};
        for (size_t i = 0; i < 2; i++) {
            NSEventType type = types[i];
            NSEvent *event = [NSEvent mouseEventWithType:type
                                                location:windowPoint
                                           modifierFlags:0
                                               timestamp:now
                                            windowNumber:window.windowNumber
                                                 context:nil
                                             eventNumber:0
                                              clickCount:1
                                                pressure:type == NSEventTypeLeftMouseDown ? 1.0 : 0.0];
            [NSApp postEvent:event atStart:NO];
        }
    }
    return FPWOk(@{
        @"windowPoint": @{@"x": @(windowPoint.x), @"y": @(windowPoint.y)},
        @"hitViewClass": hit ? NSStringFromClass([hit class]) : @"",
        @"hitIsContentView": FPWBool(hit == contentView),
        @"posted": FPWBool(post != 0),
    });
}
