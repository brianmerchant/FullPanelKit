# Restored and already-fullscreen windows

How FullPanel reaches a window whose fullscreen entry did not start with
`-toggleFullScreen:`, such as a window AppKit restores straight into a
fullscreen Space at launch, and why a window that is *already* in fullscreen
cannot be adopted in place.

> **References.** Commit hashes in this document identify revisions in
> FullPanelKit's private development history, which is not published
> ([PROVENANCE.md](PROVENANCE.md#public-history)). "Release candidate" means
> the earlier, unpublished 0.1.0 candidate, which used the previous
> fullscreen-frame geometry mechanism.

Hardware: MacBook Pro 14-inch (2021) M1 Pro, macOS 27.0.1 (26A434), built-in
display 1800 × 1169 pt, housing band 38 pt. Nothing here is verified on another
macOS version yet (see [Status](#status)).

> **Mechanism note.** The measurements and the adoption analysis below were
> made with FullPanelKit's earlier whole-display mechanism, an override of
> AppKit's private `_frameForFullScreenMode` plus frame guards. The current
> code instead answers AppKit's question to the window's fullscreen content
> controller, `-reservesSpaceForMenuBarInFullScreen`, with NO
> ([ARCHITECTURE.md](ARCHITECTURE.md)). What carries over:
>
> - Every entry, including restoration, is still prepared at
>   `willEnterFullScreen`.
> - The "first frame request" preparation became preparation at the entry's
>   reservation question, under the same rule (enabled while windowed,
>   nothing prepared since). Restoration with attachment inside
>   `willEnterFullScreen` (R3) was re-verified with it on macOS 27.0.1.
> - Enabling in a fullscreen session that is already under way is still
>   reported, not adopted. The constraint measured below (WindowServer
>   keeping the frame fixed after the first frame request) applied to the
>   frame override. AppKit does re-lay out an existing fullscreen window when
>   the reservation answer changes (detaching in fullscreen makes it
>   camera-safe at once), so in-place adoption may now be possible. That is
>   untested and not attempted; `Tools/AdoptionProbe` now answers the
>   reservation question and has not been run for it yet.

## Root cause (before this change)

- The engine prepared (armed) an entry in one place only:
  `-prepareForToggleFullScreen`, called from the `-toggleFullScreen:` override
  (FullPanelWindow) or hook (FullPanelSession).
- AppKit state restoration enters fullscreen through
  `-[NSWindow _enterFullScreenModeForRestoration…]` and never calls
  `-toggleFullScreen:`. The entry was never armed, the `_frameForFullScreenMode`
  override answered AppKit's camera-safe frame, and the session reported
  `.fallback` / `.frameNotAccepted`.
- Reproduced with `FullPanelAttachDemo` (relaunch with
  `-NSQuitAlwaysKeepsWindows YES`): restored in fullscreen, state 3, reason 5,
  armed 0, the band beside the housing black.

`toggleFullScreen:` is not the only way to start an entry. What matters is
**when** FullPanel arms, not which call arms it.

## The constraint: WindowServer fixes the frame at the first request

`Tools/AdoptionProbe/adoption_probe.m` logs every AppKit caller of
`_frameForFullScreenMode` and measures the AppKit frame, WindowServer bounds,
Space ID and the real pixels beside the housing (screencapture).

| Probe case | AppKit frame | WindowServer | Pixels beside housing |
| --- | --- | --- | --- |
| Armed before entry (control) | 1800 × 1169 | 1800 × 1169 | 100 % / 100 % |
| Armed in `willEnterFullScreen` (no toggle) | 1800 × 1169 | 1800 × 1169 | 100 % / 100 % |
| Armed 0.2 s into the entry | 1169, then 1130 | 1130 | 0 % / 0 % |
| In fullscreen, then `-[_NSFullScreenMenuBarCompanionController resizeContentWindow]`, `layout`, `-[_NSFullScreenContentController displayChanged]`, `-[_NSFullScreenSpace displayChanged]` | 1169, then 1130 after ~115 ms | 1130 | 0 % / 0 % |
| In fullscreen, `alwaysShowsMenuBarDidChange`, `updateTileShape`, `_updateTileShapeAndReshapeContentsWithAckServer:` | no frame request | 1130 | 0 % / 0 % |
| FullPanel Space, dropped to camera-safe, then re-laid out armed | 1169, then 1130 | 1130 | 100 % → 0 % → 0 % |

AppKit itself re-asks the fullscreen frame inside an existing session
(`resizeContentWindow`, on every companion `layout` and at
`windowDidChangeFullScreenStatus:`) and applies the whole display with
`setFrame:display:`. WindowServer then moves the window back to the camera-safe
tile: an AppKit-defined window-moved event (`-[NSWindow _windowMoved:]` →
`_setFrameAfterMove:`). That also happens to a Space that FullPanel created and
that later lost the strip. It is the documented "WindowServer can permanently
remove the strip from a fullscreen session".

So FullPanel must arm **before AppKit's first `_frameForFullScreenMode` request
of the entry**. That request follows `willEnterFullScreen` immediately (the
same call, 3–18 ms later in traces). Once it has been answered with the
camera-safe frame, no native in-place path gives the band back.

## Is in-place adoption possible?

**For an entry that already passed its first frame request: no.** This covers
attaching or enabling after `willEnterFullScreen` was delivered, and a window
that is already fullscreen. It was not done with any of: fullscreen toggling,
an overlay or fake fullscreen window, a new Space, window replacement, timed
retries, or forced `setFrame` (WindowServer reverts the last one anyway).
Such a session now says so instead of reporting a bare frame failure:

- `state` `.fallback`, `fallbackReason` `.frameNotAccepted` (unchanged public
  API), the band left black (no false claim);
- `diagnostics()["adoption"]` and `lastError`: "Enabled after this fullscreen
  entry began; the window keeps its camera-safe frame in this fullscreen Space.
  FullPanel applies from the next entry."; trace `adopt-unavailable`; one NSLog;
- the same Space, no exit, Mission Control behaves natively; the next entry is a
  FullPanel entry.

**For a restored window whose session exists before AppKit's first frame
request: yes, natively, and this is the case SwiftUI hosts normally are in.**
In `FullPanelAttachDemo`, SwiftUI's `viewDidMoveToWindow` callback (where the
host attaches) came 26–66 ms *before* the restoration's `willEnterFullScreen`.

## What changed (FPKEngine)

1. **`willEnterFullScreen` prepares any entry `-toggleFullScreen:` did not.**
   The toggle path is unchanged and is not prepared twice
   (`FPKWillEnterPreparesEntry`). Enabling between a toggle and its
   `willEnterFullScreen` prepares again with the new value.
2. **The first frame request prepares an entry nobody prepared, in one case
   only:** the session was enabled while the window was windowed (or windowed
   again after `didExitFullScreen`), and no entry, exit or in-fullscreen enable
   happened since (`FPKFrameRequestPreparesEntry`). This is a host that
   attaches from inside the entry's own `willEnterFullScreen`: an observer added
   during a notification does not receive it. It is never an existing
   fullscreen session, so it can never fight WindowServer's clamp.
3. **Enable inside an entry already under way** (`FPKEntryAlreadyUnderway`) is
   reported as above, never armed.
4. Diagnostics `entryPreparedBy` (`toggleFullScreen:`, `willEnterFullScreen`,
   `frameRequest`) and `adoption`. Traces `willEnterFullScreen`,
   `entry-prepared`, `frame-hook not engaged: …` (an enabled engine asked for a
   frame while not engaged, i.e. why an activation failed), `adopt-unavailable`.

No public API changed. Frame guards, the arming decision, SkyLight, the reveal
integration and the Mission Control recovery (`ff07917`, `40f579a` ports) are
unchanged. The restored window reaches them through the same code. One
difference from a toggled entry: a restored window enters before its Space is
active, so the `didEnterFullScreen` commit is skipped and the existing
compositor-verified return check commits once the Space becomes active (traced).

## Host requirement

Attach and enable **before AppKit's first fullscreen-frame request** of the
entry. In practice, attach synchronously when the window first appears (for
SwiftUI, from the `NSViewRepresentable`'s `viewDidMoveToWindow`, as
`FullPanelAttachDemo` does), and not after an asynchronous hop.
Attaching inside `willEnterFullScreen` also works (case 2 above). Attaching
later gives the reported fallback for that entry, never a bounce.

## Verification (2026-10-14, macOS 27.0.1, MacBook Pro 14" M1 Pro)

`Examples/FullPanelAttachDemo/run-scenarios.sh` runs this matrix:

| Scenario | Result |
| --- | --- |
| A: attach, enter normally, 10 originating-Space Mission Control returns | Active; pixels 99 % / 99 % at entry and after every return; Space unchanged; recovery path 10/10 (away, early commit, return-check rearm, `return-ready fromAway=1`, re-assert) |
| B: enter unattached, attach inside fullscreen | Documented fallback, band black, same Space, no exit; next entry Active, 99 % / 99 % |
| R1: relaunch restores the window into fullscreen, then 10 Mission Control returns | Prepared by `willEnterFullScreen`; Active; 99 % / 99 %; same Space throughout; 0 exit notifications; 1 entry; 10/10 returns |
| R2: two windows restored into two fullscreen Spaces | Both Active, both 99 % / 99 %, each kept its Space, no exits |
| R3: host attaches inside the restored entry's `willEnterFullScreen` | Prepared by `frameRequest`; Active; 99 % / 99 %; no exits |
| R4: host attaches 250 ms late (a timing observed in a SwiftUI app that attached after an asynchronous hop) | Documented fallback, band black, same Space, no exits |

The script run end to end on the final build: 63/63 checks (A 16, B 10, R1 16,
R2 9, R3 6, R4 6). Each scenario was also run individually, several times,
during development, with the same results.

Also: the full existing autotest 82/82 and AppKit-subclass mode 48/48
(`-FullPanelAttachMissionControl NO`; Mission Control covered above);
`FullPanelDemo` (`FullPanelWindow`) entered from its menu: prepared once by
`toggleFullScreen:`, Active, 100 % / 100 %; `swift test` 80/80 (70 existing).
"Pixels" is the fraction of non-black pixels in each region beside the housing
in a real screen capture. The demo draws there; ordinary fullscreen leaves it
black. Every screenshot was also inspected.

Not tested: external displays (none connected; the arming decision is
unchanged, so a housing-less screen still gives `.noCameraHousing`), private
browsing windows as such (same window class and path in SwiftUI), the
large-thumbnail and swipe Mission Control returns (originating-Space return
only), and the menu-bar hover reveal (needs a person).

## Status

| macOS | Status |
| --- | --- |
| 27.0.1 | Verified as above with the frame-override mechanism. Re-run on the merged `main` (5bcd609): `swift test` 80/80, autotest 82/82, AppKit-subclass 48/48, `run-scenarios.sh` 63/63 with 20/20 Mission Control returns. With the menu-bar reservation mechanism: restoration R1 (restored straight into FullPanel fullscreen) and R3 (attach inside the restored entry's `willEnterFullScreen`) passed one run each. |
| 15 | **Not verified for the current mechanism.** A hand check on the frame-override mechanism (2026-10-14) found FullPanel fullscreen working and two windows restored straight into FullPanel fullscreen; it does not apply to the current code. For the reservation method, macOS 15.8.1 was inspected statically only (present by symbol name). Before claiming anything, run `Tools/BehaviorProbes/ReservationProbe` and `run-scenarios.sh` there; in particular, check that restoration still posts `willEnterFullScreen` first, and that R1's Mission Control returns show `reassert-commit` (the `40f579a` port has not been hardware-verified on 15 either). |
