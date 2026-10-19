// swift-tools-version:5.9
// FullPanelKit — native macOS fullscreen content beside the MacBook camera housing.
// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

import PackageDescription

let package = Package(
    name: "FullPanelKit",
    platforms: [
        // Deployment floor for compilation only. Hardware-verified on macOS 27
        // (MacBook Pro 14-inch, 2021, M1 Pro) — see docs/COMPATIBILITY.md.
        .macOS(.v13)
    ],
    products: [
        .library(name: "FullPanelKit", targets: ["FullPanelKit"])
    ],
    targets: [
        // Objective-C engine. Owns every private AppKit / SkyLight interaction.
        .target(
            name: "FullPanelKitCore",
            path: "Sources/FullPanelKitCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        // Swift surface: re-exports the core and adds SwiftUI integration.
        .target(
            name: "FullPanelKit",
            dependencies: ["FullPanelKitCore"],
            path: "Sources/FullPanelKit"
        ),
        .testTarget(
            name: "FullPanelKitTests",
            dependencies: ["FullPanelKit"],
            path: "Tests/FullPanelKitTests"
        )
    ]
)
