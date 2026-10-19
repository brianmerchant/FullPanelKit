# Provenance

Where FullPanelKit came from, who holds its copyright, what third-party work
shaped it, and how it was developed. This is an engineering record kept for
transparency, not legal advice. Last reviewed 2026-10-19 against the exact
release tree.

## Summary

- **License and copyright.** FullPanelKit is MIT-licensed, Copyright (c) 2026
  Brian Merchant ([LICENSE](../LICENSE)). The release tree contains no
  third-party source code ([THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)).
- **Not clean-room.** FullPanel's first implementation was built on an
  Objective-C port of UTM's camera-housing fullscreen (Apache-2.0). Those
  adapted portions were later removed or replaced by a redesign whose authors
  had read them, and the geometry was later redesigned again around AppKit's
  own menu-bar reservation, an approach learned from Try Omarchy pull request
  #361. The current implementation is a redesign, not a clean-room
  reimplementation.
- **Fresh public history.** This repository starts from a new root commit
  made from the audited release tree. The earlier development history is kept
  privately (see "Public history" below).
- **AI-assisted.** FullPanelKit is a human-directed project developed with
  substantial assistance from Anthropic Claude Code and OpenAI Codex (see
  "Development methodology").

## Copyright and contributors

| Role | Who | Basis |
| --- | --- | --- |
| Creator, maintainer and copyright holder | Brian Merchant | Every commit in the development history (90 commits on all branches, reviewed 2026-10-19) is authored and committed by Brian Merchant (GitHub identity `brianmerchant`). No other human contributor appears in the history |
| Development tools | Anthropic Claude Code, OpenAI Codex | Tools used under human direction. They are not authors, copyright holders or maintainers. 87 of the 90 commits carry a `Co-Authored-By: Claude …` trailer recording that assistance |

The MIT license grants the rights the copyright holder has. Where material
was produced with AI assistance, the extent of copyright protection can
depend on the human contribution and on jurisdiction. That question does not
add any third party's rights to the code, and it is noted here rather than
resolved.

## Lineage

