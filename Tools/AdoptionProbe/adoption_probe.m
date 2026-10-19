// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../LICENSE).
//
// History: earlier, unpublished versions of this file contained a
// fullscreen-frame override adapted from UTM (Platform/macOS/Display/
// VMDisplayWindow.swift, Copyright © 2026 Turing Software, LLC, Apache-2.0).
// The redesign replaced it with ordinary ProbeWindow method overrides, and
// the probe later stopped overriding the fullscreen frame at all: like the
// library, it now only answers AppKit's menu-bar reservation question.
// See docs/PROVENANCE.md.
//
// Adoption probe: can a window that is ALREADY in a native fullscreen Space be
// given the whole display (the band beside the camera housing) in place?
// Hardware evidence for docs/RESTORED_FULLSCREEN.md. Standalone; not part of
// the library. In its own process only, it replaces
// -[_NSFullScreenContentController reservesSpaceForMenuBarInFullScreen] (the
// method the library's hook replaces) so that, while armed, the probe
// window's controller answers NO, and it logs every call. It enters
// fullscreen, then measures the window frame, WindowServer bounds, Space ID
// and the real pixels beside the housing (screencapture: the launching
// terminal needs Screen Recording).
//
// Build (from this directory):
//   S=../../Sources/FullPanelKitCore
//   clang -fobjc-arc -Wno-deprecated-declarations -framework AppKit -I$S -I$S/include adoption_probe.m \
//         $S/FPKSupport.m $S/FPKMenuBarOverlay.m $S/FPKDecisions.c -o adoption_probe
// Run:  ./adoption_probe <candidate> <outdir>     (about 8 s; enters and leaves fullscreen)
//
// Candidates (all but the armed* ones enter fullscreen UNARMED, like a restored
// window, then arm and try one in-place path):
//   armedEntry          control: armed before entry
//   armAtWillEnter      armed in willEnterFullScreen
//   armMidTransition    armed 0.2 s into the entry
//   none                arm only: does AppKit ask again by itself?
//   resizeContentWindow / companionLayout / ccDisplayChanged / spaceDisplayChanged
//                       AppKit re-layout paths
//   alwaysShows / updateTileShape / reshapeAck   further AppKit paths
//   armedLoseRegain     armed entry, drop to camera-safe, try to regain
//   setFrame            plain -setFrame:display: (not used by FullPanelKit)
// The outcomes recorded in docs/RESTORED_FULLSCREEN.md were measured with the
// former frame override ("moved back" for every in-place path). They do not
// carry over to the reservation answer, which AppKit does re-read for an
// existing fullscreen window (detach in fullscreen re-lays it out at once);
// this version has not been run for them yet.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "FPKSupport.h"
#import "FPKMenuBarOverlay.h"

static BOOL gArm = NO;
static int gReservationCalls = 0, gSetFrameCalls = 0;
static __weak NSWindow *gWindow;
static NSString *gCandidate, *gOut;
static NSMutableArray *gLog;

static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.3f %@", FPKNowMs() / 1000.0, s];
    printf("%s\n", line.UTF8String); fflush(stdout);
    [gLog addObject:line];
}

static NSString *stack(int skip, int n) {
    NSArray *s = [NSThread callStackSymbols];
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = skip; i < MIN(s.count, (NSUInteger)(skip + n)); i++) {
        NSString *f = s[i];
        NSRange r = [f rangeOfString:@"0x"];
        r = [f rangeOfString:@" " options:0 range:NSMakeRange(r.location, f.length - r.location)];
        [o appendFormat:@"\n      %@", [f substringFromIndex:r.location + 1]];
    }
    return o;
}

static BOOL fullStyle(NSWindow *w) { return (w.styleMask & NSWindowStyleMaskFullScreen) != 0; }

