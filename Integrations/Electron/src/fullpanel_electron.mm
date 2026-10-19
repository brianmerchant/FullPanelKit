// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// FullPanelKit for Electron: a Node-API bridge from BrowserWindow handles to
// FullPanelSession. The FullPanelKit engine is compiled unchanged from
// Sources/FullPanelKitCore; this file only resolves windows and forwards to
// the public FullPanelSession API.
//
// Window handles: BrowserWindow.getNativeWindowHandle() returns a Buffer that
// holds an NSView pointer (Electron's GetNativeView(), the window's content
// view), not an NSWindow pointer. The address is never messaged directly. It is
// compared against the views of the application's live windows, so a stale or
// foreign handle is reported as an error instead of being dereferenced.
//
// Safety rules kept here: main thread only; no NSWindow-wide hooks (attachment
// is FullPanelSession's own per-class mechanism); the window's class, delegate
// and content view are never replaced.

#if !__has_feature(objc_arc)
#error fullpanel_electron must be compiled with ARC (-fobjc-arc).
#endif

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <pthread.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <node_api.h>

#import "FullPanelKitCore.h"

// ---- Session bookkeeping ------------------------------------------------------
//
// Sessions are owned by their windows (FullPanelSession's design). The addon
// keeps only weak references, for liveSessions(), and one NSWindowWillClose
// observer per attached window that detaches the session when Electron closes
// the window.

@interface FPEAttachRecord : NSObject {
@public
    __weak NSWindow *_window;
    __weak FullPanelSession *_session;
    uintptr_t _windowAddress;
    NSString *_windowClass;
    id _closeObserver;
    id _willEnterObserver;
    NSSize _preFullScreenSize;   // at the last fullscreen entry seen (see FPEUndoStyleGrowth)
    BOOL _hasPreFullScreenSize;
    BOOL _closedByWindow;
}
@end

@implementation FPEAttachRecord
@end

static NSMutableArray<FPEAttachRecord *> *gRecords;
static NSMutableArray<NSDictionary *> *gFrameCorrections;   // evidence for diagnostics

static NSDictionary *FPERect(NSRect rect);
static BOOL FPERectsNearlyEqual(NSRect a, NSRect b);

static NSString *FPEHex(uintptr_t value) {
    return [NSString stringWithFormat:@"0x%lx", (unsigned long)value];
}

static uintptr_t FPEAddress(id object) {
    return (uintptr_t)(__bridge void *)object;
}

static FPEAttachRecord *FPELiveRecordForWindow(NSWindow *window) {
    for (FPEAttachRecord *record in gRecords) {
        NSWindow *recorded = record->_window;
        if (recorded == window && record->_closeObserver) return record;
    }
    return nil;
}

static void FPERemoveObservers(FPEAttachRecord *record) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (record->_closeObserver) [center removeObserver:record->_closeObserver];
    if (record->_willEnterObserver) [center removeObserver:record->_willEnterObserver];
    record->_closeObserver = nil;
    record->_willEnterObserver = nil;
}

// ---- Frame preservation around FullPanelKit's style restore ----------------------
//
// Disabling or detaching FullPanel restores the window's original style, which
// removes NSWindowStyleMaskFullSizeContentView from a titleBarStyle 'hidden'
// window. AppKit keeps the content rect across that style change: it asks the
// window for -contentRectForFrameRect: and derives the new frame with
// -frameRectForContentRect:. ElectronNSWindow overrides only the first, which
// returns the whole frame for a window without a standard frame; the second is
// AppKit's and adds the titlebar. The frame therefore grows upward by the
// titlebar height (32 pt on macOS 27), bottom edge fixed. Electron avoids this
// for its own style changes with ScopedDisableResize. The integration undoes
// exactly that growth instead; the FullPanelKit engine is unchanged.

static NSRect FPEStyleChangeFrame(NSWindow *window, NSRect frame) {
    return [window frameRectForContentRect:[window contentRectForFrameRect:frame]];
}

static void FPELogCorrection(NSString *when, BOOL applied, NSString *reason, NSRect from, NSRect to,
                             NSRect result) {
    if (!gFrameCorrections) gFrameCorrections = [NSMutableArray array];
    [gFrameCorrections addObject:@{@"when": when, @"applied": @(applied), @"reason": reason,
                                   @"from": FPERect(from), @"to": FPERect(to), @"result": FPERect(result)}];
}

