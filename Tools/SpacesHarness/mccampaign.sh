#!/bin/bash
# Mission Control return campaign: <batches> runs of mcreturns.sh (10 returns
# each) on one SpacesLab build, one mode and option set, thumbnail routes only
# (thumb and away-thumb alternating), in campaign mode (MC_STOP_ON_FAIL=1: the
# first FAIL, dialog, outside input or harness fault stops the campaign with
# no recovery input). Records the build, the SDK source tree and the system
# before the first batch.
#
#   ./mccampaign.sh <outdir> <SpacesLab.app> <mode> <batches> [-Option YES ...]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$1"; APP="$2"; MODE="$3"; BATCHES="$4"; shift 4
source "$ROOT/outdir.sh"; harness_outdir campaign "$OUT" >/dev/null || exit 1
mkdir -p "$OUT"
export MC_STOP_ON_FAIL=1
export MC_ROUTES="thumb away-thumb thumb away-thumb thumb away-thumb thumb away-thumb thumb away-thumb"
REPO="$(git -C "$ROOT" rev-parse --show-toplevel)"
{
    echo "started $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "commit $(git -C "$REPO" rev-parse HEAD)$(git -C "$REPO" diff --quiet HEAD -- Sources Tools/SpacesHarness || echo ' (uncommitted changes)')"
    echo "sdk-tree $(git -C "$REPO" rev-parse HEAD:Sources)"
    echo "binary $(shasum -a 256 "$APP/Contents/MacOS/SpacesLab" | cut -d' ' -f1)"
    echo "spacesctl $(shasum -a 256 "$ROOT/build/spacesctl" | cut -d' ' -f1)"
    echo "mcreturns.sh $(shasum -a 256 "$ROOT/mcreturns.sh" | cut -d' ' -f1)"
    echo "macos $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(sysctl -n hw.model)"
    echo "screen $("$ROOT/build/spacesctl" modeinfo)"
    echo "mode $MODE options [$*] routes [$MC_ROUTES] batches $BATCHES"
    echo "AppleMenuBarVisibleInFullscreen=$(defaults read -g AppleMenuBarVisibleInFullscreen 2>&1 | tr '\n' ' ')"
    echo "AppleSpacesSwitchOnActivate=$(defaults read -g AppleSpacesSwitchOnActivate 2>&1 | tr '\n' ' ')"
    echo "spans-displays=$(defaults read com.apple.spaces spans-displays 2>&1 | tr '\n' ' ')"
} > "$OUT/CAMPAIGN.txt"
cat "$OUT/CAMPAIGN.txt"
for b in $(seq -f "%02g" 1 "$BATCHES"); do
    "$ROOT/mcreturns.sh" "b$b" "$APP" "$OUT" "$MODE" "$@"
    rc=$?
    if [ $rc -ne 0 ] || ! grep -q "10 PASS, 0 FAIL" "$OUT/b$b.results.tsv"; then
        echo "campaign stopped after batch b$b (exit $rc)" | tee -a "$OUT/CAMPAIGN.txt"; exit 2
    fi
    sleep 3
done
echo "finished $(date '+%Y-%m-%d %H:%M:%S %Z')" | tee -a "$OUT/CAMPAIGN.txt"
grep -h "returns judged" "$OUT"/b*.results.tsv | tee -a "$OUT/CAMPAIGN.txt"
