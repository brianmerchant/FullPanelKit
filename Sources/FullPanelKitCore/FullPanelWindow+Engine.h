// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
// Internal: FullPanelWindow's engine, shared with the private AppKit hook in
// FPKAppKitHooks.m through FPKEngineForWindow. Not public API.

#import "FullPanelWindow.h"
#import "FPKEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface FullPanelWindow () <FPKEngineHost> {
@public
    FPKEngine *_fpkEngine;
}
@end

NS_ASSUME_NONNULL_END
