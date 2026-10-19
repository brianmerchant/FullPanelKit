// swift-tools-version:5.9
// SpacesHarness — hardware checks for display migration and Dock / Command-Tab
// activation of fullscreen windows, FullPanel and native side by side.
// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../LICENSE).

import PackageDescription

let package = Package(
    name: "SpacesHarness",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "FullPanelKit", path: "../..")
    ],
    targets: [
        // A one-window AppKit app: native fullscreen control, FullPanelSession
        // or FullPanelWindow, with a structured event log and remote commands.
        .executableTarget(
            name: "SpacesLab",
            dependencies: [.product(name: "FullPanelKit", package: "FullPanelKit")],
            path: "Sources/SpacesLab"
        ),
        // Drives the real system UI (Command-Tab, Dock, Mission Control) and
        // reads WindowServer state from outside the app.
        .executableTarget(name: "spacesctl", path: "Sources/spacesctl")
    ]
)
