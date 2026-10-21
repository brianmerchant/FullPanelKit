// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// The functions under test are the exact ones the engine calls.

import AppKit
import CoreGraphics
import XCTest
@testable import FullPanelKit
import FullPanelKitCore.Decisions   // test-only decision SPI

// MacBook Pro 14-inch (2021) default scaled resolution.
let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
let inset: CGFloat = 32

final class RectToleranceTests: XCTestCase {
    func testHalfPointTolerance() {
        XCTAssertTrue(FPKRectsNearlyEqual(display, display.insetBy(dx: 0.2, dy: 0.2)))
        XCTAssertFalse(FPKRectsNearlyEqual(display, display.insetBy(dx: 1, dy: 0)))
    }
}

final class FallbackDecisionTests: XCTestCase {
    private func caps(band: Bool = true, geometry: Bool = true, overlay: Bool = true,
                      pinned: Bool = false) -> FPKCapabilities {
        FPKCapabilities(band: band, geometry: geometry, menuBarOverlay: overlay, menuBarPinned: pinned)
    }

    func testEngagesWhenEverythingIsAvailable() {
        XCTAssertEqual(FPKFallbackForCapabilities(caps()), .none)
    }

    func testUnsupportedDisplay() {
        XCTAssertEqual(FPKFallbackForCapabilities(caps(band: false)), .noCameraHousing)
        XCTAssertEqual(FPKFallbackForCapabilities(caps(band: false, geometry: false, overlay: false,
                                                       pinned: true)), .noCameraHousing)
    }

    // Precedence: no band, menu bar pinned, AppKit, SkyLight.
    func testPrecedence() {
        XCTAssertEqual(FPKFallbackForCapabilities(caps(geometry: false, overlay: false, pinned: true)),
                       .menuBarAlwaysShown)
        XCTAssertEqual(FPKFallbackForCapabilities(caps(geometry: false, overlay: false)), .appKitUnavailable)
        XCTAssertEqual(FPKFallbackForCapabilities(caps(geometry: false)), .appKitUnavailable)
        XCTAssertEqual(FPKFallbackForCapabilities(caps(overlay: false)), .skyLightUnavailable)
    }

    func testReasonSummariesExist() {
        let reasons: [FullPanelFallbackReason] = [.none, .noCameraHousing, .appKitUnavailable,
                                                  .skyLightUnavailable, .menuBarAlwaysShown,
                                                  .frameNotAccepted]
        for reason in reasons { XCTAssertFalse(reason.summary.isEmpty) }
    }
}

final class StateTransitionTests: XCTestCase {
    func testResolveState() {
        XCTAssertEqual(FPKResolveState(false, true, true, true, true), .disabled)
        XCTAssertEqual(FPKResolveState(true, false, true, true, true), .inactive)
        XCTAssertEqual(FPKResolveState(true, true, true, true, true), .active)
        XCTAssertEqual(FPKResolveState(true, true, false, false, true), .fallback)
        XCTAssertEqual(FPKResolveState(true, true, true, false, false), .fallback)
        XCTAssertEqual(FPKResolveState(true, true, true, true, false), .fallback)
    }

    // Pointer zones. Measured: the top row reports exactly maxY.
    func testPointerZones() {
        let maxY = display.maxY
        XCTAssertEqual(FPKPointerZoneAt(maxY, maxY, inset), .topEdge)
        XCTAssertEqual(FPKPointerZoneAt(maxY - 0.5, maxY, inset), .topEdge)
        XCTAssertEqual(FPKPointerZoneAt(maxY - 1, maxY, inset), .band)
        XCTAssertEqual(FPKPointerZoneAt(maxY - inset, maxY, inset), .band)
        XCTAssertEqual(FPKPointerZoneAt(maxY - inset - 1, maxY, inset), .content)
    }

    func testRevealRequestLatch() {
        // Set at the top edge only.
        XCTAssertTrue(FPKRevealRequestAfterMove(false, .topEdge, false))
        XCTAssertFalse(FPKRevealRequestAfterMove(false, .band, false))
        XCTAssertFalse(FPKRevealRequestAfterMove(false, .content, false))
        // Kept in the band (moving down into the revealed menu bar).
        XCTAssertTrue(FPKRevealRequestAfterMove(true, .band, false))
        XCTAssertTrue(FPKRevealRequestAfterMove(true, .band, true))
        // Kept below the band while the reveal is still on screen; cleared after.
        XCTAssertTrue(FPKRevealRequestAfterMove(true, .content, true))
        XCTAssertFalse(FPKRevealRequestAfterMove(true, .content, false))
    }

