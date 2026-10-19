// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Camera-housing geometry of one display, in AppKit global screen
/// coordinates (points, bottom-left origin) — the same space as NSScreen.frame.
///
/// All rectangles come from public NSScreen API (safeAreaInsets and
/// auxiliaryTopLeftArea / auxiliaryTopRightArea). Nothing here is private.
NS_SWIFT_NAME(FullPanelDisplayGeometry)
@interface FullPanelDisplayGeometry : NSObject

/// Geometry for a live screen.
- (instancetype)initWithScreen:(NSScreen *)screen;

/// Geometry from raw values (tests, previews). Pass NSZeroRect for an
/// auxiliary area the screen does not report.
- (instancetype)initWithScreenFrame:(NSRect)screenFrame
                         topInset:(CGFloat)topInset
                auxiliaryLeftArea:(NSRect)auxiliaryLeftArea
               auxiliaryRightArea:(NSRect)auxiliaryRightArea NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// The whole display (NSScreen.frame).
@property (nonatomic, readonly) NSRect screenFrame;
/// Height of the camera-housing band (NSScreen.safeAreaInsets.top); 0 if none.
@property (nonatomic, readonly) CGFloat topInset;
/// Usable display area left of the camera housing; NSZeroRect if none.
@property (nonatomic, readonly) NSRect auxiliaryLeftArea;
/// Usable display area right of the camera housing; NSZeroRect if none.
@property (nonatomic, readonly) NSRect auxiliaryRightArea;
/// The physical camera-housing exclusion zone: the part of the top band
/// between the two auxiliary areas. NSZeroRect if it cannot be derived.
/// Never draw content you need the user to see or click here.
@property (nonatomic, readonly) NSRect cameraHousingRect;
/// The full top band (both auxiliary areas plus the housing).
@property (nonatomic, readonly) NSRect topBandRect;
/// The display below the top band (where AppKit would normally put a
/// fullscreen window on a notched display).
@property (nonatomic, readonly) NSRect belowHousingRect;
/// YES when the display has a camera housing (topInset > 0). This is the
/// same rule the engine uses to decide whether to attempt FullPanel.
@property (nonatomic, readonly) BOOL hasCameraHousing;
/// YES when the display also reports both auxiliary areas.
@property (nonatomic, readonly) BOOL hasAuxiliaryAreas;

/// Screens that have a camera housing (normally just the built-in display).
+ (NSArray<NSScreen *> *)screensWithCameraHousing;

@end

NS_ASSUME_NONNULL_END