// After FullPanelKit removed fullSizeContentView: if the current frame is
// exactly AppKit's re-derivation of a frame of `originalSize` at the same
// bottom-left origin, set that frame. Anything else is left alone (and logged):
// the frame is never moved, and coordinates are never taken from the past.
static void FPEUndoStyleGrowth(NSWindow *window, NSSize originalSize, NSString *when) {
    NSWindowStyleMask mask = window.styleMask;
    if ((mask & NSWindowStyleMaskFullSizeContentView) || (mask & NSWindowStyleMaskFullScreen)) return;
    NSRect current = window.frame;
    NSRect original = current;
    original.size = originalSize;
    if (FPERectsNearlyEqual(current, original)) return;   // nothing grew
    if (!FPERectsNearlyEqual(FPEStyleChangeFrame(window, original), current)) {
        FPELogCorrection(when, NO, @"frame is not the style-change growth of the original size",
                         current, original, current);
        return;
    }
    [window setFrame:original display:YES];
    FPELogCorrection(when, YES, @"undid titlebar growth", current, original, window.frame);
}

// In fullscreen FullPanelKit restores the style when fullscreen exits, after
// AppKit has put the window back at its pre-fullscreen frame. The size seen at
// fullscreen entry identifies the growth; the position is whatever AppKit chose.
static void FPEUndoStyleGrowthAfterFullScreen(NSWindow *window, NSSize originalSize) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    __weak NSWindow *weakWindow = window;
    __block id exitToken = nil, closeToken = nil;
    void (^finish)(BOOL) = ^(BOOL undo) {
        if (exitToken) [center removeObserver:exitToken];
        if (closeToken) [center removeObserver:closeToken];
        exitToken = closeToken = nil;
        if (!undo) return;
        // After FullPanelKit's own exit handling for this notification.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow *strongWindow = weakWindow;
            if (strongWindow) FPEUndoStyleGrowth(strongWindow, originalSize, @"after fullscreen exit");
        });
    };
    exitToken = [center addObserverForName:NSWindowDidExitFullScreenNotification object:window
                                     queue:nil usingBlock:^(NSNotification *note) { finish(YES); }];
    closeToken = [center addObserverForName:NSWindowWillCloseNotification object:window
                                      queue:nil usingBlock:^(NSNotification *note) { finish(NO); }];
}

// Runs `change` (a disable or detach) and undoes the frame growth its style
// restore causes. Only when fullSizeContentView was on: otherwise the restore
// cannot remove it. In fullscreen without a size from this session's entry
// (attached while already in fullscreen) the style was never applied, so there
// is nothing to undo.
static void FPEPreservingFrame(NSWindow *window, FPEAttachRecord *record, void (^change)(void)) {
    BOOL hadFullSizeContent = (window.styleMask & NSWindowStyleMaskFullSizeContentView) != 0;
    if (window.styleMask & NSWindowStyleMaskFullScreen) {
        change();
        if (hadFullSizeContent && record && record->_hasPreFullScreenSize) {
            FPEUndoStyleGrowthAfterFullScreen(window, record->_preFullScreenSize);
        }
        return;
    }
    NSSize before = window.frame.size;
    change();
    if (hadFullSizeContent) FPEUndoStyleGrowth(window, before, @"windowed");
}

