// swift-tools-version:5.9
// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE at the repository root).
// Consumer of a clean FullPanelKit clone (see ../check.sh, which fills in the path).
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "__FULLPANELKIT__")],
    targets: [
        .executableTarget(name: "Consumer",
                          dependencies: [.product(name: "FullPanelKit", package: "FullPanelKit")])
    ]
)
