#!/bin/bash
# Builds FullPanelAttachDemo.app locally. Does NOT launch or install it.
#
#   ./build-demo.sh            debug build
#   ./build-demo.sh release    release build
#
# Output: Examples/FullPanelAttachDemo/build/FullPanelAttachDemo.app
# Built on this Mac (never downloaded), so it carries no quarantine attribute
# and Gatekeeper does not block it. Ad-hoc signature only; no credentials,
# no privileged commands, no security-setting changes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/FullPanelAttachDemo.app"

cd "$ROOT"
swift build -c "$CONFIG" --product FullPanelAttachDemo
BIN="$(swift build -c "$CONFIG" --product FullPanelAttachDemo --show-bin-path)/FullPanelAttachDemo"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/FullPanelAttachDemo"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo
echo "Built: $APP"
echo "Launch with:  open \"$APP\""
echo "With trace:   open \"$APP\" --args -FullPanelTrace YES"
echo "Autotest:     \"$APP/Contents/MacOS/FullPanelAttachDemo\" -FullPanelAttachAutotest YES -FullPanelAttachReport /path/report.json"