// AppKit's question to a fullscreen window's content controller: reserve the
// menu-bar band? Replaced once, in this process, with the encodings macOS 27
// has (any other: the probe reports it and answers nothing itself). While
// armed, the probe window's controller answers NO, as the library's hook does
// for an engaged window; every call is logged.
static BOOL installReservationAnswer(void) {
    Class cls = NSClassFromString(@"_NSFullScreenContentController");
    SEL reservesSel = NSSelectorFromString(@"reservesSpaceForMenuBarInFullScreen");
    SEL windowSel = NSSelectorFromString(@"window");
    Method reserves = cls ? class_getInstanceMethod(cls, reservesSel) : NULL;
    Method window = cls ? class_getInstanceMethod(cls, windowSel) : NULL;
    if (!reserves || !window || strcmp(method_getTypeEncoding(reserves), "B16@0:8") != 0 ||
        strcmp(method_getTypeEncoding(window), "@16@0:8") != 0) return NO;
    BOOL (*appKit)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(reserves);
    id (*windowOf)(id, SEL) = (id (*)(id, SEL))method_getImplementation(window);
    method_setImplementation(reserves, imp_implementationWithBlock(^BOOL(id controller) {
        BOOL appKitAnswer = appKit(controller, reservesSel);
        NSWindow *w = windowOf(controller, windowSel);
        if (w != gWindow) return appKitAnswer;
        BOOL answer = gArm ? NO : appKitAnswer;
        L(@"reservesSpaceForMenuBarInFullScreen #%d arm=%d fs=%d frame=%@ AppKit=%d -> %d%@",
          ++gReservationCalls, gArm, fullStyle(w), NSStringFromRect(w.frame), appKitAnswer, answer,
          stack(2, 9));
        return answer;
    }));
    return YES;
}

// The probe owns its window class; it only logs frame changes.
@interface ProbeWindow : NSWindow @end
@implementation ProbeWindow
- (void)setFrame:(NSRect)frame display:(BOOL)display {
    gSetFrameCalls++;
    if (gArm) L(@"setFrame:display: %@ (fs=%d)%@", NSStringFromRect(frame), fullStyle(self), stack(2, 6));
    [super setFrame:frame display:display];
}
@end

@interface MagentaView : NSView @end
@implementation MagentaView
- (void)drawRect:(NSRect)r { [[NSColor colorWithSRGBRed:1 green:0 blue:1 alpha:1] setFill]; NSRectFill(r); }
@end

// Fraction of magenta pixels in the two regions beside the housing.
static NSString *bandPixels(NSWindow *w, NSString *tag) {
    NSScreen *s = w.screen;
    NSRect left = s.auxiliaryTopLeftArea, right = s.auxiliaryTopRightArea;
    CGFloat top = NSMaxY(s.frame);
    NSString *path = [gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.png", gCandidate, tag]];
    NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/usr/sbin/screencapture"
        arguments:@[@"-x", [NSString stringWithFormat:@"-R0,0,%.0f,%.0f", NSWidth(s.frame), s.safeAreaInsets.top], path]];
    [t waitUntilExit];
    NSBitmapImageRep *rep = (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path];
    if (!rep) return @"capture-failed";
    CGFloat scale = rep.pixelsWide / NSWidth(s.frame);
    NSString *(^frac)(NSRect) = ^NSString *(NSRect r) {
        long mag = 0, n = 0;
        // Sample a grid inside r, avoiding the edges near the housing.
        for (CGFloat x = NSMinX(r) + 8; x < NSMaxX(r) - 8; x += 6) {
            for (CGFloat y = 3; y < (top - NSMinY(r)) - 3; y += 3) {
                NSColor *c = [rep colorAtX:(NSInteger)(x * scale) y:(NSInteger)(y * scale)];
                n++;
                if (c.redComponent > 0.8 && c.greenComponent < 0.45 && c.blueComponent > 0.8) mag++;
            }
        }
        return [NSString stringWithFormat:@"%.2f", n ? (double)mag / n : 0];
    };
    return [NSString stringWithFormat:@"magentaLeft=%@ magentaRight=%@ (%@)", frac(left), frac(right), path.lastPathComponent];
}

