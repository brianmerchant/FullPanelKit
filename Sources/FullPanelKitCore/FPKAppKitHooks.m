// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// History: earlier, unpublished versions of this file contained portions
// adapted from UTM's Platform/macOS/Display/VMDisplayWindow.swift (Copyright
// © 2026 Turing Software, LLC, Apache-2.0): the fullscreen-frame override,
// the -toggleFullScreen: and -setFrame:display: attachment wrappers, and the
// menu-bar reveal observer. They were removed or rewritten in a later
// redesign, and the rewritten frame override and attachment wrappers were
// then removed in favour of the menu-bar reservation hook below. The redesign
// was written by authors who had read the adapted code; it is not a
// clean-room implementation. See docs/PROVENANCE.md.
//
// The one private AppKit hook: the fullscreen content controller's menu-bar
// reservation. Its selectors and type encodings are resolved at runtime and
// verified; any mismatch makes the engine fall back to ordinary fullscreen.
//
// No window class is modified: neither FullPanelWindow nor an attached
// window's class gets an override from this file, and -toggleFullScreen: is
// not wrapped (every entry is prepared at willEnterFullScreen; measured entry
// order, docs/ARCHITECTURE.md). The menu-bar reveal is observed
// without hooks (FPKFullScreenTitlebar.m).

#if !__has_feature(objc_arc)
#error FullPanelKitCore must be compiled with ARC (-fobjc-arc).
#endif

#import "FPKAppKitHooks.h"
#import "FPKSupport.h"
#import "FPKEngine.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <pthread.h>
#import <string.h>

// ---- Menu-bar reservation ------------------------------------------------------
//
// In native fullscreen AppKit gives each window a private content controller
// (`_NSFullScreenContentController`, one per fullscreen window, reachable from
// it through `-window`). AppKit asks that controller
// `-reservesSpaceForMenuBarInFullScreen`; on a display with a camera housing
// the answer is YES and AppKit lays the window out below the band.
//
// The controller's class is AppKit's, so this cannot be confined to an
// application class like an ordinary override. The replacement applies to every
// controller in the process, asks AppKit first, and only turns a YES into NO
// for a window whose engine currently claims the band (enabled, armed,
// entering or inside, not rejected: -fpkClaimsMenuBarBand). Every other window,
// including every window of the process without FullPanel, keeps AppKit's
// answer, and so does any call off the main thread (engines are main-thread
// objects). Installed once, at the first enable (FPKEngine), so it is in
// place before that window's entry asks.
//
// It is never restored. Detaching or disabling makes it pass AppKit's answer
// through; putting the original implementation back could undo another
// library's later replacement of the same shared method.
//
// Another library replacing the same selector (FPKReservationHookCheck):
//   - before FullPanelKit: the implementation no longer lies in AppKit's
//     image. FullPanelKit does not install and its entries are ordinary
//     fullscreen (AppKitUnavailable); the other library's behaviour is kept.
//   - after FullPanelKit: the method no longer runs this replacement. Whether
//     the other library still calls it cannot be known, so later entries are
//     ordinary fullscreen. An entry already under way is checked by P1 at
//     didEnterFullScreen: if AppKit did not lay the window out over the
//     display, the entry is rejected and nothing claims the band.
// Swapping implementations with method_exchangeImplementations is detected
// the same way. A library that changes the controller's class (isa swizzling,
// KVO) gets a subclass whose method lookup still reaches this one.

typedef BOOL (*FPKBoolGetter)(id, SEL);
typedef id (*FPKObjectGetter)(id, SEL);

static IMP reservationReplacement;   // set once, by the installation
static bool reservationRefused;      // the installation found the method intercepted

static Method controllerMethod(Class cls, NSString *name, const char *encoding) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    return types && strcmp(types, encoding) == 0 ? method : NULL;
}

// Both controller methods with the encodings verified on macOS 27.0.1 (and
// present by name on 15.8.1; docs/COMPATIBILITY.md). Resolved
// once per process; installs nothing. `own`: the controller class implements
// the reservation method itself rather than inheriting it.
static BOOL reservationMethods(Method *reserves, Method *window, Class *controllerClass, BOOL *own) {
    static Class c;
    static Method r, w;
    static BOOL resolved, implementsItself;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = NSClassFromString(@"_NSFullScreenContentController");
        r = c ? controllerMethod(c, @"reservesSpaceForMenuBarInFullScreen", "B16@0:8") : NULL;
        w = c ? controllerMethod(c, @"window", "@16@0:8") : NULL;
        resolved = r && w;
        Class superclass = c ? class_getSuperclass(c) : Nil;
        implementsItself = resolved &&
            !(superclass && class_getInstanceMethod(superclass, method_getName(r)) == r);
        if (!resolved) NSLog(@"FullPanelKit: AppKit menu-bar reservation unavailable");
    });
    if (reserves) *reserves = r;
    if (window) *window = w;
    if (controllerClass) *controllerClass = c;
    if (own) *own = implementsItself;
    return resolved;
}

