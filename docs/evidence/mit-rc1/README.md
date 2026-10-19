# Evidence for the MIT release candidate (2026-10-19)

Extracts from the runs behind [TESTING.md](../../TESTING.md), "MIT release
candidate". Hardware: MacBook Pro 14-inch 2021 (MacBookPro18,3, M1 Pro),
built-in display 1800 × 1169 pt at 120 Hz with a 38 pt camera housing,
macOS 27.0.1 (26A434), single display. Full logs, traces and screen captures
stay with the maintainer.

The SDK code tested is this release's: the hardware runs used builds from an
exact export of the release tree, except the Mission Control campaign, whose
harness binary was built from the development tree immediately before.
Between the two, `Sources/` differs only in comments (comment-stripped token
streams identical), so the compiled SDK is the same.

| File | What it is |
| --- | --- |
| `mc-campaign.txt`, `mc-campaign.results.tsv` | 100 Mission Control thumbnail returns, `Tools/SpacesHarness/mccampaign.sh`, `FullPanelWindow` with default settings, 10 batches of 10 (`thumb` and `away-thumb` alternating). Per return: verdict, latency from the click to the Space being shown, the band beside the housing (fraction of the window's colour, left/right), presentation options, FullPanel state, key window, application active, Space ID |
| `autotest-swiftui.checks.txt` | `FullPanelAttachDemo -FullPanelAttachAutotest YES -FullPanelAttachMissionControl NO`: 82/82 (81 printed checks plus one informational KVO baseline recorded in the JSON report) |
| `autotest-appkit.checks.txt` | Same with `-FullPanelAttachAppKitSubclassOnly YES`: 49/49 |
| `lifecycle.checks.txt`, `lifecycle-zombie.checks.txt` | `-FullPanelAttachScenario lifecycle`, plain and under `NSZombieEnabled=YES MallocScribble=1`: 28/28 each, no zombie messages |
| `winit-autotest.checks.txt`, `tauri-autotest.checks.txt`, `electron-autotest.checks.txt` | Bridge autotests: winit 140/140, Tauri 101/101, Electron 63/63 (+2/2 informational). They never simulate Mission Control or clicks |

Mission Control campaign stop rules: Mission Control verified open
immediately before every click; the Space thumbnail located by its pixels;
the first failure, system dialog, outside input or display change stops the
campaign with no recovery input. An earlier attempt stopped after 2 returns
because the harness predicted the thumbnail's position wrongly with four
Spaces present (a harness fault; the click missed the thumbnail); it is not
part of the 100 and the harness was corrected before this run.
