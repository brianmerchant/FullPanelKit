// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Designed in the redesign described in docs/PROVENANCE.md, from black-box
// measurements (Tools/BehaviorProbes/RevealSignals). Public AppKit API only, apart from the
// class name that identifies AppKit's titlebar window.

#if !__has_feature(objc_arc)
#error FullPanelKitCore must be compiled with ARC (-fobjc-arc).
#endif

#import "FPKFullScreenTitlebar.h"
#import "FPKDecisions.h"
#import "FPKSupport.h"

static char kFPKTitlebarAlphaContext;

// AppKit's class for the fullscreen titlebar/toolbar window (an
// interoperability fact; observed as a child window of the fullscreen window).
static NSString *const kFPKTitlebarWindowClass = @"NSToolbarFullScreenWindow";

// Alpha at or below this counts as "not on screen" (AppKit animates to 0).
static const CGFloat kFPKVisibleAlpha = 0.01;

@implementation FPKFullScreenTitlebar {
    __weak NSWindow *_window;
    void (^_onChange)(void);
    BOOL _running;
    // Held strongly while observed, so KVO is always removed before the
    // titlebar window can go away.
    NSWindow *_observed;
    BOOL _titlebarFades;          // _observed has been seen faded out
    BOOL _savedIgnoresMouse;
    BOOL _changedIgnoresMouse;
    NSView *_hiddenView;          // FullPanelHideTitlebarContent only
    BOOL _savedViewHidden;
    id _childObserver;
}

- (instancetype)initWithWindow:(NSWindow *)window onChange:(void (^)(void))onChange {
    if ((self = [super init])) {
        _window = window;
        _onChange = [onChange copy];
    }
    return self;
}

- (NSWindow *)titlebarWindow { return _observed; }

- (NSString *)source {
    if (!_observed) return @"menu-intent";
    return _titlebarFades ? @"titlebar-alpha" : @"titlebar-pinned";
}

- (void)start {
    if (_running) return;
    _running = YES;
    // AppKit can order a new titlebar window in during transitions; its
    // occlusion change is the cheapest public signal that one appeared.
    __weak FPKFullScreenTitlebar *weakSelf = self;
    _childObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowDidChangeOcclusionStateNotification object:nil queue:nil
                usingBlock:^(NSNotification *note) {
        FPKFullScreenTitlebar *strongSelf = weakSelf;
        NSWindow *other = note.object;
        if (strongSelf && [other isKindOfClass:[NSWindow class]] &&
            other.parentWindow == strongSelf->_window && other != strongSelf->_observed) {
            [strongSelf refresh];
        }
    }];
    [self refresh];
}

- (void)stop {
    if (_childObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_childObserver];
        _childObserver = nil;
    }
    [self follow:nil];
    _running = NO;
    _revealVisible = NO;
}

- (void)refresh {
    if (!_running) return;
    NSWindow *found = nil;
    for (NSWindow *child in _window.childWindows) {
        if ([NSStringFromClass([child class]) isEqualToString:kFPKTitlebarWindowClass]) {
            found = child;
            break;
        }
    }
    if (found != _observed) [self follow:found];
    [self applyPassThrough];
    [self reread];
}

- (void)setPassThrough:(BOOL)passThrough {
    if (passThrough == _passThrough) return;
    _passThrough = passThrough;
    [self applyPassThrough];
}

// ---- Private ----------------------------------------------------------------

// Switches observation to `titlebar` (nil: none), restoring the previous one.
- (void)follow:(nullable NSWindow *)titlebar {
    [self showContent];
    if (_observed) {
        [_observed removeObserver:self forKeyPath:@"alphaValue" context:&kFPKTitlebarAlphaContext];
        if (_changedIgnoresMouse) _observed.ignoresMouseEvents = _savedIgnoresMouse;
        FPKTrace(@"titlebar-released", [NSString stringWithFormat:@"num=%ld",
                                        (long)_observed.windowNumber]);
    }
    _observed = titlebar;
    _titlebarFades = NO;
    _changedIgnoresMouse = NO;
    if (titlebar) {
        [titlebar addObserver:self forKeyPath:@"alphaValue" options:0
                      context:&kFPKTitlebarAlphaContext];
        FPKTrace(@"titlebar-followed", [NSString stringWithFormat:@"num=%ld alpha=%.2f",
                                        (long)titlebar.windowNumber, titlebar.alphaValue]);
    }
}