    // A titlebar window AppKit fades (ordinary windows): a reveal starts with
    // the intent and ends with the fade-out, as before.
    func testRevealVisibleWithAFadingTitlebar() {
        // Hidden: faded out, whatever the intent says.
        XCTAssertFalse(FPKRevealVisibleNow(true, true, false, false, true, true))
        // Fading in while AppKit intends the menu bar: on screen.
        XCTAssertTrue(FPKRevealVisibleNow(true, true, true, false, true, true))
        // Opaque without the intent ("Always show toolbar in full screen"): no reveal starts.
        XCTAssertFalse(FPKRevealVisibleNow(true, true, true, false, false, true))
        // The intent ends first; the reveal lasts until the fade-out.
        XCTAssertTrue(FPKRevealVisibleNow(true, true, true, true, false, true))
        XCTAssertFalse(FPKRevealVisibleNow(true, true, false, true, false, true))
    }

    // Without a titlebar window the intent alone decides (unchanged fallback).
    func testRevealVisibleWithoutATitlebar() {
        XCTAssertTrue(FPKRevealVisibleNow(false, false, false, false, true, true))
        XCTAssertTrue(FPKRevealVisibleNow(false, false, false, true, true, false))
        XCTAssertFalse(FPKRevealVisibleNow(false, false, false, true, false, true))
    }

    // Measured on macOS 27.0.1 (FullPanelDemo with a hidden titlebar accessory
    // view controller): AppKit pins the titlebar window's alpha at 1 for the
    // whole entry. Mission Control and
    // Space switches make the intent true while the Space is away; a top-edge
    // reveal makes it true on the Space. Each must end when the intent does.
    func testRevealVisibleWithAPinnedTitlebarFollowsTheIntent() {
        var visible = false
        func read(menuBarVisible: Bool, onSpace: Bool) -> Bool {
            visible = FPKRevealVisibleNow(true, false, true, visible, menuBarVisible, onSpace)
            return visible
        }
        // Entered, menu bar hidden.
        XCTAssertFalse(read(menuBarVisible: false, onSpace: true))
        // Mission Control open (or Control-arrow away): the Space is not shown.
        XCTAssertFalse(read(menuBarVisible: true, onSpace: false))
        // Back on the Space: the intent is false again.
        XCTAssertFalse(read(menuBarVisible: false, onSpace: true))
        // Top-edge reveal: AppKit sets the (unchanged) alpha on every animation step.
        XCTAssertTrue(read(menuBarVisible: true, onSpace: true))
        XCTAssertTrue(read(menuBarVisible: true, onSpace: true))
        // Pointer back in the content: the hide animation's first step ends it.
        XCTAssertFalse(read(menuBarVisible: false, onSpace: true))
        // A reveal on screen when the Space is left ends too.
        XCTAssertTrue(read(menuBarVisible: true, onSpace: true))
        XCTAssertFalse(read(menuBarVisible: true, onSpace: false))
    }

    // The v0.1.0 rule applied to a pinned titlebar window latched: once the
    // intent had been true, an opaque titlebar window kept the reveal forever
    // (black band after every Mission Control or Space return).
    func testPinnedTitlebarDoesNotLatchTheReveal() {
        let afterMissionControl = FPKRevealVisibleNow(true, false, true, true, false, true)
        XCTAssertFalse(afterMissionControl)
    }

    private func facts(tracking: Bool = true, key: Bool = true, onSpace: Bool = true,
                       supported: Bool = true, requested: Bool = false, visible: Bool = false,
                       releasing: Bool = false, forcing: Bool = false) -> FPKFacts {
        FPKFacts(tracking: tracking, key: key, onActiveSpace: onSpace, revealSupported: supported,
                 revealRequested: requested, revealVisible: visible, releasing: releasing,
                 forcing: forcing)
    }

    func testIntentLeavesThePresentationToTheSystemAwayFromTheSpace() {
        XCTAssertEqual(FPKIntentForFacts(facts(onSpace: false)).presentation, .leave)
        XCTAssertEqual(FPKIntentForFacts(facts(onSpace: false, forcing: true)).presentation, .leave)
        // The overlay still follows the reveal state there.
        XCTAssertFalse(FPKIntentForFacts(facts(onSpace: false)).backdropVisible)
    }

    func testIntentAtRestForcesAndClearsTheBand() {
        let i = FPKIntentForFacts(facts())
        XCTAssertEqual(i.presentation, .force)
        XCTAssertFalse(i.backdropVisible)
        XCTAssertTrue(i.titlebarPassThrough)
    }

