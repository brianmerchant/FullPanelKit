# Integration evidence

What has actually been verified for each integration shipped in this
repository, and on which revision. Status labels:

> **References.** Commit hashes in this document identify revisions in
> FullPanelKit's private development history, which is not published
> ([PROVENANCE.md](PROVENANCE.md#public-history)). "Release candidate" means
> the earlier, unpublished 0.1.0 candidate, which used the previous
> fullscreen-frame geometry mechanism.

- **Hardware verified:** exercised on a physical notched MacBook, with
  real screen captures of the area beside the housing.
- **Runtime tested:** an automated suite ran against real AppKit windows and
  real fullscreen transitions, but checked the window and app state rather
  than the physical screen.
- **Build verified:** compiles and links only.
- **Experimental:** works in the recorded tests, but the API or behaviour may
  still change.
- **Not yet verified on the release candidate:** an earlier revision was
  tested; this one was not.

**Common to every row:**
- **Hardware:** MacBook Pro 14-inch 2021 (MacBookPro18,3, M1 Pro), built-in
  display 1800 × 1169 pt with a 38 pt camera housing, macOS 27.0.1 (26A434).
- **Toolchain:** Xcode 27.1, Swift 6.4, Rust 1.99.0.
- **Not covered:** other Macs, other macOS releases and external displays.
  See [COMPATIBILITY.md](COMPATIBILITY.md).
- **Evidence:** links go to [evidence/0.1.0-rc](evidence/0.1.0-rc/README.md).

"RC" means release-candidate commit `30fa67b`. "601d06a" means the final
acceptance run on SDK code that is functionally identical to the RC.

## Summary

| Integration | Kind | Source | Status |
| --- | --- | --- | --- |
| `FullPanelWindow` | AppKit subclass | [Examples/FullPanelDemo](../Examples/FullPanelDemo) | **Hardware verified** (this release: 100 Mission Control returns, Dock/Command-Tab; RC and 601d06a: demo and suite) |
| `FullPanelSession`, SwiftUI `WindowGroup` | Existing-window attachment | [Examples/FullPanelAttachDemo](../Examples/FullPanelAttachDemo) | **Hardware verified** (this release: autotest 82/82, lifecycle 28/28; 601d06a: scenarios) |
| `FullPanelSession`, your `NSWindow` subclass | Existing-window attachment | `FullPanelAttachDemo` (AppKit mode), [Tools/SpacesHarness](../Tools/SpacesHarness) | **Hardware verified** (this release: autotest 49/49; 601d06a) |
| Electron 44.7.0 | Node-API addon | [Integrations/Electron](../Integrations/Electron) | **Experimental.** Runtime tested on this release (63/63) and on RC; band hardware-captured on RC; Mission Control and clicks not verified with the bridge |
| Tauri 2.12.3 | Rust crate + C-ABI bridge | [Integrations/Tauri](../Integrations/Tauri) | **Experimental.** Same as Electron (101/101 on this release) |
| winit 0.30.13 | Rust crate + C-ABI bridge | [Integrations/Winit](../Integrations/Winit) | **Experimental.** Same as Electron (140/140 on this release) |

The bridges use the unchanged `FullPanelKitCore` sources and
`FullPanelSession`. They are compiled from this repository by relative path,
so a checkout of the release tag builds against exactly that release.

## FullPanelWindow — `Examples/FullPanelDemo`

| Field | Record |
| --- | --- |
| Source | `Examples/FullPanelDemo` (AppKit view and SwiftUI root view in one app); `Tools/SpacesHarness` (SpacesLab `-mode fpwindow`) |
| SDK revision | RC `30fa67b` (demo); SDK code of `601d06a` (SpacesHarness) |
| Build | RC: `build-demo.sh` without warnings |
| Runtime | RC: native fullscreen entry and exit in both variants; clicks on the controls beside the housing; top-edge menu-bar reveal and hide |
| Hardware | RC: band filled by the window in both variants ([AppKit](evidence/0.1.0-rc/demos/fullpaneldemo-appkit-band.png), [SwiftUI](evidence/0.1.0-rc/demos/fullpaneldemo-swiftui-band.png)). Synthetic clicks moved the counters to 2 and 1 ([AppKit](evidence/0.1.0-rc/demos/interact-appkit-2-clicked.png), [SwiftUI](evidence/0.1.0-rc/demos/interact-swiftui-2-clicked.png)). At the top edge the band turned into the app's menu bar; moving away restored it ([probe](evidence/0.1.0-rc/demos/fullpaneldemo-interaction-probe.txt), [after](evidence/0.1.0-rc/demos/interact-appkit-4-hidden.png)) |
| Mission Control | **Verified** (601d06a): entry plus 18 returns (6 paths × 3 rounds), band rendered at the 0.4 s sample on all 18 returns ([summary](evidence/0.1.0-rc/core/missioncontrol.summary.txt), [3.0 s sample](evidence/0.1.0-rc/core/mc-fpwindow-thumb-1-3.0s.png)) |
| Other | Dock and Command-Tab behave the same as native fullscreen ([activation](evidence/0.1.0-rc/core/activation.summary.txt)). Display-mode change: other scale keeps FullPanel; a mode without the housing band falls back and resumes ([displaymode](evidence/0.1.0-rc/core/displaymode.summary.txt)) |
| Limitations | Clicks and pointer moves were synthetic `CGEvent`s, not a trackpad. Window restoration at launch is not applicable to this demo |

## FullPanelSession — `Examples/FullPanelAttachDemo`

| Field | Record |
| --- | --- |
| Source | `Examples/FullPanelAttachDemo` (SwiftUI `WindowGroup`; `-FullPanelAttachAppKitSubclassOnly YES` for an AppKit `NSWindow` subclass); scenario runner `run-scenarios.sh` |
| SDK revision | SDK code of `601d06a`; the demo builds on RC `30fa67b` without warnings |
| Build | RC: `build-demo.sh` without warnings |
| Runtime | Autotest 82/82 ([checks](evidence/0.1.0-rc/core/autotest.checks.txt)); AppKit-subclass autotest 48/48 ([checks](evidence/0.1.0-rc/core/appkit-subclass.checks.txt)); lifecycle 28/28 under Zombies, MallocScribble and MallocGuardEdges ([checks](evidence/0.1.0-rc/core/lifecycle.checks.txt)) |
| Hardware | Scenarios 77/77 with band captures: A fresh entry, B attach inside fullscreen (documented fallback), R1–R5 windows restored into fullscreen at launch ([summary](evidence/0.1.0-rc/core/scenarios.summary.txt), [entry](evidence/0.1.0-rc/core/scenario-A-entered.png), [after Mission Control](evidence/0.1.0-rc/core/scenario-A-after-mission-control-1.png)) |
| Mission Control | **Verified** (601d06a): 5 originating-Space returns each in A, R1 and R5, with the recovery path on every return; SpacesHarness session mode: entry plus 18 returns, band at the 0.4 s sample on all 18 ([summary](evidence/0.1.0-rc/core/missioncontrol.summary.txt)) |
| Restoration | **Verified** (601d06a): R1–R5, including two windows restored into two Spaces and a restore while another app is frontmost |
| Limitations | Not re-run on the RC (unchanged SDK code). Physical external display, display sleep/wake and macOS 15 are not covered |

## Electron — `Integrations/Electron`

| Field | Record |
| --- | --- |
| Source | `Integrations/Electron`: `src/fullpanel_electron.mm`, `index.js`, test app in `test-app/` |
| Versions | Electron 44.7.0 (Chromium 152, Node 24.21.0, Node-API 10), exact pin in `package.json` |
| SDK revision | RC `30fa67b` |
| Build | RC: `npm ci`, `npm run build`, no warnings |
| Runtime | RC: `npm run autotest` 63/63 plus 2 informational ([checks](evidence/0.1.0-rc/bridges/electron-autotest.checks.txt)). Covers the bridge, enable/disable, move and resize cycles, fullscreen through `setFullScreen` with native frame and WindowServer bounds covering the display, disable/detach/attach inside fullscreen, close and quit cleanup. Its pixel check (T4) uses Chromium's `capturePage`, which is the app's render, not the screen |
| Hardware | RC: window A's band is filled with the app's magenta and cyan; control window B's band is black ([A](evidence/0.1.0-rc/bridges/electron-A-band.png), [B](evidence/0.1.0-rc/bridges/electron-B-band.png), [probe](evidence/0.1.0-rc/bridges/electron-band-probe.txt)) |
| Mission Control | **Not yet verified on the release candidate.** A manual run on 2026-10-12, on an earlier SDK revision, recorded three Mission Control returns and clicks on both sides afterwards (see the Electron README's verification record). That report file was not retained |
| Limitations | Experimental. Main process only. `titleBarStyle: 'hidden'` windows need the documented 32 pt correction (handled by the addon). Physical clicks and menu-bar reveal not re-verified on RC |

## Tauri — `Integrations/Tauri`

| Field | Record |
| --- | --- |
| Source | `Integrations/Tauri`: crate `fullpanelkit-tauri` (`src/lib.rs`, `src/fullpanel_tauri.m`), test app `test-app/` |
| Versions | Tauri 2.12.3, Tao 0.37.1, Wry 0.57.0 (`Cargo.lock`) |
| SDK revision | RC `30fa67b` |
| Build | RC: `cargo build --locked`, no warnings |
| Runtime | RC: `--autotest` 101/101 ([checks](evidence/0.1.0-rc/bridges/tauri-autotest.checks.txt)); the suite itself lists physical clicks and visible pixels as not run |
| Hardware | RC: window A's band is filled with the app's orange and teal; control window B's band is black ([A](evidence/0.1.0-rc/bridges/tauri-A-band.png), [B](evidence/0.1.0-rc/bridges/tauri-B-band.png), [probe](evidence/0.1.0-rc/bridges/tauri-band-probe.txt)) |
| Mission Control | **Not yet verified on the release candidate.** Reported as verified on hardware on 2026-10-12 (earlier SDK revision) in the commit that added the bridge; no report was retained |
| Limitations | Experimental. Physical clicks and menu-bar reveal not re-verified on RC |

## winit — `Integrations/Winit`

| Field | Record |
| --- | --- |
| Source | `Integrations/Winit`: crate `fullpanelkit-winit` (`src/lib.rs`, `src/fullpanel_winit.m`), softbuffer test app `test-app/` |
| Versions | winit 0.30.13, raw-window-handle 0.6.2, softbuffer 0.4.8 (`Cargo.lock`) |
| SDK revision | RC `30fa67b` |
| Build | RC: `cargo build --locked`, no warnings |
| Runtime | RC: `--autotest` 140/140 ([checks](evidence/0.1.0-rc/bridges/winit-autotest.checks.txt)); its pixel checks read the app's own buffer, not the display |
| Hardware | RC: window A's band is filled with the app's orange and teal; control window B's band is black ([A](evidence/0.1.0-rc/bridges/winit-A-band.png), [B](evidence/0.1.0-rc/bridges/winit-B-band.png), [probe](evidence/0.1.0-rc/bridges/winit-band-probe.txt)) |
| Mission Control | **Not yet verified on the release candidate.** Reported as verified on hardware on 2026-10-12 (earlier SDK revision) in the commit that added the bridge; no report was retained |
| Limitations | Experimental. With winit's default titlebar the window shifts by 32 pt on enable/disable; use a full-size content view with a transparent titlebar (see the README). Physical clicks and menu-bar reveal not re-verified on RC |

## Reproducing

| Integration | Commands (from the repository root) |
| --- | --- |
| FullPanelWindow | `Examples/FullPanelDemo/build-demo.sh`, then `open Examples/FullPanelDemo/build/FullPanelDemo.app` (add `--args -FullPanelDemoSwiftUI YES` for SwiftUI) and press Control-Command-F |
| FullPanelSession | `Examples/FullPanelAttachDemo/build-demo.sh`; automated runs in [TESTING.md](TESTING.md) |
| Electron | `cd Integrations/Electron && npm ci && npx --no install-electron && npm run build && npm run autotest`; interactive: `npm start` |
| Tauri | `cd Integrations/Tauri && cargo run --locked -p fullpanel-tauri-test -- --autotest`; interactive: drop `-- --autotest` |
| winit | `cd Integrations/Winit && cargo run --locked -p fullpanel-winit-test -- --autotest`; interactive: drop `-- --autotest` |

Automated suites enter fullscreen on the built-in display; leave the Mac idle
while they run. Manual checks: [MANUAL_ACCEPTANCE.md](MANUAL_ACCEPTANCE.md).

No integration here is affiliated with or endorsed by the Electron, Tauri or
winit projects.
