// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// FullPanelSession: the FullPanel engine (FPKEngine.m) for an existing window.
// The window keeps its class, isa, method implementations and delegate:
// attaching adds only an associated object and notification observers. The
// engine reaches AppKit through the menu-bar reservation hook
// (FPKAppKitHooks.m), which looks the window's engine up by association.

#if !__has_feature(objc_arc)
#error FullPanelKitCore must be compiled with ARC (-fobjc-arc).
#endif

#import "FullPanelSession.h"
#import "FPKMenuBarOverlay.h"
#import "FPKEngine.h"
#import "FPKSupport.h"
#import "FullPanelWindow+Engine.h"
#import <objc/runtime.h>
#import <string.h>

NSNotificationName const FullPanelSessionStateDidChangeNotification =
    @"FullPanelSessionStateDidChangeNotification";
NSErrorDomain const FullPanelSessionErrorDomain = @"FullPanelSessionErrorDomain";

static char kFPKSessionKey;
static NSUInteger attachedCount;   // main thread only

@interface FullPanelSession () <FPKEngineHost> {
@public
    FPKEngine *_engine;
}
- (void)fpkWindowDidDeallocate;
@end

// The window's associated object. It owns the session, and its deallocation
// (when the window deallocates) detaches the session even if the application
// still holds a reference to it.
@interface FPKSessionOwner : NSObject {
@public
    FullPanelSession *_session;
}
@end

@implementation FPKSessionOwner
- (void)dealloc {
    [_session fpkWindowDidDeallocate];
}
@end

// Runs its block when the window it is associated with is freed (released
// with the window's associated objects, after -[NSWindow dealloc]). The block
// must not message the window.
@interface FPKWindowGoneHandler : NSObject {
@public
    void (^_block)(void);
}
@end

@implementation FPKWindowGoneHandler
- (void)dealloc {
    if (_block) _block();
}
@end

static FullPanelSession *sessionOf(id window) {
    FPKSessionOwner *owner = objc_getAssociatedObject(window, &kFPKSessionKey);
    return owner ? owner->_session : nil;
}

FPKEngine *FPKAttachedEngineForWindow(id window) {
    if (!attachedCount || !window) return nil;
    FullPanelSession *session = sessionOf(window);
    return session ? session->_engine : nil;
}

FPKEngine *FPKEngineForWindow(NSWindow *window) {
    if ([window isKindOfClass:[FullPanelWindow class]]) {
        return ((FullPanelWindow *)window)->_fpkEngine;
    }
    return FPKAttachedEngineForWindow(window);
}

// AppKit's own window classes (NSWindow, NSPanel, ...) are refused. Nothing
// of theirs is modified any more, but attaching to them has not been
// validated (dynamic KVO subclasses, AppKit-owned delegates and windows;
// docs/ATTACHMENT.md), so the restriction stays until it is.
static BOOL classIsAppKitOwned(Class cls) {
    const char *image = class_getImageName(cls);
    return image && strstr(image, "/AppKit.framework/") != NULL;
}

