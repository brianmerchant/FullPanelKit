// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE at the repository root).
// Compiles FullPanelKitCore, unchanged, straight from Sources/FullPanelKitCore,
// plus the C-ABI bridge in src/fullpanel_winit.m (ARC, macOS 13, same flags as
// the Electron and Tauri integrations).

use std::path::PathBuf;

const CORE_SOURCES: &[&str] = &[
    "FPKAppKitHooks.m",
    "FPKDecisions.c",
    "FPKEngine.m",
    "FPKFullScreenTitlebar.m",
    "FPKMenuBarOverlay.m",
    "FPKSupport.m",
    "FullPanelDisplayGeometry.m",
    "FullPanelSession.m",
    "FullPanelWindow.m",
];

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let core = manifest.join("../../../Sources/FullPanelKitCore");
    let bridge = manifest.join("src/fullpanel_winit.m");

    let mut build = cc::Build::new();
    build
        .include(core.join("include"))
        .flag("-fobjc-arc")
        .flag("-mmacosx-version-min=13.0")
        .warnings(false);
    for source in CORE_SOURCES {
        let path = core.join(source);
        println!("cargo:rerun-if-changed={}", path.display());
        build.file(path);
    }
    build.file(&bridge);
    println!("cargo:rerun-if-changed={}", bridge.display());
    println!("cargo:rerun-if-changed={}", core.join("include").display());
    build.compile("fullpanelkit_core");

    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=CoreGraphics");
    println!("cargo:rustc-link-lib=framework=QuartzCore");
}
