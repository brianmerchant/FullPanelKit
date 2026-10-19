#!/bin/bash
# Builds a separate consumer package against a clean clone of a committed
# FullPanelKit ref: nothing from this checkout's working tree, build caches or
# untracked files is used. The consumer (Consumer/) uses the public API the
# AppKit and SwiftUI quick starts and the examples rely on, compiles every
# Swift example in that commit's README, and checks that the test-only
# decision SPI is not part of `import FullPanelKit`.
#
#   ./check.sh [ref]        default: HEAD
#
# Writes only to a new temporary directory, which it removes at the end.
# Needs no network: the package has no dependencies.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REF="${1:-HEAD}"
SHA="$(git -C "$ROOT" rev-parse --verify "$REF^{commit}")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fpk-consumer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git clone -q --no-local "$ROOT" "$WORK/FullPanelKit"
git -C "$WORK/FullPanelKit" checkout -q "$SHA"
cp -R "$ROOT/Tools/ConsumerCheck/Consumer" "$WORK/Consumer"
sed -i '' "s#__FULLPANELKIT__#$WORK/FullPanelKit#" "$WORK/Consumer/Package.swift"
# The README's examples, from the same commit, must compile too.
python3 -I "$ROOT/Tools/ConsumerCheck/readme_snippets.py" "$WORK/FullPanelKit/README.md" \
    "$WORK/Consumer/Sources/Consumer/ReadmeExamples.swift"
echo "FullPanelKit $SHA (clean clone) -> consumer build"
swift build --package-path "$WORK/Consumer" 2>&1 | grep -E "error|warning: .*Consumer|Compiling|Build complete" | grep -v "^\[" || true
"$WORK/Consumer/.build/debug/Consumer"
# The decision SPI must not be reachable through the public import.
cat > "$WORK/Consumer/Sources/Consumer/SPILeak.swift" <<'SWIFT'
import FullPanelKit
let leaked = FPKReturnCheckBudget
SWIFT
if swift build --package-path "$WORK/Consumer" >/dev/null 2>&1; then
    echo "FAIL: FPKDecisions is visible through import FullPanelKit"; exit 1
fi
echo "PASS: decision SPI not visible through import FullPanelKit"