static NSString *state(NSWindow *w) {
    BOOL found = NO;
    NSRect ws = FPKWindowServerBounds(w, &found);
    return [NSString stringWithFormat:@"fs=%d frame=%@ ws=%@ space=%llu fsSpace=%llu onActive=%d key=%d content=%@",
            (w.styleMask & NSWindowStyleMaskFullScreen) != 0, NSStringFromRect(w.frame),
            NSStringFromRect(ws), FPKSpaceOfWindow(w), FPKFullscreenSpaceOfWindow(w), w.isOnActiveSpace,
            w.isKeyWindow, NSStringFromRect(w.contentView.frame)];
}

static void after(double s, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), b);
}

static void finish(NSWindow *w) {
    L(@"EXIT begin");
    [w toggleFullScreen:nil];
    after(2.5, ^{
        L(@"after exit: %@", state(w));
        [[gLog componentsJoinedByString:@"\n"] writeToFile:[gOut stringByAppendingPathComponent:
            [gCandidate stringByAppendingString:@".log"]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NSApp terminate:nil];
    });
}

static void runCandidate(NSWindow *w) {
    id cc = [w respondsToSelector:NSSelectorFromString(@"_fullScreenContentController")]
        ? ((id (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"_fullScreenContentController")) : nil;
    id space = [cc respondsToSelector:@selector(space)] ? [cc performSelector:@selector(space)] : nil;
    L(@"contentController=%@ space=%@", [cc class], [space class]);
    int before = gReservationCalls;
    NSString *c = gCandidate;
    if ([c isEqual:@"none"]) {
    } else if ([c isEqual:@"alwaysShows"]) {
        ((void (*)(id, SEL))objc_msgSend)(cc, NSSelectorFromString(@"alwaysShowsMenuBarDidChange"));
    } else if ([c isEqual:@"ccDisplayChanged"]) {
        ((void (*)(id, SEL))objc_msgSend)(cc, NSSelectorFromString(@"displayChanged"));
    } else if ([c isEqual:@"spaceDisplayChanged"]) {
        ((void (*)(id, SEL))objc_msgSend)(space, NSSelectorFromString(@"displayChanged"));
    } else if ([c isEqual:@"updateTileShape"]) {
        ((void (*)(id, SEL))objc_msgSend)(space, NSSelectorFromString(@"updateTileShape"));
    } else if ([c isEqual:@"reshapeAck"]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(space, NSSelectorFromString(@"_updateTileShapeAndReshapeContentsWithAckServer:"), YES);
    } else if ([c isEqual:@"companionLayout"] || [c isEqual:@"resizeContentWindow"]) {
        id comp = ((id (*)(id, SEL))objc_msgSend)(cc, NSSelectorFromString(@"menuBarCompanionController"));
        L(@"companion=%@", [comp class]);
        ((void (*)(id, SEL))objc_msgSend)(comp, NSSelectorFromString([c isEqual:@"companionLayout"] ? @"layout" : @"resizeContentWindow"));
    } else if ([c isEqual:@"setFrame"]) {
        [w setFrame:w.screen.frame display:YES];
    }
    L(@"candidate %@ returned; reservation calls +%d; %@", c, gReservationCalls - before, state(w));
    after(0.3, ^{ L(@"+0.3s %@", state(w)); });
    after(1.5, ^{
        L(@"+1.5s %@ layers:%@", state(w), FPKMenuBarLayerDescription());
        L(@"PIXELS adopted %@", bandPixels(w, @"adopted"));
        finish(w);
    });
}

@interface Delegate : NSObject <NSApplicationDelegate, NSWindowDelegate> { @public NSWindow *_w; } @end
@implementation Delegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    BOOL reservation = installReservationAnswer();
    L(@"AppKit menu-bar reservation %@; SkyLight override %@",
      reservation ? @"answered by the probe" : @"MISSING (encodings differ)",
      FPKMenuBarOverlayAvailable() ? @"available" : @"UNAVAILABLE");
    if (!reservation) { [NSApp terminate:nil]; return; }
    NSRect r = NSMakeRect(200, 200, 700, 450);
    NSWindow *w = [[ProbeWindow alloc] initWithContentRect:r
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                  NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    w.titlebarAppearsTransparent = YES;
    w.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    w.contentView = [[MagentaView alloc] initWithFrame:r];
    w.delegate = self;
    w.restorable = NO;
    _w = w;
    gWindow = w;
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    L(@"screen=%@ inset=%.0f auxL=%@ auxR=%@", NSStringFromRect(w.screen.frame), w.screen.safeAreaInsets.top,
      NSStringFromRect(w.screen.auxiliaryTopLeftArea), NSStringFromRect(w.screen.auxiliaryTopRightArea));
    gArm = [gCandidate isEqual:@"armedEntry"] || [gCandidate isEqual:@"armedLoseRegain"];   // control: a normal armed entry
    after(0.8, ^{ L(@"ENTER (unarmed=%d)", !gArm); [w toggleFullScreen:nil]; });
}
- (void)windowWillEnterFullScreen:(NSNotification *)n {
    L(@"willEnterFullScreen %@", state(_w));
    if ([gCandidate isEqual:@"armAtWillEnter"]) { gArm = YES; L(@"ARM at willEnter"); }
    if ([gCandidate isEqual:@"armMidTransition"]) after(0.2, ^{ gArm = YES; L(@"ARM mid-transition %@", state(self->_w)); });
}
- (void)windowDidEnterFullScreen:(NSNotification *)n {
    NSWindow *w = _w;
    L(@"didEnterFullScreen %@", state(w));
    after(1.5, ^{
        L(@"settled %@", state(w));
        uint64_t sid = FPKFullscreenSpaceOfWindow(w);
        int32_t rc = 0;
        FPKMenuBarOverlaySet(sid, NO, &rc);
        L(@"menu backdrop hidden space=%llu rc=%d", sid, rc);
        after(0.5, ^{
            L(@"PIXELS before %@", bandPixels(w, @"before"));
            if ([gCandidate isEqual:@"armedEntry"] || [gCandidate hasPrefix:@"armAt"] || [gCandidate isEqual:@"armMidTransition"]) {
                L(@"layers %@", FPKMenuBarLayerDescription()); finish(w); return; }
            if ([gCandidate isEqual:@"armedLoseRegain"]) {
                L(@"layers %@", FPKMenuBarLayerDescription());
                gArm = NO;
                id cc = ((id (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"_fullScreenContentController"));
                id comp = ((id (*)(id, SEL))objc_msgSend)(cc, NSSelectorFromString(@"menuBarCompanionController"));
                ((void (*)(id, SEL))objc_msgSend)(comp, NSSelectorFromString(@"resizeContentWindow"));
                after(1.0, ^{
                    L(@"camera-safe now: %@", state(w));
                    L(@"PIXELS lost %@", bandPixels(w, @"lost"));
                    gArm = YES;
                    ((void (*)(id, SEL))objc_msgSend)(comp, NSSelectorFromString(@"resizeContentWindow"));
                    L(@"regain requested: %@", state(w));
                    after(1.5, ^{ L(@"+1.5s %@", state(w)); L(@"PIXELS regained %@", bandPixels(w, @"regained")); finish(w); });
                });
                return;
            }
            gArm = YES;
            L(@"ARM + candidate %@", gCandidate);
            runCandidate(w);
        });
    });
}
- (void)windowWillExitFullScreen:(NSNotification *)n {
    FPKMenuBarOverlaySet(FPKFullscreenSpaceOfWindow(_w), YES, NULL);
    gArm = NO;
}
@end

int main(int argc, char **argv) { @autoreleasepool {
    gCandidate = argc > 1 ? @(argv[1]) : @"none";
    gOut = argc > 2 ? @(argv[2]) : @".";
    gLog = [NSMutableArray array];
    NSApplication *app = [NSApplication sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    Delegate *d = [Delegate new];
    app.delegate = d;
    [app run];
}}