static BOOL fail(NSError **error, FullPanelSessionError code, NSString *message) {
    NSLog(@"FullPanelKit: cannot attach: %@", message);
    if (error) {
        *error = [NSError errorWithDomain:FullPanelSessionErrorDomain code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

@implementation FullPanelSession {
    __weak NSWindow *_window;
    BOOL _attached;
}

+ (FullPanelSession *)attachToWindow:(NSWindow *)window error:(NSError **)error {
    if (![NSThread isMainThread]) {
        fail(error, FullPanelSessionErrorNotMainThread,
             @"FullPanelSession must be used on the main thread.");
        return nil;
    }
    FullPanelSession *existing = sessionOf(window);
    if (existing) return existing;   // idempotent while attached
    if ([window isKindOfClass:[FullPanelWindow class]]) {
        fail(error, FullPanelSessionErrorFullPanelWindow,
             @"The window is a FullPanelWindow; use its fullPanelEnabled property.");
        return nil;
    }
    // -class, not object_getClass(): SwiftUI and other KVO users give the
    // instance a dynamic NSKVONotifying_ subclass of its real class.
    Class cls = [window class];
    if (classIsAppKitOwned(cls)) {
        fail(error, FullPanelSessionErrorUnsupportedWindowClass,
             [NSString stringWithFormat:@"%@ is an AppKit class. FullPanelSession does not support "
              "AppKit's own window classes; create the window as a FullPanelWindow or your own subclass.",
              NSStringFromClass(cls)]);
        return nil;
    }
    FullPanelSession *session = [[FullPanelSession alloc] initWithWindow:window];
    FPKSessionOwner *owner = [[FPKSessionOwner alloc] init];
    owner->_session = session;
    objc_setAssociatedObject(window, &kFPKSessionKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    attachedCount++;
    [session->_engine installLifecycleObservers];
    FPKTrace(@"session-attach", [NSString stringWithFormat:@"window=%p class=%@",
             window, NSStringFromClass(cls)]);
    return session;
}

+ (FullPanelSession *)sessionForWindow:(NSWindow *)window {
    return sessionOf(window);
}

+ (BOOL)systemSupportAvailable {
    return FPKReservationGeometryAvailable() && FPKMenuBarOverlayAvailable();
}

- (instancetype)initWithWindow:(NSWindow *)window {
    if ((self = [super init])) {
        _window = window;
        _attached = YES;
        _engine = [[FPKEngine alloc] initWithWindow:window host:self];
    }
    return self;
}

- (NSWindow *)window { return _window; }
- (BOOL)isAttached { return _attached; }

- (BOOL)isEnabled { return _engine.enabled; }

- (void)setEnabled:(BOOL)enabled {
    if (!_attached) return;
    _engine.enabled = enabled;
}

- (FullPanelState)state { return _engine.state; }
- (FullPanelFallbackReason)fallbackReason { return _engine.fallbackReason; }
- (BOOL)isActive { return _engine.state == FullPanelStateActive; }

+ (NSSet<NSString *> *)keyPathsForValuesAffectingActive {
    return [NSSet setWithObject:@"state"];
}

- (nullable FullPanelDisplayGeometry *)geometry {
    NSScreen *screen = _window.screen;
    return screen ? [[FullPanelDisplayGeometry alloc] initWithScreen:screen] : nil;
}

- (NSRect)convertScreenRect:(NSRect)screenRect toView:(NSView *)view {
    NSWindow *window = view.window ?: _window;
    return [view convertRect:[window convertRectFromScreen:screenRect] fromView:nil];
}

- (void)restoreSystemState {
    [_engine fullPanelWillExitFullScreen];
    [_engine fpkUpdateState];
}

- (void)detach {
    if (!_attached) return;
    // The window's reference may be the last one.
    NS_VALID_UNTIL_END_OF_SCOPE FullPanelSession *keepAlive = self;
    NSWindow *window = _window;
    self.enabled = NO;   // restores system state; style now or after fullscreen
    [_engine teardown];
    if (_engine.styleSyncPending && window) [self restoreStyleAfterFullScreen:window];
    [self willChangeValueForKey:@"attached"];
    _attached = NO;
    attachedCount--;
    FPKSessionOwner *owner = window ? objc_getAssociatedObject(window, &kFPKSessionKey) : nil;
    if (owner && owner->_session == self) {
        owner->_session = nil;
        objc_setAssociatedObject(window, &kFPKSessionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self didChangeValueForKey:@"attached"];
    FPKTrace(@"session-detach", [NSString stringWithFormat:@"window=%p", window]);
    [self fpkEnginePostStateChange];
    (void)keepAlive;
}

// The window is being freed (FPKSessionOwner, released with the window's
// associated objects). The engine holds the window weakly, so from here it
// reads nil and never messages the half-freed window (OmacVM #402); release
// everything and report the session as detached.
- (void)fpkWindowDidDeallocate {
    if (!_attached) return;
    [self willChangeValueForKey:@"attached"];
    _attached = NO;
    attachedCount--;
    [_engine teardown];
    [self didChangeValueForKey:@"attached"];
    FPKTrace(@"session-window-deallocated", nil);
    [self fpkEnginePostStateChange];
}

// Detached during fullscreen: the engine's own observers are gone, so finish
// restoring the window style once, when fullscreen ends. The observers end
// with the window too: a window freed without exiting or closing must not
// leave them (and the engine) registered for an address another window may
// reuse.
- (void)restoreStyleAfterFullScreen:(NSWindow *)window {
    FPKEngine *engine = _engine;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    __weak NSWindow *weakWindow = window;
    // One association per pending restore (keyed by the handler), so a later
    // detach on the same window does not cancel this one.
    FPKWindowGoneHandler *gone = [[FPKWindowGoneHandler alloc] init];
    const void *key = (__bridge const void *)gone;
    __block id exitToken = nil, closeToken = nil;
    __block BOOL done = NO;
    void (^finish)(BOOL) = ^(BOOL restore) {
        if (done) return;
        done = YES;
        if (restore) [engine fpkSyncStyle];
        if (exitToken) [center removeObserver:exitToken];
        if (closeToken) [center removeObserver:closeToken];
        exitToken = closeToken = nil;
        NSWindow *w = weakWindow;   // nil when called because the window is freed
        if (w) objc_setAssociatedObject(w, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    exitToken = [center addObserverForName:NSWindowDidExitFullScreenNotification object:window
                                     queue:nil usingBlock:^(NSNotification *note) { finish(YES); }];
    closeToken = [center addObserverForName:NSWindowWillCloseNotification object:window
                                      queue:nil usingBlock:^(NSNotification *note) { finish(NO); }];
    gone->_block = ^{ finish(NO); };
    objc_setAssociatedObject(window, key, gone, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSDictionary<NSString *, id> *)diagnostics {
    NSMutableDictionary *d = [[_engine diagnostics] mutableCopy];
    NSWindow *window = _window;
    d[@"api"] = @"FullPanelSession";
    d[@"attached"] = @(_attached);
    d[@"windowClass"] = window ? NSStringFromClass([window class]) : @"";
    d[@"windowRuntimeClass"] = window ? NSStringFromClass(object_getClass(window)) : @"";
    d[@"windowPointer"] = window ? [NSString stringWithFormat:@"%p", window] : @"";
    d[@"delegateClass"] = window.delegate ? NSStringFromClass([(id)window.delegate class]) : @"";
    return d;
}

// ---- Engine host --------------------------------------------------------------------

- (void)fpkEngineStateWillChange:(BOOL)stateChanged reason:(BOOL)reasonChanged {
    if (stateChanged) [self willChangeValueForKey:@"state"];
    if (reasonChanged) [self willChangeValueForKey:@"fallbackReason"];
}

- (void)fpkEngineStateDidChange:(BOOL)stateChanged reason:(BOOL)reasonChanged {
    if (reasonChanged) [self didChangeValueForKey:@"fallbackReason"];
    if (stateChanged) [self didChangeValueForKey:@"state"];
}

- (void)fpkEnginePostStateChange {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:FullPanelSessionStateDidChangeNotification object:self];
}

- (void)dealloc {
    // Normally already detached (by -detach or the window's deallocation).
    // Either way nothing may outlive the session.
    if (_attached) {
        _attached = NO;
        attachedCount--;
    }
    [_engine teardown];
}

@end
