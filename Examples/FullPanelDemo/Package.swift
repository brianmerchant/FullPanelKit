// swift-tools-version:5.9
// FullPanelDemo — reference application for FullPanelKit.
// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../LICENSE).

import PackageDescription

let package = Package(
    name: "FullPanelDemo",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "FullPanelKit", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "FullPanelDemo",
            dependencies: [.product(name: "FullPanelKit", package: "FullPanelKit")],
            path: "Sources/FullPanelDemo"
        )
    ]
)
