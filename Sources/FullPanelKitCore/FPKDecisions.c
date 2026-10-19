// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// History: earlier, unpublished versions of this file contained portions
// adapted from UTM's Platform/macOS/Display/VMDisplayWindow.swift (Copyright
// © 2026 Turing Software, LLC, Apache-2.0): the whole-display fullscreen-frame
// rule, the arming conditions, the menu-bar alpha target and the top-edge
// pointer rule. The redesign replaced them with FPKChooseFullScreenFrame,
// FPKFallbackForCapabilities, the pointer-zone functions and
// FPKIntentForFacts, written from a behaviour specification;
// FPKChooseFullScreenFrame and the frame-guard decisions were later removed
// with the frame override they served. See docs/PROVENANCE.md.
//
// Pure decision logic used by the FullPanel engine. The other functions come
// from the hardware-tested FullPanel Notch Probe v0.4 (commit 4660e21); see
// docs/HARDWARE_BASELINE.md for the mapping to the original code.

#include "FPKDecisions.h"
#include <math.h>

static bool nearly(CGFloat a, CGFloat b) { return fabs(a - b) < 0.5; }

bool FPKRectsNearlyEqual(CGRect a, CGRect b) {
    return nearly(a.origin.x, b.origin.x) && nearly(a.origin.y, b.origin.y) &&
           nearly(a.size.width, b.size.width) && nearly(a.size.height, b.size.height);
}

FPKReservationHookStatus FPKReservationHookCheck(bool methodsMatch, bool ownMethod,
                                                 bool implementationFromAppKit, bool installed,
                                                 bool implementationIsOurs) {
    if (!methodsMatch) return FPKReservationHookMissing;
    if (!ownMethod) return FPKReservationHookInherited;
    if (installed) return implementationIsOurs ? FPKReservationHookUsable : FPKReservationHookReplaced;
    return implementationFromAppKit ? FPKReservationHookUsable : FPKReservationHookIntercepted;
}

FullPanelFallbackReason FPKFallbackForCapabilities(FPKCapabilities c) {
    if (!c.band) return FullPanelFallbackReasonNoCameraHousing;
    if (c.menuBarPinned) return FullPanelFallbackReasonMenuBarAlwaysShown;
    if (!c.geometry) return FullPanelFallbackReasonAppKitUnavailable;
    if (!c.menuBarOverlay) return FullPanelFallbackReasonSkyLightUnavailable;
    return FullPanelFallbackReasonNone;
}

FullPanelState FPKResolveState(bool enabled, bool inFullScreen, bool armed,
                               bool accepted, bool coversDisplay) {
    if (!enabled) return FullPanelStateDisabled;
    if (!inFullScreen) return FullPanelStateInactive;
    return (armed && accepted && coversDisplay) ? FullPanelStateActive
                                                : FullPanelStateFallback;
}

FPKPointerZone FPKPointerZoneAt(CGFloat pointerY, CGFloat displayMaxY, CGFloat band) {
    if (pointerY >= displayMaxY - 0.5) return FPKPointerZoneTopEdge;
    if (pointerY >= displayMaxY - band) return FPKPointerZoneBand;
    return FPKPointerZoneContent;
}

bool FPKRevealRequestAfterMove(bool requested, FPKPointerZone zone, bool revealVisible) {
    switch (zone) {
        case FPKPointerZoneTopEdge: return true;
        case FPKPointerZoneContent: return revealVisible ? requested : false;
        case FPKPointerZoneBand: return requested;
    }
    return requested;
}

FPKIntent FPKIntentForFacts(FPKFacts f) {
    FPKIntent intent = { .backdropVisible = true, .presentation = FPKPresentationLeave,
                         .titlebarPassThrough = false };
    if (!f.tracking) {
        // Not engaged in this Space: nothing of FullPanel's should show. A
        // forced value left over is relaxed; the full restore is the
        // engine's release path.
        if (f.forcing) intent.presentation = FPKPresentationRelax;
        return intent;
    }
    bool revealOnScreen = f.revealSupported && f.revealVisible;
    bool revealWanted = f.revealSupported && (f.revealRequested || revealOnScreen);
    intent.backdropVisible = revealOnScreen;
    intent.titlebarPassThrough = !revealOnScreen;
    // Away from its Space (Mission Control, a Space switch) the options belong
    // to the system's transition: neither force nor relax until it is back
    // (measured: forcing there captured Mission Control's 0x400 as AppKit's
    // fullscreen policy).
    if (!f.onActiveSpace) return intent;
    if (f.key && !revealWanted && !f.releasing) {
        intent.presentation = FPKPresentationForce;
    } else if (f.forcing) {
        intent.presentation = FPKPresentationRelax;
    }
    return intent;
}