| Date (2026) | Step |
| --- | --- |
| Sep 20 – Oct 14 | **UTM** (Turing Software, LLC; author osy) adds native fullscreen beside the camera housing to its VM window: [PR #7885](https://github.com/utmapp/UTM/pull/7885) (merged Sep 20) and [PR #7910](https://github.com/utmapp/UTM/pull/7910) (merged Oct 14), `Platform/macOS/Display/VMDisplayWindow.swift`, Apache-2.0 |
| Oct 7 – 8 | A "UTM notch shim" for OmacVM's QEMU display: an Objective-C port of UTM's approach whose own header credits UTM PR #7910 (Apache-2.0). Its author is not recorded; its form (an archive with 1980 file timestamps) suggests it was produced with a generative coding tool, but which tool is unverified. It no longer exists in any form in FullPanelKit |
| Oct 9 – 10 | Brian Merchant builds FullPanel, a native fullscreen mode for **OmacVM**'s QEMU display, on that port, on a branch of his OmacVM fork; much of FullPanel's early hardware testing happens there |
| Oct 10 | Brian Merchant proposes the working branch upstream in [OmacVM issue #339](https://github.com/gillesgoetsch/OmacVM/issues/339). Gilles Goetsch later ships his own FullPanel implementation in OmacVM, based on that branch. It is downstream of FullPanel, not an input to FullPanelKit |
| Oct 10 | FullPanel is extracted from a local hardware-test probe into this separate Swift package, FullPanelKit ([HARDWARE_BASELINE.md](HARDWARE_BASELINE.md)) |
| Oct 10 – 17 | FullPanelKit grows its own engine: `FullPanelSession` attachment, Mission Control and Space return recovery, entry adoption, display release and resume, presentation ownership across windows, the Swift and SwiftUI layer, tests, harnesses, examples and the Electron, Tauri and winit bridges. None of this has a UTM counterpart |
| Oct 17 | A source-level audit compares FullPanelKit with UTM and OmacVM. It finds that the fullscreen-frame hook, the SkyLight menu-bar layer, the menu-bar reveal observer and the reveal/presentation logic were **adapted** from UTM (a close translation), and finds no OmacVM code by other authors. The unpublished 0.1.0 candidate is relicensed Apache-2.0 with UTM's notices and per-region markers |
| Oct 17 – 18 | **Redesign.** Every adapted portion is removed or replaced: a reveal sensor built on public API (KVO on AppKit's fullscreen titlebar window), a declarative facts-to-intent reconciler, entry preparation at `willEnterFullScreen` instead of a `-toggleFullScreen:` override, and a rewritten SkyLight module. Written by an AI-assisted session that had read the adapted code, so it is a redesign by exposed authors, not clean-room. A targeted review of what remained found the platform interface (names, signatures, constants and call order dictated by AppKit and SkyLight), commonplace techniques and required behaviour, and no remaining expression identifiable as UTM's |
| Oct 18 | **Reservation geometry.** [Try Omarchy pull request #361](https://github.com/omacom/try-omarchy/pull/361) ("Full macOS notch support", by themartiano, MIT) is read at commit `f34e179b`: its description, its camera-notch document and the patch regions for the reservation hook, window level and pointer reveal. What was taken: the fact that AppKit's fullscreen content controller asks `-reservesSpaceForMenuBarInFullScreen`, and that answering NO makes AppKit lay the window out over the whole display. FullPanelKit's hook was written from that selector, its type encoding, runtime introspection on macOS 27.0.1 and FullPanelKit's own engine state. It differs from the pull request: AppKit's answer first, changed only for windows in a FullPanel entry, verified per entry, installed once with ownership checks; no window-level change (FullPanelKit keeps its SkyLight backdrop override) |
| Oct 18 – 19 | The redesigned fullscreen-frame override, its frame guards, the content-size answer and the per-class attachment hooks are removed. The reservation hook is the SDK's only runtime method replacement, and no window class is modified |
| Oct 19 | MIT release candidate prepared from the audited tree, with a fresh Git root |

## What FullPanelKit shares with UTM today

The platform interface: AppKit's and SkyLight's names, type signatures and
constants, the order SkyLight requires (create a transaction, set the
override, commit), AppKit's fullscreen titlebar window class name, the
`AppleMenuBarVisibleInFullscreen` preference, and the behaviour any
implementation must produce. These are interoperability facts. FullPanelKit's
mechanisms differ: AppKit lays the window out (no frame override), the reveal
is sensed through public KVO (no private setter hooks), and a declarative
reconciler applies one intent (not a set of imperative handlers).

## Public history

The development repository's early commits contain the UTM-adapted code.
Some of the earliest snapshots carried an MIT license file without the
Apache-2.0 text and UTM's notices that those portions required. To avoid
distributing those snapshots without their notices, this public repository
starts from a **new root commit** made from the audited release tree, and
the earlier history is not published. It is kept privately, unchanged, as the
provenance record.

A fresh history only avoids publishing those intermediate versions. It does
not by itself settle obligations for any third-party material in the tree;
that rests on the tree containing none (section 1 of
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)).

## Development methodology

FullPanelKit is a **human-directed, AI-assisted** project.

- **Human direction.** Brian Merchant set the goals and scope, made the
  design, licensing and release decisions, chose what to keep, ran and
  supervised the hardware tests, and approves every release.
- **Anthropic Claude Code** assisted with implementation, architecture
  investigation, debugging, automated test and harness development, hardware
  validation workflows, code review, documentation, licensing and provenance
  research, and release preparation.
- **OpenAI Codex** assisted with implementation, technical research,
  debugging, test development, early fullscreen integration work, and
  architecture and compatibility investigations, including in the earlier
  integrations FullPanel grew out of.
- **What AI assistance does not establish.** It does not make the AI tools
  or their vendors authors or copyright holders, and it does not guarantee
  originality: an AI-assisted rewrite is not automatically independent of
  sources its author or the tool had seen. Third-party provenance therefore
  had to be reviewed separately (the audits recorded above), and every
  change, claim and release requires human review and verification.

## Verification behind these statements

- No `[UTM-derived]` region, Turing Software notice or Apache-2.0 header
  remains in source; the history notes in the affected files say what they
  once contained.
- Each redesign step was recorded as it happened (which session read what,
  and in what order). The detailed audits, the side-by-side comparison with
  UTM and those records are kept with the private development history.
- References above (UTM, OmacVM and Try Omarchy pull requests, issues,
  authors, dates and licenses) were re-checked against GitHub on 2026-10-19.

## Limits

- Not legal advice, and no counsel has reviewed it. An opinion on the
  residual similarities (dictated interfaces and general technique) is
  optional and the owner's decision.
- The origin of the October 7 – 8 shim is unverified; UTM's attribution does
  not depend on it.