static void FPETrackAttachment(NSWindow *window, FullPanelSession *session) {
    if (!gRecords) gRecords = [NSMutableArray array];
    FPEAttachRecord *record = FPELiveRecordForWindow(window);
    if (record) {
        record->_session = session;
        return;
    }
    record = [[FPEAttachRecord alloc] init];
    record->_window = window;
    record->_session = session;
    record->_windowAddress = FPEAddress(window);
    record->_windowClass = NSStringFromClass([window class]);
    __weak FPEAttachRecord *weakRecord = record;
    __weak NSWindow *weakWindow = window;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    record->_willEnterObserver = [center
        addObserverForName:NSWindowWillEnterFullScreenNotification
                    object:window
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    FPEAttachRecord *strongRecord = weakRecord;
                    NSWindow *strongWindow = weakWindow;
                    if (strongRecord && strongWindow) {
                        strongRecord->_preFullScreenSize = strongWindow.frame.size;
                        strongRecord->_hasPreFullScreenSize = YES;
                    }
                }];
    record->_closeObserver = [center
        addObserverForName:NSWindowWillCloseNotification
                    object:window
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    // Electron never reopens a closed BrowserWindow: detach now so
                    // the engine's observers and the session go away with it.
                    FPEAttachRecord *strongRecord = weakRecord;
                    NSWindow *strongWindow = weakWindow;
                    if (strongWindow) [[FullPanelSession sessionForWindow:strongWindow] detach];
                    if (strongRecord) {
                        strongRecord->_closedByWindow = YES;
                        FPERemoveObservers(strongRecord);
                    }
                }];
    [gRecords addObject:record];
}

// ---- Value conversion -----------------------------------------------------------

static napi_value FPEToJS(napi_env env, id value) {
    napi_value result = nullptr;
    if (!value || value == [NSNull null]) {
        napi_get_null(env, &result);
    } else if ([value isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
            napi_get_boolean(env, [value boolValue], &result);
        } else {
            napi_create_double(env, [value doubleValue], &result);
        }
    } else if ([value isKindOfClass:[NSString class]]) {
        napi_create_string_utf8(env, [value UTF8String], NAPI_AUTO_LENGTH, &result);
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        napi_create_object(env, &result);
        for (id key in (NSDictionary *)value) {
            napi_set_named_property(env, result, [[key description] UTF8String],
                                    FPEToJS(env, ((NSDictionary *)value)[key]));
        }
    } else if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        napi_create_array_with_length(env, array.count, &result);
        for (NSUInteger i = 0; i < array.count; i++) {
            napi_set_element(env, result, (uint32_t)i, FPEToJS(env, array[i]));
        }
    } else {
        napi_create_string_utf8(env, [[value description] UTF8String], NAPI_AUTO_LENGTH, &result);
    }
    return result;
}

static napi_value FPEThrow(napi_env env, const char *code, NSString *message) {
    napi_throw_error(env, code, [[@"fullpanelkit-electron: " stringByAppendingString:message] UTF8String]);
    return nullptr;
}

static NSDictionary *FPERect(NSRect rect) {
    return @{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
             @"width": @(rect.size.width), @"height": @(rect.size.height)};
}

static id FPERectOrNull(NSRect rect) {
    return NSIsEmptyRect(rect) ? [NSNull null] : FPERect(rect);
}

static BOOL FPERectsNearlyEqual(NSRect a, NSRect b) {
    return fabs(a.origin.x - b.origin.x) <= 0.5 && fabs(a.origin.y - b.origin.y) <= 0.5 &&
           fabs(a.size.width - b.size.width) <= 0.5 && fabs(a.size.height - b.size.height) <= 0.5;
}

// ---- Argument handling ------------------------------------------------------------

static bool FPEGetArgs(napi_env env, napi_callback_info info, size_t expected, napi_value *args) {
    size_t argc = expected;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < expected) {
        FPEThrow(env, "ERR_FULLPANEL_ARGS", @"missing argument");
        return false;
    }
    return true;
}

static bool FPERequireMainThread(napi_env env) {
    if (pthread_main_np() && [NSThread isMainThread]) return true;
    FPEThrow(env, "ERR_FULLPANEL_THREAD",
             @"must be called on the macOS main thread (the Electron main process)");
    return false;
}