- (void)applyPassThrough {
    NSWindow *titlebar = _observed;
    if (!titlebar) return;
    if (_passThrough) {
        if (!_changedIgnoresMouse) {
            _savedIgnoresMouse = titlebar.ignoresMouseEvents;
            _changedIgnoresMouse = YES;
        }
        if (!titlebar.ignoresMouseEvents) titlebar.ignoresMouseEvents = YES;
        if (_hidesContentWhilePassingThrough) [self hideContentOf:titlebar];
    } else {
        if (_changedIgnoresMouse) {
            titlebar.ignoresMouseEvents = _savedIgnoresMouse;
            _changedIgnoresMouse = NO;
        }
        [self showContent];
    }
}

// FullPanelHideTitlebarContent only: the frame view that holds the titlebar.
- (void)hideContentOf:(NSWindow *)titlebar {
    NSView *view = titlebar.contentView.superview ?: titlebar.contentView;
    if (!view) return;
    if (view != _hiddenView) {
        [self showContent];
        _hiddenView = view;
        _savedViewHidden = view.hidden;
    }
    if (!view.hidden) {
        view.hidden = YES;
        FPKTrace(@"titlebar-content", [NSString stringWithFormat:@"hidden num=%ld",
                                       (long)titlebar.windowNumber]);
    }
}

- (void)showContent {
    if (!_hiddenView) return;
    _hiddenView.hidden = _savedViewHidden;
    FPKTrace(@"titlebar-content", [NSString stringWithFormat:@"restored hidden=%d", _savedViewHidden]);
    _hiddenView = nil;
}

- (void)reread {
    NSWindow *titlebar = _observed;
    BOOL shown = titlebar && titlebar.alphaValue > kFPKVisibleAlpha;
    // Only a titlebar window AppKit has faded out can end a reveal by fading.
    if (titlebar && !shown && !_titlebarFades) {
        _titlebarFades = YES;
        FPKTrace(@"titlebar-fades", [NSString stringWithFormat:@"num=%ld", (long)titlebar.windowNumber]);
    }
    BOOL visible = FPKRevealVisibleNow(titlebar != nil, _titlebarFades, shown, _revealVisible,
                                       [NSMenu menuBarVisible], _window.isOnActiveSpace);
    if (visible == _revealVisible) return;
    _revealVisible = visible;
    FPKTrace(@"reveal", [NSString stringWithFormat:@"visible=%d source=%@", visible, self.source]);
    if (_onChange) _onChange();
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context != &kFPKTitlebarAlphaContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (object != _observed) return;
    if ([NSThread isMainThread]) {
        [self reread];
    } else {
        __weak FPKFullScreenTitlebar *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reread]; });
    }
}

- (NSString *)traceDescription {
    NSWindow *titlebar = _observed;
    if (!titlebar) return [NSString stringWithFormat:@"titlebar=none reveal=%d", _revealVisible];
    return [NSString stringWithFormat:@"titlebar=%ld alpha=%.2f fades=%d ignoresMouse=%d passThrough=%d reveal=%d",
            (long)titlebar.windowNumber, titlebar.alphaValue, _titlebarFades,
            titlebar.ignoresMouseEvents, _passThrough, _revealVisible];
}

- (void)dealloc {
    if (_hiddenView) _hiddenView.hidden = _savedViewHidden;
    if (_observed) {
        [_observed removeObserver:self forKeyPath:@"alphaValue" context:&kFPKTitlebarAlphaContext];
        if (_changedIgnoresMouse) _observed.ignoresMouseEvents = _savedIgnoresMouse;
    }
    if (_childObserver) [[NSNotificationCenter defaultCenter] removeObserver:_childObserver];
}

@end
