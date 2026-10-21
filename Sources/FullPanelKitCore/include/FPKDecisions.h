// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Pure decision logic used by the FullPanel engine.
//
// Every function here is side-effect free and uses only CoreGraphics value
// types, so it can be unit-tested without a notched display. The engine in
// FPKEngine.m calls exactly these functions — they are not a
// re-implementation for testing.
//
// NOT public API: these may change in any release, including patch releases.
// They are not part of `import FullPanelKit` / `import FullPanelKitCore`; the
// module map puts them in the explicit submodule `FullPanelKitCore.Decisions`
// for FullPanelKit's own tests.

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include "FullPanelTypes.h"

CF_ASSUME_NONNULL_BEGIN
CF_EXTERN_C_BEGIN

/// Rects equal within half a point (AppKit/WindowServer rounding).
bool FPKRectsNearlyEqual(CGRect a, CGRect b);

// ---- Fullscreen geometry ---------------------------------------------------

/// Whether the menu-bar reservation hook may be installed, or still be relied
/// on (FPKAppKitHooks.m). `methodsMatch`: AppKit's content controller has both
/// methods with macOS 27's encodings. `ownMethod`: the controller class
/// implements -reservesSpaceForMenuBarInFullScreen itself, so replacing it
/// cannot change a superclass shared by other classes. `implementationFromAppKit`:
/// before installation, the method's current implementation lies in the
/// controller class's own image (anything else means another library already
/// replaced it). `installed` / `implementationIsOurs`: after installation,
/// whether the method still runs FullPanelKit's replacement.
typedef CF_ENUM(long, FPKReservationHookStatus) {
    FPKReservationHookUsable = 0,        // installable, or installed and still in place
    FPKReservationHookMissing = 1,       // methods missing or encodings differ
    FPKReservationHookInherited = 2,     // implemented by a superclass: not installed
    FPKReservationHookIntercepted = 3,   // replaced by someone else before installation
    FPKReservationHookReplaced = 4,      // replaced by someone else after installation
};
FPKReservationHookStatus FPKReservationHookCheck(bool methodsMatch, bool ownMethod,
                                                 bool implementationFromAppKit, bool installed,
                                                 bool implementationIsOurs);

/// What a FullPanel entry needs from this display and system.
typedef struct FPKCapabilities {
    bool band;                 // the screen has a camera-housing band
    bool geometry;             // the menu-bar reservation hook is installed and usable
    bool menuBarOverlay;       // the menu-bar backdrop override is available
    bool menuBarPinned;        // "Always show menu bar in full screen" is on
} FPKCapabilities;

/// The fallback reason for an entry with these capabilities, or None when
/// FullPanel can engage. Precedence: no band, menu bar pinned, AppKit, SkyLight.
FullPanelFallbackReason FPKFallbackForCapabilities(FPKCapabilities capabilities);

/// Resolved state reported to the application.
FullPanelState FPKResolveState(bool enabled, bool inFullScreen, bool armed,
                               bool accepted, bool coversDisplay);

// ---- Pointer and reveal --------------------------------------------------------

/// Where the pointer is relative to the band, in AppKit global coordinates.
typedef CF_ENUM(long, FPKPointerZone) {
    FPKPointerZoneContent = 0,   // below the band
    FPKPointerZoneBand = 1,      // inside the band, not on the top row
    FPKPointerZoneTopEdge = 2,   // pushed against the top of the display
};

/// AppKit reports a pointer held against the top of a display as exactly the
/// screen's maxY (measured: probe RevealSignals). Half a point of tolerance
/// keeps a fractional trackpad position on the top row.
FPKPointerZone FPKPointerZoneAt(CGFloat pointerY, CGFloat displayMaxY, CGFloat band);

/// Whether the user has asked for a reveal: set at the top edge, kept while
/// the pointer is in the band or a reveal is on screen, cleared in the content.
bool FPKRevealRequestAfterMove(bool requested, FPKPointerZone zone, bool revealVisible);

/// Whether a menu-bar reveal is on screen, re-read whenever AppKit sets the
/// fullscreen titlebar window's alpha (every reveal animation step) or the
/// window's state changes. `menuBarVisible` is `+[NSMenu menuBarVisible]`,
/// AppKit's intent; `wasVisible` the previous answer.
///
/// - No titlebar window (`hasTitlebar` false): the intent alone.
/// - A titlebar window that has been seen faded out (`titlebarFades`): AppKit
///   fades it in with a reveal and out after it, so a reveal starts with the
///   intent and ends with the fade-out (`shown` false).
/// - A titlebar window never seen faded: AppKit pins its alpha at 1 when the
///   window does not reserve the menu bar (FullPanel) and the titlebar window
///   is taller than the autohide height (a titlebar accessory view controller
///   or a toolbar; measured on macOS 27.0.1), or with "Always show toolbar in
///   full screen". Its alpha says nothing about reveals: the intent, while the
///   window's Space is the active one, decides.
bool FPKRevealVisibleNow(bool hasTitlebar, bool titlebarFades, bool shown, bool wasVisible,
                         bool menuBarVisible, bool onActiveSpace);

