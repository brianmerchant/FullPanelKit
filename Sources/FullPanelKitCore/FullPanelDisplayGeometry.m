// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

#if !__has_feature(objc_arc)
#error FullPanelKitCore must be compiled with ARC (-fobjc-arc).
#endif

#import "FullPanelDisplayGeometry.h"

@implementation FullPanelDisplayGeometry

- (instancetype)initWithScreen:(NSScreen *)screen {
    return [self initWithScreenFrame:screen.frame topInset:screen.safeAreaInsets.top
                   auxiliaryLeftArea:screen.auxiliaryTopLeftArea
                  auxiliaryRightArea:screen.auxiliaryTopRightArea];
}

- (instancetype)initWithScreenFrame:(NSRect)screenFrame topInset:(CGFloat)topInset
                  auxiliaryLeftArea:(NSRect)left auxiliaryRightArea:(NSRect)right {
    if ((self = [super init])) {
        _screenFrame = screenFrame;
        _topInset = MAX(0, topInset);
        _auxiliaryLeftArea = NSIsEmptyRect(left) ? NSZeroRect : left;
        _auxiliaryRightArea = NSIsEmptyRect(right) ? NSZeroRect : right;
    }
    return self;
}

- (BOOL)hasCameraHousing { return _topInset > 0; }

- (BOOL)hasAuxiliaryAreas {
    return !NSIsEmptyRect(_auxiliaryLeftArea) && !NSIsEmptyRect(_auxiliaryRightArea);
}

- (NSRect)topBandRect {
    if (_topInset <= 0) return NSZeroRect;
    return NSMakeRect(NSMinX(_screenFrame), NSMaxY(_screenFrame) - _topInset,
                      NSWidth(_screenFrame), _topInset);
}

- (NSRect)belowHousingRect {
    NSRect r = _screenFrame;
    r.size.height = MAX(0, r.size.height - _topInset);
    return r;
}

- (NSRect)cameraHousingRect {
    if (!self.hasCameraHousing || !self.hasAuxiliaryAreas) return NSZeroRect;
    CGFloat minX = NSMaxX(_auxiliaryLeftArea);
    CGFloat maxX = NSMinX(_auxiliaryRightArea);
    if (maxX <= minX) return NSZeroRect;
    NSRect band = self.topBandRect;
    return NSMakeRect(minX, NSMinY(band), maxX - minX, NSHeight(band));
}

+ (NSArray<NSScreen *> *)screensWithCameraHousing {
    NSMutableArray *result = [NSMutableArray array];
    for (NSScreen *screen in [NSScreen screens]) {
        if (screen.safeAreaInsets.top > 0) [result addObject:screen];
    }
    return result;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[FullPanelDisplayGeometry class]]) return NO;
    FullPanelDisplayGeometry *o = object;
    return NSEqualRects(_screenFrame, o.screenFrame) && _topInset == o.topInset &&
           NSEqualRects(_auxiliaryLeftArea, o.auxiliaryLeftArea) &&
           NSEqualRects(_auxiliaryRightArea, o.auxiliaryRightArea);
}

- (NSUInteger)hash {
    return (NSUInteger)(_screenFrame.size.width * 31 + _screenFrame.size.height * 17 + _topInset);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<FullPanelDisplayGeometry screen=%@ inset=%.1f left=%@ right=%@ housing=%@>",
            NSStringFromRect(_screenFrame), _topInset, NSStringFromRect(_auxiliaryLeftArea),
            NSStringFromRect(_auxiliaryRightArea), NSStringFromRect(self.cameraHousingRect)];
}

@end
