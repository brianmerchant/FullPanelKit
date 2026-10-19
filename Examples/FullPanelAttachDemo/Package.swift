// swift-tools-version:5.9
// FullPanelAttachDemo — FullPanelSession on SwiftUI WindowGroup windows.
// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../LICENSE).

import PackageDescription

let package = Package(
    name: "FullPanelAttachDemo",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "FullPanelKit", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "FullPanelAttachDemo",
            dependencies: [.product(name: "FullPanelKit", package: "FullPanelKit")],
            path: "Sources/FullPanelAttachDemo"
        )
    ]
)