// ---- Desired system state ---------------------------------------------------

/// What the engine does with the application-wide presentation options.
typedef CF_ENUM(long, FPKPresentationIntent) {
    FPKPresentationLeave = 0,    // do not touch them
    FPKPresentationForce = 1,    // FullScreen | HideMenuBar | HideDock: no reveal
    FPKPresentationRelax = 2,    // stop forcing; AppKit's fullscreen policy applies
};

/// Observed facts the desired state is derived from.
typedef struct FPKFacts {
    bool tracking;          // engaged in this Space: overlay submitted, observers running
    bool key;               // the window is key
    bool onActiveSpace;     // the window's Space is the active Space (not in a transition)
    bool revealSupported;   // deliberate reveals are allowed (FullPanelRevealIntegration)
    bool revealRequested;   // FPKRevealRequestAfterMove
    bool revealVisible;     // AppKit shows the menu bar over the Space
    bool releasing;         // a return re-assert holds the options released
    bool forcing;           // this engine's forced options are in effect
} FPKFacts;

typedef struct FPKIntent {
    bool backdropVisible;            // menu-bar backdrop opaque (alpha 1) or transparent
    FPKPresentationIntent presentation;
    bool titlebarPassThrough;        // AppKit's fullscreen titlebar window ignores the mouse
} FPKIntent;

/// The system state FullPanel wants for one window, from its facts. Pure; the
/// engine applies the difference to what it applied before.
FPKIntent FPKIntentForFacts(FPKFacts facts);

/// WindowServer-bounds check used to decide when a Mission Control return has
/// settled. `windowServerBounds` is top-left-origin (Quartz); `appKitFrame` is
/// bottom-left-origin; `primaryScreenMaxY` is NSMaxY of the primary screen.
bool FPKCompositorMatchesFrame(CGRect windowServerBounds, CGRect appKitFrame,
                               CGFloat primaryScreenMaxY);

/// After this many unanswered compositor polls (of the 120-poll budget), an
/// unknown compositor state (-1) is treated as settled.
enum { FPKReturnCheckBudget = 120, FPKReturnCheckUnknownThreshold = 102 };

/// Whether a Mission Control / Space return may commit the menu-bar alpha.
/// @param compositorState 1 matches, 0 not yet, -1 unknown
bool FPKReturnIsReady(bool coversDisplay, bool onActiveSpace, bool isKey,
                      int compositorState, unsigned checksLeft);

/// Whether a return check that is already running must restart its budget.
/// A check can start while Mission Control is still open (e.g. when the
/// window's occlusion becomes visible). Events from the actual return to the
/// Space were then coalesced into it, so its budget could expire before
/// WindowServer settled. The budget restarts when the window has returned —
/// it was away and is now the visible key window on the active Space — at
/// most once per check, so the check stays bounded (≤ 2 × budget).
bool FPKReturnCheckShouldRearm(bool checkPending, bool wasAway, bool isKey,
                               bool onActiveSpace, bool visible,
                               bool alreadyRearmed);

/// Presentation options to restore when FullPanel stops forcing HideMenuBar.
/// The reveal integration can activate before AppKit has applied its
/// fullscreen options (observed: 0). AppKit rejects options without
/// NSApplicationPresentationFullScreen while in fullscreen, so fall back to
/// AppKit's own fullscreen options (FullScreen | AutoHideMenuBar |
/// AutoHideDock, 0x405), which it sets itself on every Space activation.
unsigned long FPKRelaxedPresentationOptions(unsigned long current);

/// Whether a completed return must re-assert the forced presentation
/// options before committing the menu-bar alpha again. `revealActive` is
/// "tracking" (FPKFacts); `forcing` and `revealVisible` are the FPKFacts fields.
/// macOS 15: after a Mission Control return, AppKit restores the
/// revealable options and FullPanel re-forces HideMenuBar while the Space is
/// still animating in. WindowServer then keeps drawing the fullscreen menu
/// bar opaque over the housing band, ignoring later alpha commits, until the
/// forced options are applied again after the Space settled (what a top-edge
/// reveal does). Only for a check that follows an actual return from away
/// (never the window's own re-layout), while presentation is forced and the
/// menu bar is not revealed.
bool FPKReturnNeedsPresentationReassert(bool returnFromAway, bool revealActive,
                                        bool forcing, bool revealVisible,
                                        bool alreadyScheduled);