static NSView *FPEFindViewWithAddress(NSView *root, uintptr_t address) {
    if (!root) return nil;
    NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        NSView *view = stack.lastObject;
        [stack removeLastObject];
        if (FPEAddress(view) == address) return view;
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

// Resolves the Buffer from getNativeWindowHandle() to its live NSWindow by
// address comparison only. Returns nil (and throws) when no live window owns
// the view.
static NSWindow *FPEResolveWindow(napi_env env, napi_value handle, NSView *__strong *viewOut) {
    bool isBuffer = false;
    if (napi_is_buffer(env, handle, &isBuffer) != napi_ok || !isBuffer) {
        FPEThrow(env, "ERR_FULLPANEL_HANDLE",
                 @"expected the Buffer returned by BrowserWindow.getNativeWindowHandle()");
        return nil;
    }
    void *data = nullptr;
    size_t length = 0;
    napi_get_buffer_info(env, handle, &data, &length);
    if (!data || length != sizeof(uintptr_t)) {
        FPEThrow(env, "ERR_FULLPANEL_HANDLE",
                 [NSString stringWithFormat:@"native handle must be %zu bytes, got %zu",
                  sizeof(uintptr_t), length]);
        return nil;
    }
    uintptr_t address = 0;
    memcpy(&address, data, sizeof address);
    if (!address) {
        FPEThrow(env, "ERR_FULLPANEL_HANDLE", @"native handle is null");
        return nil;
    }
    NSArray<NSWindow *> *windows = NSApp.windows;
    // Fast path: Electron's handle is the content view.
    for (NSWindow *window in windows) {
        if (FPEAddress(window.contentView) == address) {
            if (viewOut) *viewOut = window.contentView;
            return window;
        }
    }
    for (NSWindow *window in windows) {
        NSView *contentView = window.contentView;
        NSView *view = FPEFindViewWithAddress(contentView.superview ?: contentView, address);
        if (view) {
            if (viewOut) *viewOut = view;
            return window;
        }
    }
    FPEThrow(env, "ERR_FULLPANEL_NO_WINDOW",
             [NSString stringWithFormat:@"no live NSWindow owns the view %@ (window closed?)",
              FPEHex(address)]);
    return nil;
}

// ---- Window facts -----------------------------------------------------------------

static NSString *FPEImageName(Class cls) {
    const char *image = cls ? class_getImageName(cls) : NULL;
    return image ? @(image) : @"";
}

static NSDictionary *FPEClassFacts(NSWindow *window) {
    Class cls = [window class];
    Class runtimeClass = object_getClass(window);
    NSString *image = FPEImageName(cls);
    NSMutableArray *chain = [NSMutableArray array];
    for (Class c = cls; c; c = class_getSuperclass(c)) [chain addObject:NSStringFromClass(c)];
    // The same rules FullPanelSession applies in +attachToWindow:error:.
    NSString *reason = @"";
    if (![window isKindOfClass:[NSWindow class]]) {
        reason = @"not an NSWindow";
    } else if ([window isKindOfClass:[FullPanelWindow class]]) {
        reason = @"FullPanelWindow (use fullPanelEnabled)";
    } else if ([image containsString:@"/AppKit.framework/"]) {
        reason = @"AppKit-owned class; FullPanelSession does not support AppKit's own window classes";
    }
    return @{
        @"windowClass": NSStringFromClass(cls),
        @"windowRuntimeClass": NSStringFromClass(runtimeClass),
        @"windowClassImage": image,
        @"superclassChain": chain,
        @"isElectronNSWindow": @(strcmp(class_getName(cls), "ElectronNSWindow") == 0),
        @"eligibleForAttachment": @(reason.length == 0),
        @"ineligibleReason": reason,
    };
}

static NSDictionary *FPEStyleFacts(NSWindow *window) {
    NSWindowStyleMask mask = window.styleMask;
    NSButton *close = [window standardWindowButton:NSWindowCloseButton];
    NSButton *zoom = [window standardWindowButton:NSWindowZoomButton];
    return @{
        @"styleMaskRaw": @(mask),
        @"titled": @((mask & NSWindowStyleMaskTitled) != 0),
        @"resizable": @((mask & NSWindowStyleMaskResizable) != 0),
        @"fullSizeContentView": @((mask & NSWindowStyleMaskFullSizeContentView) != 0),
        @"fullScreen": @((mask & NSWindowStyleMaskFullScreen) != 0),
        @"titlebarAppearsTransparent": @(window.titlebarAppearsTransparent),
        @"titleHidden": @(window.titleVisibility == NSWindowTitleHidden),
        @"fullScreenPrimary":
            @((window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0),
        @"closeButtonFrame": close ? FPERect([close convertRect:close.bounds toView:nil])
                                   : [NSNull null],
        @"closeButtonHidden": @(close ? close.hidden : YES),
        @"zoomButtonEnabled": @(zoom ? zoom.enabled : NO),
    };
}

// WindowServer bounds through public CoreGraphics (Quartz, top-left origin).
static NSDictionary *FPEWindowServerFacts(NSWindow *window) {
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    NSRect bounds = NSZeroRect;
    BOOL found = NO;
    if (window.windowNumber > 0) {
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
                                                     (CGWindowID)window.windowNumber);
        NSArray *infos = CFBridgingRelease(list);
        NSDictionary *bounds_dict = infos.firstObject[(__bridge NSString *)kCGWindowBounds];
        CGRect rect;
        if (bounds_dict &&
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds_dict, &rect)) {
            bounds = NSRectFromCGRect(rect);
            found = YES;
        }
    }
    facts[@"windowServerBoundsFound"] = @(found);
    facts[@"windowServerBounds"] = FPERect(bounds);
    NSScreen *screen = window.screen;
    NSNumber *displayID = screen.deviceDescription[@"NSScreenNumber"];
    if (displayID) {
        NSRect display = NSRectFromCGRect(CGDisplayBounds(displayID.unsignedIntValue));
        facts[@"displayQuartzBounds"] = FPERect(display);
        facts[@"windowServerCoversDisplay"] = @(found && FPERectsNearlyEqual(bounds, display));
    } else {
        facts[@"displayQuartzBounds"] = [NSNull null];
        facts[@"windowServerCoversDisplay"] = @NO;
    }
    // The AppKit frame in Quartz coordinates (top-left origin of the primary
    // screen), to compare with the WindowServer outside fullscreen too.
    NSScreen *primary = NSScreen.screens.firstObject;
    NSRect frame = window.frame;
    NSRect quartzFrame = NSMakeRect(NSMinX(frame), NSMaxY(primary.frame) - NSMaxY(frame),
                                    NSWidth(frame), NSHeight(frame));
    facts[@"windowServerMatchesFrame"] = @(found && FPERectsNearlyEqual(bounds, quartzFrame));
    return facts;
}

