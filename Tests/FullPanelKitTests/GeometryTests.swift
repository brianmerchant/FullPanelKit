// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

import AppKit
import XCTest
@testable import FullPanelKit

final class GeometryTests: XCTestCase {
    // Representative 14-inch values (points). Real values come from NSScreen.
    let left = NSRect(x: 0, y: 950, width: 654, height: 32)
    let right = NSRect(x: 858, y: 950, width: 654, height: 32)

    func notched() -> FullPanelDisplayGeometry {
        FullPanelDisplayGeometry(screenFrame: display, topInset: inset,
                                 auxiliaryLeftArea: left, auxiliaryRightArea: right)
    }

    func testNotchedDisplay() {
        let g = notched()
        XCTAssertTrue(g.hasCameraHousing)
        XCTAssertTrue(g.hasAuxiliaryAreas)
        XCTAssertEqual(g.cameraHousingRect, NSRect(x: 654, y: 950, width: 204, height: 32))
        XCTAssertEqual(g.topBandRect, NSRect(x: 0, y: 950, width: 1512, height: 32))
        XCTAssertEqual(g.belowHousingRect, NSRect(x: 0, y: 0, width: 1512, height: 950))
    }

    func testExternalDisplayHasNoHousing() {
        let g = FullPanelDisplayGeometry(screenFrame: NSRect(x: 1512, y: 0, width: 2560, height: 1440),
                                         topInset: 0, auxiliaryLeftArea: .zero,
                                         auxiliaryRightArea: .zero)
        XCTAssertFalse(g.hasCameraHousing)
        XCTAssertFalse(g.hasAuxiliaryAreas)
        XCTAssertEqual(g.cameraHousingRect, .zero)
        XCTAssertEqual(g.topBandRect, .zero)
        XCTAssertEqual(g.belowHousingRect, g.screenFrame)
    }

    func testInsetWithoutAuxiliaryAreasHasNoHousingRect() {
        let g = FullPanelDisplayGeometry(screenFrame: display, topInset: inset,
                                         auxiliaryLeftArea: .zero, auxiliaryRightArea: .zero)
        XCTAssertTrue(g.hasCameraHousing)
        XCTAssertEqual(g.cameraHousingRect, .zero)
    }

    func testFullscreenLayoutIsTopLeftOrigin() {
        let layout = FullPanelLayout(geometry: notched(), windowFrame: display,
                                     state: .active, fallbackReason: .none)
        XCTAssertTrue(layout.isActive)
        XCTAssertEqual(layout.leftArea, CGRect(x: 0, y: 0, width: 654, height: 32))
        XCTAssertEqual(layout.rightArea, CGRect(x: 858, y: 0, width: 654, height: 32))
        XCTAssertEqual(layout.cameraHousing, CGRect(x: 654, y: 0, width: 204, height: 32))
        XCTAssertEqual(layout.contentSize, display.size)
    }

    func testWindowedLayoutExcludesAreasOutsideWindow() {
        let windowed = CGRect(x: 276, y: 181, width: 960, height: 620)
        let layout = FullPanelLayout(geometry: notched(), windowFrame: windowed,
                                     state: .inactive, fallbackReason: .none)
        XCTAssertFalse(layout.isActive)
        XCTAssertNil(layout.leftArea)
        XCTAssertNil(layout.rightArea)
        XCTAssertNil(layout.cameraHousing)
    }

    func testFallbackLayoutIsNotActive() {
        let below = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let layout = FullPanelLayout(geometry: notched(), windowFrame: below,
                                     state: .fallback, fallbackReason: .frameNotAccepted)
        XCTAssertFalse(layout.isActive)
        XCTAssertNil(layout.leftArea)
    }
}
