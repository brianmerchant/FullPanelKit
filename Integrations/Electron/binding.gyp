# FullPanelKit for Electron: a Node-API addon that compiles FullPanelKitCore
# (Objective-C, unchanged) straight from Sources/FullPanelKitCore.
# Build against Electron's headers with `npm run build`.
{
  "variables": {
    "fpk_core": "../../Sources/FullPanelKitCore"
  },
  "targets": [
    {
      "target_name": "fullpanel_electron",
      "sources": [
        "src/fullpanel_electron.mm",
        "<(fpk_core)/FPKAppKitHooks.m",
        "<(fpk_core)/FPKDecisions.c",
        "<(fpk_core)/FPKEngine.m",
        "<(fpk_core)/FPKFullScreenTitlebar.m",
        "<(fpk_core)/FPKMenuBarOverlay.m",
        "<(fpk_core)/FPKSupport.m",
        "<(fpk_core)/FullPanelDisplayGeometry.m",
        "<(fpk_core)/FullPanelSession.m",
        "<(fpk_core)/FullPanelWindow.m"
      ],
      "include_dirs": [
        "<(fpk_core)/include"
      ],
      "defines": [
        "NAPI_VERSION=8"
      ],
      "xcode_settings": {
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
        "MACOSX_DEPLOYMENT_TARGET": "13.0",
        "OTHER_LDFLAGS": [
          "-framework AppKit",
          "-framework CoreGraphics"
        ]
      }
    }
  ]
}
