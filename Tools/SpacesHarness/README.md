# SpacesHarness

Hardware checks for fullscreen windows across Spaces and displays, with
FullPanel and native fullscreen side by side: Mission Control and Space-switch
returns, Dock and Command-Tab activation, display-mode changes, and moving a
fullscreen Space between displays in Mission Control. Results:
[docs/TESTING.md](../../docs/TESTING.md). Background
and results: [docs/WINDOW_LIFECYCLE.md](../../docs/WINDOW_LIFECYCLE.md).

```sh
./build.sh                                  # build/SpacesLab.app, SpacesOther.app, spacesctl
./activation.sh                             # this Mac's Space-switching setting
./activation.sh YES                         # setting on, SpacesLab's own defaults only
./migration.sh session desktop              # FullPanelSession, leave Mission Control via the Desktop left behind
./migration.sh control moved                # native fullscreen control, via the moved Space
./missioncontrol.sh 3                       # 6 return paths x 3 cycles, all three modes
./displaymode.sh 54 60                      # built-in display: other scale with / without housing
./abc.sh <label> build/SpacesLab.app <outdir> session   # 10 bounded transitions with dialog and input guards
./mcreturns.sh <label> build/SpacesLab.app <outdir> fpwindow [-Option YES]   # exactly 10 Mission Control returns, same guards
./mccampaign.sh <outdir> build/SpacesLab.app fpwindow 10   # 10 x mcreturns.sh, thumbnail routes, stops at the first FAIL without recovery input
./lifecycle-ab.sh <label> p2|multi|reveal|fallback build/SpacesLab.app <outdir>   # lifecycle checks (lccheck.py)
./demo-run.sh <label> <outdir> fresh        # one FullPanelAttachDemo (SwiftUI) scenario under the same guards
```

`abc.sh`, `mcreturns.sh`, `displaymode-ab.sh`, `lifecycle-ab.sh` and `demo-run.sh` stop at once,
without touching it, when a permission prompt or other system dialog is on
screen, and on input that did not come from the harness. Their output folder
must not be one macOS protects (Downloads, Documents, Desktop, iCloud Drive;
`outdir.sh`).

`missioncontrol.sh` returns to the fullscreen window through Escape, the large
preview, the small Space thumbnail, the large preview then the thumbnail, the
thumbnail from another Space, and Control-arrow Space switches, and samples
`spacesctl band` (SpacesLab's teal beside the housing) 0.4, 1.2 and 3 s
later. `displaymode.sh` switches the built-in display to another scaled mode
with the housing band and to one without it (indices from `spacesctl modes`)
using `kCGConfigureForAppOnly`, so the previous mode returns when the holding
process exits.

`activation.sh` runs native fullscreen (`control`), `FullPanelSession`
(`session`) and `FullPanelWindow` (`fpwindow`) through the same Dock and
Command-Tab steps and prints whether each FullPanel mode behaved like native
fullscreen. `migration.sh <mode> <escape|moved|desktop>` records, for each
step, which display shows the window's Space, how much of each display is
non-black, and the FullPanel state.

## Requirements and side effects

- Accessibility (key, mouse and Dock events) and Screen Recording (captures)
  for the terminal that runs the scripts.
- A display with a camera housing. `migration.sh` also needs one without (an
  external monitor or Sidecar), with "Displays have separate Spaces" on, and
  one Desktop per display.
- The scripts move between Spaces, open Mission Control and enter fullscreen.
  Do not use the Mac while they run.
- `migration.sh` with `escape` or `moved` makes a display black (macOS
  behavior; native fullscreen too). The script detects it and recovers the
  display by entering and leaving fullscreen with a window there.
- No setting is changed. `AppleSpacesSwitchOnActivate` overrides are passed
  as launch arguments to SpacesLab only. Display modes are changed only for
  the lifetime of `spacesctl modehold`.

## Calibration

`spacesctl bar` places Mission Control's Spaces-bar thumbnails from the
display geometry: about 172 pt apart, centered, 97 pt below the top of the
display plus 23 pt on a display with a housing (macOS 27, 14-inch MacBook Pro
and a 1539 × 1070 pt Sidecar display). The drag is retried and checked against
WindowServer (`spacesctl space`). On other hardware, check the coordinates
first: open Mission Control with the pointer at the top edge and compare a
screenshot.

## Tools

`spacesctl` (see its source for the full list): `cmd`, `cmdtab [n]`, `key`,
`dock`, `front`, `space <pid>` (display, whether shown, place in the Spaces
bar), `shot`, `band`, `onscreen builtin|external`, `bar`, `drag`, `move`,
`click`, `modes`, `modehold <index> <seconds>`.

`SpacesLab -mode control|session|fpwindow|plain -tag <t> -log <path>
[-screen builtin|external] [-autoFS YES]` writes one line per window and
application event: screen, frame, style, collection behavior, key/main/
visible/occlusion, Space, presentation options and FullPanel diagnostics.