static NSDictionary *FPENativeFacts(NSWindow *window, NSView *handleView) {
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    [facts addEntriesFromDictionary:FPEClassFacts(window)];
    [facts addEntriesFromDictionary:FPEStyleFacts(window)];
    [facts addEntriesFromDictionary:FPEWindowServerFacts(window)];
    NSView *contentView = window.contentView;
    NSScreen *screen = window.screen;
    facts[@"windowAddress"] = FPEHex(FPEAddress(window));
    facts[@"windowNumber"] = @(window.windowNumber);
    facts[@"handleViewAddress"] = FPEHex(FPEAddress(handleView));
    facts[@"handleViewClass"] = handleView ? NSStringFromClass([handleView class]) : @"";
    facts[@"handleIsContentView"] = @(handleView == contentView);
    facts[@"contentViewClass"] = contentView ? NSStringFromClass([contentView class]) : @"";
    facts[@"contentViewFlipped"] = @(contentView.isFlipped);
    facts[@"contentViewSize"] = @{@"width": @(contentView.bounds.size.width),
                                   @"height": @(contentView.bounds.size.height)};
    facts[@"delegateClass"] = window.delegate ? NSStringFromClass([(id)window.delegate class]) : @"";
    facts[@"windowFrame"] = FPERect(window.frame);
    facts[@"contentLayoutRect"] = FPERect(window.contentLayoutRect);
    facts[@"visible"] = @(window.isVisible);
    facts[@"onActiveSpace"] = @(window.isOnActiveSpace);
    facts[@"screenFrame"] = screen ? FPERect(screen.frame) : [NSNull null];
    facts[@"screenSafeAreaTop"] = @(screen ? screen.safeAreaInsets.top : 0);
    facts[@"screenBackingScaleFactor"] = @(screen ? screen.backingScaleFactor : 0);
    facts[@"screenName"] = screen.localizedName ?: @"";
    facts[@"frameCoversScreen"] = @(screen && FPERectsNearlyEqual(window.frame, screen.frame));
    facts[@"occlusionVisible"] = @((window.occlusionState & NSWindowOcclusionStateVisible) != 0);
    facts[@"isKey"] = @(window.isKeyWindow);
    // What a style change that keeps the content rect does to this frame:
    // the instance's contentRectForFrameRect: (Electron overrides it), then
    // frameRectForContentRect: (AppKit's). growth > 0 is the 32-point issue.
    NSRect frame = window.frame;
    NSRect content = [window contentRectForFrameRect:frame];
    NSRect derived = [window frameRectForContentRect:content];
    facts[@"frameConversion"] = @{
        @"contentRectForFrame": FPERect(content),
        @"frameRectForThatContent": FPERect(derived),
        @"growth": @(NSHeight(derived) - NSHeight(frame)),
        @"appKitContentRectForFrame":
            FPERect([NSWindow contentRectForFrameRect:frame styleMask:window.styleMask]),
    };
    return facts;
}