    func testIntentRelaxesForARequestedOrVisibleReveal() {
        let requested = FPKIntentForFacts(facts(requested: true, forcing: true))
        XCTAssertEqual(requested.presentation, .relax)
        XCTAssertFalse(requested.backdropVisible, "nothing on screen yet")
        let visible = FPKIntentForFacts(facts(visible: true, forcing: false))
        XCTAssertEqual(visible.presentation, .leave)
        XCTAssertTrue(visible.backdropVisible)
        XCTAssertFalse(visible.titlebarPassThrough)
    }

    func testIntentNeverForcesForAWindowThatIsNotKey() {
        XCTAssertEqual(FPKIntentForFacts(facts(key: false)).presentation, .leave)
        XCTAssertEqual(FPKIntentForFacts(facts(key: false, forcing: true)).presentation, .relax)
    }

    func testIntentReleasingHoldsTheOptionsReleased() {
        XCTAssertEqual(FPKIntentForFacts(facts(releasing: true, forcing: true)).presentation, .relax)
        XCTAssertEqual(FPKIntentForFacts(facts(releasing: true)).presentation, .leave)
    }

    func testIntentWithoutRevealSupportAlwaysForcesAndNeverShowsTheBackdrop() {
        let i = FPKIntentForFacts(facts(supported: false, requested: true, visible: true))
        XCTAssertEqual(i.presentation, .force)
        XCTAssertFalse(i.backdropVisible)
        XCTAssertTrue(i.titlebarPassThrough)
    }

    func testIntentWhenNotTrackingTouchesNothingButAForcedValue() {
        let idle = FPKIntentForFacts(facts(tracking: false))
        XCTAssertEqual(idle.presentation, .leave)
        XCTAssertTrue(idle.backdropVisible)
        XCTAssertFalse(idle.titlebarPassThrough)
        XCTAssertEqual(FPKIntentForFacts(facts(tracking: false, forcing: true)).presentation, .relax)
    }

    func testCompositorMatchConvertsCoordinates() {
        // Built-in display as primary: Quartz and AppKit frames coincide.
        XCTAssertTrue(FPKCompositorMatchesFrame(display, display, display.maxY))
        // Window below an external primary display at AppKit y = -982.
        let appKit = CGRect(x: 0, y: -982, width: 1512, height: 982)
        let quartz = CGRect(x: 0, y: 1080, width: 1512, height: 982)
        XCTAssertTrue(FPKCompositorMatchesFrame(quartz, appKit, 1080))
        // Mission Control still scaling the window.
        XCTAssertFalse(FPKCompositorMatchesFrame(display.insetBy(dx: 100, dy: 60), display, display.maxY))
    }

    func testReturnReadiness() {
        XCTAssertTrue(FPKReturnIsReady(true, true, true, 1, 120))
        XCTAssertFalse(FPKReturnIsReady(true, true, true, 0, 10))
        XCTAssertFalse(FPKReturnIsReady(false, true, true, 1, 120))
        XCTAssertFalse(FPKReturnIsReady(true, false, true, 1, 120))
        XCTAssertFalse(FPKReturnIsReady(true, true, false, 1, 120))
        // Unknown compositor state is accepted only after ~18 polls.
        XCTAssertFalse(FPKReturnIsReady(true, true, true, -1, 103))
        XCTAssertTrue(FPKReturnIsReady(true, true, true, -1, 102))
        XCTAssertEqual(Int(FPKReturnCheckBudget), 120)
    }

    func testReturnCheckRearmsOnceWhenWindowActuallyReturns() {
        // Trace 20:35:28-29: check started in Mission Control (away, not key);
        // didBecomeKey on the returned Space must restart its budget.
        XCTAssertTrue(FPKReturnCheckShouldRearm(true, true, true, true, true, false))
        // Only once per check.
        XCTAssertFalse(FPKReturnCheckShouldRearm(true, true, true, true, true, true))
        // No running check: the normal start path applies instead.
        XCTAssertFalse(FPKReturnCheckShouldRearm(false, true, true, true, true, false))
    }

    func testReturnCheckDoesNotRearmWithoutReturn() {
        // Not away (e.g. resize/move or reveal while in fullscreen).
        XCTAssertFalse(FPKReturnCheckShouldRearm(true, false, true, true, true, false))
        // Still in Mission Control: not key, off Space, or not visible.
        XCTAssertFalse(FPKReturnCheckShouldRearm(true, true, false, true, true, false))
        XCTAssertFalse(FPKReturnCheckShouldRearm(true, true, true, false, true, false))
        XCTAssertFalse(FPKReturnCheckShouldRearm(true, true, true, true, false, false))
    }