/// Presentation options (NSApplicationPresentationOptions raw values).
/// In native fullscreen the getter reports AppKit's fullscreen policy, which
/// includes the application's window:willUseFullScreenPresentationOptions:.
/// It is that policy, not FullPanel's own forced value and not a pre-fullscreen
/// value (no FullScreen bit), that a restore inside fullscreen must return to.
bool FPKIsNativeFullScreenPresentation(bool inFullScreen, unsigned long current,
                                       unsigned long forced);

/// What to set when FullPanel stops forcing presentation options. Inside native
/// fullscreen, AppKit reads a pre-fullscreen value such as 0 back as the hidden
/// menu bar and Dock (verified on macOS 27: 0x0 and 0x400 both read 0x40A), so
/// the saved native fullscreen policy is used; outside fullscreen, the windowed
/// value saved before entry. Returns false (set nothing) inside fullscreen
/// without a native policy, or while another FullPanel window that is key in
/// fullscreen still forces the app-global options.
bool FPKPresentationRestoreTarget(bool inFullScreen, bool nativeValid,
                                  unsigned long native, unsigned long windowed,
                                  bool otherOwnerActive, unsigned long *target);

/// Fullscreen entry preparation (arming). Every native entry posts
/// willEnterFullScreen before AppKit lays out the fullscreen window (measured:
/// probe RevealSignals, entry order), so willEnterFullScreen prepares every
/// entry the engine is told about.

/// An entry whose willEnterFullScreen the engine did not receive (attached
/// and enabled inside that notification) is prepared at AppKit's question to
/// the window's fullscreen content controller whether to reserve the
/// menu-bar band: the session was enabled while the window was windowed (or
/// windowed again after an exit) and nothing prepared an entry since, so the
/// question belongs to a new entry. The controller exists only for a
/// fullscreen transition or session.
bool FPKReservationRequestPreparesEntry(bool unpreparedEntryAllowed, bool enabled,
                                        bool enteringOrInside, bool inFullScreen);

/// Whether a fullscreen entry is verified to have the whole display (P1; the
/// former frame override's acceptance did this).
/// Checked at didEnterFullScreen, or at the first later fullscreen event when
/// that notification was not delivered (state restoration). `definitive` is
/// YES at didEnterFullScreen only: a later check may accept, never reject.
typedef CF_ENUM(long, FPKEntryVerdict) {
    FPKEntryVerdictPending = 0,    // not decided yet
    FPKEntryVerdictAccepted = 1,   // the window covers its display beside the housing
    FPKEntryVerdictRejected = 2,   // AppKit laid it out otherwise (e.g. Split View)
};
FPKEntryVerdict FPKVerifyReservationEntry(bool armed, bool inFullScreen, bool coversDisplay,
                                          bool screenHasHousing, bool definitive);

/// Whether enabling finds the window's fullscreen entry already under way
/// (attached or enabled inside fullscreen): reported, never adopted.
bool FPKEntryAlreadyUnderway(bool inFullScreen, bool enteringOrInside);

/// The window's screen during a fullscreen session. A fullscreen Space can move
/// to another display (Mission Control drag, display arrangement or removal);
/// FullPanel applies only beside a camera housing, so on a display without one
/// the Space is ordinary fullscreen. The entry stays armed: back beside the
/// housing in the same Space, AppKit's layout under the reservation hook gives
/// the window the whole display again (macOS 27 hardware, display-mode round
/// trip) and the menu bar is committed again.

/// Whether FullPanel must release its system state (menu-bar alpha,
/// presentation, reveal, titlebar) because the window's screen has no housing.
bool FPKScreenReleasesSession(bool armed, bool inFullScreen, bool screenHasHousing,
                              bool alreadyReleased);

/// Whether a released session resumes: the window is beside a housing again.
bool FPKScreenResumesSession(bool released, bool inFullScreen, bool screenHasHousing);

/// The reason published for a fullscreen session in .fallback: the entry's own
/// reason, otherwise no camera housing on the current screen, otherwise the
/// frame was not accepted.
FullPanelFallbackReason FPKFullScreenFallbackReason(FullPanelFallbackReason sessionReason,
                                                    bool screenHasHousing);

CF_EXTERN_C_END
CF_ASSUME_NONNULL_END