static NSString *FPEStateName(FullPanelState state) {
    switch (state) {
        case FullPanelStateDisabled: return @"Disabled";
        case FullPanelStateInactive: return @"Inactive";
        case FullPanelStateActive: return @"Active";
        case FullPanelStateFallback: return @"Fallback";
    }
    return @"Unknown";
}

static NSDictionary *FPEStateFacts(FullPanelSession *session) {
    if (!session) return @{@"attached": @NO, @"enabled": @NO, @"stateName": @"NoSession"};
    return @{
        @"attached": @(session.isAttached),
        @"enabled": @(session.isEnabled),
        @"state": @(session.state),
        @"stateName": FPEStateName(session.state),
        @"active": @(session.isActive),
        @"fallbackReason": @(session.fallbackReason),
        @"fallbackDescription": FullPanelFallbackReasonDescription(session.fallbackReason) ?: @"",
    };
}

// ---- Addon identity ---------------------------------------------------------------

static NSString *FPEAddonImage(void) {
    Dl_info info;
    if (dladdr((const void *)&FPEAddonImage, &info) && info.dli_fname) return @(info.dli_fname);
    return @"";
}

static NSString *FPERealPath(NSString *path) {
    char resolved[PATH_MAX];
    return (path.length && realpath(path.fileSystemRepresentation, resolved)) ? @(resolved) : path;
}

// FullPanelKitCore's classes must come from this addon. If another image in the
// process already registered them, the Objective-C runtime would use one copy
// for some calls and the other for the rest; refuse to load instead.
static NSString *FPEDuplicateClassProblem(void) {
    NSString *addon = FPERealPath(FPEAddonImage());
    for (NSString *name in @[@"FullPanelSession", @"FullPanelWindow", @"FullPanelDisplayGeometry"]) {
        NSString *image = FPERealPath(FPEImageName(NSClassFromString(name)));
        if (![image isEqualToString:addon]) {
            return [NSString stringWithFormat:@"%@ is registered by %@, not by this addon (%@)",
                    name, image, addon];
        }
    }
    return nil;
}

// ---- Exports ----------------------------------------------------------------------

static napi_value AddonInfo(napi_env env, napi_callback_info info) {
    uint32_t napiVersion = 0;
    napi_get_version(env, &napiVersion);
    const napi_node_version *node = nullptr;
    napi_get_node_version(env, &node);
    NSString *nodeVersion = node ? [NSString stringWithFormat:@"%u.%u.%u", node->major,
                                    node->minor, node->patch] : @"";
    return FPEToJS(env, @{
        @"addonImage": FPEAddonImage(),
        @"fullPanelSessionImage": FPEImageName([FullPanelSession class]),
        @"duplicateClassProblem": FPEDuplicateClassProblem() ?: [NSNull null],
        @"runtimeNapiVersion": @(napiVersion),
        @"builtForNapiVersion": @(NAPI_VERSION),
        @"runtimeNodeVersion": nodeVersion,
        @"pthreadMainThread": @(pthread_main_np() != 0),
        @"nsThreadMainThread": @([NSThread isMainThread]),
        @"systemSupportAvailable": @([FullPanelSession systemSupportAvailable]),
        @"frameCorrections": gFrameCorrections ?: @[],
    });
}