// YES when `imp` lies in the image that defines `cls` (AppKit).
static BOOL implementationInImageOfClass(IMP imp, Class cls) {
    Dl_info info;
    const char *image = class_getImageName(cls);
    return imp && image && dladdr((const void *)imp, &info) && info.dli_fname &&
           strcmp(info.dli_fname, image) == 0;
}

static FPKReservationHookStatus reservationStatus(void) {
    Method reserves;
    Class controller;
    BOOL own;
    if (!reservationMethods(&reserves, NULL, &controller, &own)) {
        return FPKReservationHookCheck(false, false, false, false, false);
    }
    if (__atomic_load_n(&reservationRefused, __ATOMIC_ACQUIRE)) {
        return FPKReservationHookCheck(true, own, false, false, false);
    }
    IMP current = method_getImplementation(reserves);
    IMP installed = __atomic_load_n(&reservationReplacement, __ATOMIC_ACQUIRE);
    return FPKReservationHookCheck(true, own, !installed && implementationInImageOfClass(current, controller),
                                   installed != NULL, installed && current == installed);
}

static NSString *reservationStatusDescription(FPKReservationHookStatus status) {
    switch (status) {
        case FPKReservationHookUsable: return nil;
        case FPKReservationHookMissing: return @"AppKit menu-bar reservation unavailable";
        case FPKReservationHookInherited: return @"AppKit menu-bar reservation is inherited, not installed";
        case FPKReservationHookIntercepted:
            return @"AppKit menu-bar reservation already replaced by other code, not installed";
        case FPKReservationHookReplaced:
            return @"AppKit menu-bar reservation replaced by other code after installation";
    }
    return @"AppKit menu-bar reservation unavailable";
}

BOOL FPKMenuBarReservationAvailable(void) { return reservationStatus() == FPKReservationHookUsable; }

BOOL FPKInstallMenuBarReservationHook(NSString **reason) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Decided once: a library that intercepted the method before this
        // point keeps it, and this process never installs.
        FPKReservationHookStatus status = reservationStatus();
        if (status != FPKReservationHookUsable) {
            if (status == FPKReservationHookIntercepted) {
                __atomic_store_n(&reservationRefused, true, __ATOMIC_RELEASE);
            }
            NSLog(@"FullPanelKit: %@", reservationStatusDescription(status));
            return;
        }
        Method reserves, window;
        (void)reservationMethods(&reserves, &window, NULL, NULL);
        SEL reservesSel = method_getName(reserves);
        SEL windowSel = method_getName(window);
        FPKBoolGetter appKitReserves = (FPKBoolGetter)method_getImplementation(reserves);
        FPKObjectGetter windowOf = (FPKObjectGetter)method_getImplementation(window);
        IMP replacement = imp_implementationWithBlock(^BOOL(id contentController) {
            BOOL reservesBand = appKitReserves(contentController, reservesSel);
            if (!reservesBand || !pthread_main_np()) return reservesBand;
            id w = windowOf(contentController, windowSel);
            FPKEngine *e = [w isKindOfClass:[NSWindow class]] ? FPKEngineForWindow(w) : nil;
            // The engine may prepare an entry it was not told about (P2) before
            // it answers.
            return e ? ![e fpkAnswerReservationRequest] : YES;
        });
        method_setImplementation(reserves, replacement);
        __atomic_store_n(&reservationReplacement, replacement, __ATOMIC_RELEASE);
        FPKTrace(@"reservation-hook", @"installed");
    });
    FPKReservationHookStatus status = reservationStatus();
    if (status != FPKReservationHookUsable) {
        if (reason) *reason = reservationStatusDescription(status);
        return NO;
    }
    return YES;
}

BOOL FPKMenuBarReservationHookInstalled(void) {
    return __atomic_load_n(&reservationReplacement, __ATOMIC_ACQUIRE) != NULL &&
           reservationStatus() == FPKReservationHookUsable;
}