    func testPresentationReassertOnlyAfterActualReturn() {
        // macOS 15 trace 13:59:50-14:00:00: after a Mission Control return the
        // committed alpha had no effect until forced options were re-applied.
        XCTAssertTrue(FPKReturnNeedsPresentationReassert(true, true, true, false, false))
        // The window's own re-layout (resize/move) is not a return: no repeat.
        XCTAssertFalse(FPKReturnNeedsPresentationReassert(false, true, true, false, false))
        // Already in flight: at most one per return.
        XCTAssertFalse(FPKReturnNeedsPresentationReassert(true, true, true, false, true))
    }

    func testPresentationReassertLeavesRevealAndUnforcedAlone() {
        // Menu bar revealed on purpose at the top edge.
        XCTAssertFalse(FPKReturnNeedsPresentationReassert(true, true, true, true, false))
        // Presentation not forced (reveal allowed) or reveal integration off.
        XCTAssertFalse(FPKReturnNeedsPresentationReassert(true, true, false, false, false))
        XCTAssertFalse(FPKReturnNeedsPresentationReassert(true, false, true, false, false))
    }

    func testRelaxedPresentationFallsBackToAppKitFullscreenOptions() {
        let appKit: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]
        XCTAssertEqual(appKit.rawValue, 0x405)
        // macOS 15 trace 14:12:00: reveal activated while options were still 0.
        XCTAssertEqual(FPKRelaxedPresentationOptions(0), appKit.rawValue)
        // Already fullscreen options: kept as they are.
        XCTAssertEqual(FPKRelaxedPresentationOptions(0x405), 0x405)
        XCTAssertEqual(FPKRelaxedPresentationOptions(0x40a), 0x40a)
    }

    // Raw NSApplicationPresentationOptions values seen on macOS 27.
    let nativeFS: UInt = 0x405   // FullScreen | AutoHideDock | AutoHideMenuBar
    let forcedFS: UInt = 0x40A   // FullScreen | HideDock | HideMenuBar (FullPanel)

    func testNativeFullScreenPresentationCapture() {
        // detach-probe trace: FullPanel forces at the SkyLight commit, before
        // didEnterFullScreen, while the getter still reads the windowed 0x0.
        XCTAssertFalse(FPKIsNativeFullScreenPresentation(true, 0x0, forcedFS))
        // At didEnterFullScreen AppKit has applied its own policy.
        XCTAssertTrue(FPKIsNativeFullScreenPresentation(true, nativeFS, forcedFS))
        // An application policy from window:willUseFullScreenPresentationOptions:
        // (here also auto-hiding the toolbar) is kept as is.
        XCTAssertTrue(FPKIsNativeFullScreenPresentation(true, 0x4405, forcedFS))
        // Never FullPanel's own forced value, never outside fullscreen.
        XCTAssertFalse(FPKIsNativeFullScreenPresentation(true, forcedFS, forcedFS))
        XCTAssertFalse(FPKIsNativeFullScreenPresentation(false, nativeFS, forcedFS))
    }

    func testPresentationRestoreTarget() {
        var target: UInt = 0xFFFF
        // Detach or disable inside fullscreen: the native fullscreen policy, not the
        // windowed 0x0 that AppKit would read back as 0x40A.
        XCTAssertTrue(FPKPresentationRestoreTarget(true, true, nativeFS, 0x0, false, &target))
        XCTAssertEqual(target, nativeFS)
        // Outside fullscreen: the windowed preference saved before entry.
        XCTAssertTrue(FPKPresentationRestoreTarget(false, true, nativeFS, 0x0, false, &target))
        XCTAssertEqual(target, 0x0)
        // Inside fullscreen with no native policy seen: set nothing (no hard-coded default).
        target = 0xFFFF
        XCTAssertFalse(FPKPresentationRestoreTarget(true, false, 0, 0x0, false, &target))
        XCTAssertEqual(target, 0xFFFF)
        // Another FullPanel window, key in fullscreen, still owns the forced options.
        XCTAssertFalse(FPKPresentationRestoreTarget(true, true, nativeFS, 0x0, true, &target))
        XCTAssertFalse(FPKPresentationRestoreTarget(false, true, nativeFS, 0x0, true, &target))
    }
}