// Phase 1 bridge check: resolve the handle and report the window's classes.
// Never attaches.
static napi_value Inspect(napi_env env, napi_callback_info info) {
    napi_value args[1];
    if (!FPEGetArgs(env, info, 1, args) || !FPERequireMainThread(env)) return nullptr;
    NSView *view = nil;
    NSWindow *window = FPEResolveWindow(env, args[0], &view);
    if (!window) return nullptr;
    NSMutableDictionary *result = [FPENativeFacts(window, view) mutableCopy];
    result[@"mainThread"] = @YES;
    result[@"hasSession"] = @([FullPanelSession sessionForWindow:window] != nil);
    return FPEToJS(env, result);
}

static napi_value Attach(napi_env env, napi_callback_info info) {
    napi_value args[1];
    if (!FPEGetArgs(env, info, 1, args) || !FPERequireMainThread(env)) return nullptr;
    NSWindow *window = FPEResolveWindow(env, args[0], nullptr);
    if (!window) return nullptr;
    BOOL already = [FullPanelSession sessionForWindow:window] != nil;
    NSError *error = nil;
    FullPanelSession *session = [FullPanelSession attachToWindow:window error:&error];
    if (!session) {
        return FPEToJS(env, @{
            @"ok": @NO,
            @"code": @(error.code),
            @"message": error.localizedDescription ?: @"attach failed",
        });
    }
    FPETrackAttachment(window, session);
    NSMutableDictionary *result = [FPEStateFacts(session) mutableCopy];
    result[@"ok"] = @YES;
    result[@"alreadyAttached"] = @(already);
    result[@"windowClass"] = NSStringFromClass([window class]);
    return FPEToJS(env, result);
}

static napi_value SetEnabled(napi_env env, napi_callback_info info) {
    napi_value args[2];
    if (!FPEGetArgs(env, info, 2, args) || !FPERequireMainThread(env)) return nullptr;
    NSWindow *window = FPEResolveWindow(env, args[0], nullptr);
    if (!window) return nullptr;
    bool enabled = false;
    if (napi_get_value_bool(env, args[1], &enabled) != napi_ok) {
        return FPEThrow(env, "ERR_FULLPANEL_ARGS", @"enabled must be a boolean");
    }
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    if (!session) return FPEToJS(env, @{@"ok": @NO, @"message": @"window is not attached"});
    if (enabled || !session.isEnabled) {
        session.enabled = enabled;
    } else {
        FPEPreservingFrame(window, FPELiveRecordForWindow(window), ^{ session.enabled = NO; });
    }
    NSMutableDictionary *result = [FPEStateFacts(session) mutableCopy];
    result[@"ok"] = @YES;
    return FPEToJS(env, result);
}

static napi_value GetState(napi_env env, napi_callback_info info) {
    napi_value args[1];
    if (!FPEGetArgs(env, info, 1, args) || !FPERequireMainThread(env)) return nullptr;
    NSWindow *window = FPEResolveWindow(env, args[0], nullptr);
    if (!window) return nullptr;
    return FPEToJS(env, FPEStateFacts([FullPanelSession sessionForWindow:window]));
}

// Camera-housing geometry of the window's screen, in AppKit global coordinates
// and in the content view's top-left coordinates (CSS pixels at zoom 1 when the
// web contents fill the content view).
static napi_value GetGeometry(napi_env env, napi_callback_info info) {
    napi_value args[1];
    if (!FPEGetArgs(env, info, 1, args) || !FPERequireMainThread(env)) return nullptr;
    NSWindow *window = FPEResolveWindow(env, args[0], nullptr);
    if (!window) return nullptr;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    NSScreen *screen = window.screen;
    if (!screen) return FPEToJS(env, @{@"screen": [NSNull null]});
    FullPanelDisplayGeometry *geometry = session.geometry
        ?: [[FullPanelDisplayGeometry alloc] initWithScreen:screen];
    NSView *contentView = window.contentView;
    id (^toContent)(NSRect) = ^id(NSRect screenRect) {
        if (NSIsEmptyRect(screenRect)) return [NSNull null];
        NSRect rect = session
            ? [session convertScreenRect:screenRect toView:contentView]
            : [contentView convertRect:[window convertRectFromScreen:screenRect] fromView:nil];
        if (!contentView.isFlipped) rect.origin.y = NSHeight(contentView.bounds) - NSMaxY(rect);
        return FPERect(rect);
    };
    return FPEToJS(env, @{
        @"screenFrame": FPERect(geometry.screenFrame),
        @"topInset": @(geometry.topInset),
        @"hasCameraHousing": @(geometry.hasCameraHousing),
        @"hasAuxiliaryAreas": @(geometry.hasAuxiliaryAreas),
        @"screen": @{
            @"auxiliaryLeftArea": FPERectOrNull(geometry.auxiliaryLeftArea),
            @"auxiliaryRightArea": FPERectOrNull(geometry.auxiliaryRightArea),
            @"cameraHousingRect": FPERectOrNull(geometry.cameraHousingRect),
            @"topBandRect": FPERectOrNull(geometry.topBandRect),
        },
        @"content": @{
            @"width": @(NSWidth(contentView.bounds)),
            @"height": @(NSHeight(contentView.bounds)),
            @"auxiliaryLeftArea": toContent(geometry.auxiliaryLeftArea),
            @"auxiliaryRightArea": toContent(geometry.auxiliaryRightArea),
            @"cameraHousingRect": toContent(geometry.cameraHousingRect),
            @"topBandRect": toContent(geometry.topBandRect),
        },
    });
}

