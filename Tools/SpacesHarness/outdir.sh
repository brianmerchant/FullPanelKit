# Sourced by the SpacesHarness scripts: harness_outdir <name> [given dir]
# prints the output directory. Default: <name>-<timestamp> in $FPK_HARNESS_RUNS,
# or in Tools/SpacesHarness/runs (git-ignored).
# Refuses folders macOS protects (Downloads, Documents, Desktop, iCloud Drive,
# removable volumes): SpacesLab writes its -log there, and macOS then asks it
# for access with a dialog that interrupts the run.
harness_outdir() {
    local runs="${FPK_HARNESS_RUNS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runs}"
    local dir="${2:-$runs/$1-$(date +%Y%m%d-%H%M%S)}"
    case "$dir" in
        "$HOME"/Downloads*|"$HOME"/Documents*|"$HOME"/Desktop*|"$HOME"/Library/Mobile\ Documents*|/Volumes/*)
            echo "harness: refusing output folder $dir (protected by macOS; SpacesLab would trigger an access prompt; set FPK_HARNESS_RUNS)" >&2
            return 1 ;;
    esac
    echo "$dir"
}
