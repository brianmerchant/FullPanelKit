#!/bin/bash
# Builds SpacesLab.app and SpacesOther.app (the same binary under a second
# bundle identifier, used as "another application") and spacesctl into
# Tools/SpacesHarness/build. Ad-hoc signed; installs and launches nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
swift build -c debug
BIN="$(swift build -c debug --show-bin-path)"
mkdir -p build
bundle() {   # bundle <name> <bundle id>
    local app="build/$1.app"
    rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
    cp "$BIN/SpacesLab" "$app/Contents/MacOS/$1"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
    codesign --force --sign - "$app" >/dev/null
}
bundle SpacesLab dev.brianmerchant.FullPanelKit.SpacesLab
bundle SpacesOther dev.brianmerchant.FullPanelKit.SpacesOther
cp "$BIN/spacesctl" build/spacesctl
echo "Built $ROOT/build/{SpacesLab.app,SpacesOther.app,spacesctl}"