bool FPKCompositorMatchesFrame(CGRect windowServerBounds, CGRect appKitFrame,
                               CGFloat primaryScreenMaxY) {
    // Quartz uses a top-left origin, AppKit a bottom-left global origin.
    CGRect expected = CGRectMake(appKitFrame.origin.x,
                                 primaryScreenMaxY - (appKitFrame.origin.y + appKitFrame.size.height),
                                 appKitFrame.size.width, appKitFrame.size.height);
    return FPKRectsNearlyEqual(windowServerBounds, expected);
}

bool FPKReturnIsReady(bool coversDisplay, bool onActiveSpace, bool isKey,
                      int compositorState, unsigned checksLeft) {
    // If WindowServer doesn't expose the window's bounds, fall back to a
    // short settled-key-window check instead of suppressing a working return.
    bool unknownLongEnough = compositorState < 0 &&
                             checksLeft <= FPKReturnCheckUnknownThreshold;
    return coversDisplay && onActiveSpace && isKey &&
           (compositorState == 1 || unknownLongEnough);
}

unsigned long FPKRelaxedPresentationOptions(unsigned long current) {
    // NSApplicationPresentation: FullScreen 1<<10, AutoHideMenuBar 1<<2,
    // AutoHideDock 1<<0 (AppKit raw values; asserted in DecisionTests).
    const unsigned long fullScreen = 1UL << 10;
    return (current & fullScreen) ? current : (fullScreen | (1UL << 2) | (1UL << 0));
}

bool FPKReturnNeedsPresentationReassert(bool returnFromAway, bool revealActive,
                                        bool forcing, bool revealVisible,
                                        bool alreadyScheduled) {
    return returnFromAway && revealActive && forcing && !revealVisible &&
           !alreadyScheduled;
}

bool FPKReturnCheckShouldRearm(bool checkPending, bool wasAway, bool isKey,
                               bool onActiveSpace, bool visible,
                               bool alreadyRearmed) {
    return checkPending && !alreadyRearmed && wasAway && isKey &&
           onActiveSpace && visible;
}

// NSApplicationPresentationFullScreen (1 << 10).
static const unsigned long FPKPresentationFullScreenBit = 1UL << 10;

bool FPKIsNativeFullScreenPresentation(bool inFullScreen, unsigned long current,
                                       unsigned long forced) {
    return inFullScreen && (current & FPKPresentationFullScreenBit) && current != forced;
}

bool FPKPresentationRestoreTarget(bool inFullScreen, bool nativeValid,
                                  unsigned long native, unsigned long windowed,
                                  bool otherOwnerActive, unsigned long *target) {
    if (otherOwnerActive) return false;
    if (inFullScreen) {
        if (!nativeValid) return false;
        *target = native;
        return true;
    }
    *target = windowed;
    return true;
}

bool FPKReservationRequestPreparesEntry(bool unpreparedEntryAllowed, bool enabled,
                                        bool enteringOrInside, bool inFullScreen) {
    return unpreparedEntryAllowed && enabled && !enteringOrInside && inFullScreen;
}

FPKEntryVerdict FPKVerifyReservationEntry(bool armed, bool inFullScreen, bool coversDisplay,
                                          bool screenHasHousing, bool definitive) {
    if (!armed || !inFullScreen) return FPKEntryVerdictPending;
    if (coversDisplay && screenHasHousing) return FPKEntryVerdictAccepted;
    return definitive ? FPKEntryVerdictRejected : FPKEntryVerdictPending;
}

bool FPKEntryAlreadyUnderway(bool inFullScreen, bool enteringOrInside) {
    return inFullScreen && !enteringOrInside;
}

bool FPKScreenReleasesSession(bool armed, bool inFullScreen, bool screenHasHousing,
                              bool alreadyReleased) {
    return armed && inFullScreen && !screenHasHousing && !alreadyReleased;
}

bool FPKScreenResumesSession(bool released, bool inFullScreen, bool screenHasHousing) {
    return released && inFullScreen && screenHasHousing;
}

FullPanelFallbackReason FPKFullScreenFallbackReason(FullPanelFallbackReason sessionReason,
                                                    bool screenHasHousing) {
    if (sessionReason != FullPanelFallbackReasonNone) return sessionReason;
    return screenHasHousing ? FullPanelFallbackReasonFrameNotAccepted
                            : FullPanelFallbackReasonNoCameraHousing;
}