static napi_value GetDiagnostics(napi_env env, napi_callback_info info) {
    napi_value args[1];
    if (!FPEGetArgs(env, info, 1, args) || !FPERequireMainThread(env)) return nullptr;
    NSView *view = nil;
    NSWindow *window = FPEResolveWindow(env, args[0], &view);
    if (!window) return nullptr;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    return FPEToJS(env, @{
        @"native": FPENativeFacts(window, view),
        @"state": FPEStateFacts(session),
        @"session": session ? [session diagnostics] : [NSNull null],
    });
}

static napi_value Detach(napi_env env, napi_callback_info info) {
    napi_value args[1];
    if (!FPEGetArgs(env, info, 1, args) || !FPERequireMainThread(env)) return nullptr;
    NSWindow *window = FPEResolveWindow(env, args[0], nullptr);
    if (!window) return nullptr;
    FullPanelSession *session = [FullPanelSession sessionForWindow:window];
    FPEAttachRecord *record = FPELiveRecordForWindow(window);
    if (session) FPEPreservingFrame(window, record, ^{ [session detach]; });
    if (record) FPERemoveObservers(record);
    return FPEToJS(env, @{@"ok": @YES, @"wasAttached": @(session != nil)});
}

// Every window this addon attached in the process, for cleanup checks.
static napi_value LiveSessions(napi_env env, napi_callback_info info) {
    if (!FPERequireMainThread(env)) return nullptr;
    NSMutableArray *list = [NSMutableArray array];
    for (FPEAttachRecord *record in gRecords) {
        NSWindow *window = record->_window;
        FullPanelSession *session = record->_session;
        [list addObject:@{
            @"windowAddress": FPEHex(record->_windowAddress),
            @"windowClass": record->_windowClass ?: @"",
            @"windowAlive": @(window != nil),
            @"sessionAlive": @(session != nil),
            @"sessionAttached": @(session.isAttached),
            @"closeObserverInstalled": @(record->_closeObserver != nil),
            @"detachedByWindowClose": @(record->_closedByWindow),
        }];
    }
    return FPEToJS(env, list);
}

static napi_value Init(napi_env env, napi_value exports) {
    NSString *problem = FPEDuplicateClassProblem();
    if (problem) return FPEThrow(env, "ERR_FULLPANEL_DUPLICATE_CLASSES", problem);
    const napi_property_descriptor properties[] = {
        {"addonInfo", nullptr, AddonInfo, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
        {"inspect", nullptr, Inspect, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
        {"attach", nullptr, Attach, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
        {"setEnabled", nullptr, SetEnabled, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
        {"getState", nullptr, GetState, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
        {"getGeometry", nullptr, GetGeometry, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
        {"getDiagnostics", nullptr, GetDiagnostics, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
        {"detach", nullptr, Detach, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
        {"liveSessions", nullptr, LiveSessions, nullptr, nullptr, nullptr, napi_enumerable, nullptr},
    };
    napi_define_properties(env, exports, sizeof properties / sizeof properties[0], properties);
    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
