# Release checklist — 0.1.0 Developer Preview

Everything here must be checked, with evidence recorded, before the release
is approved. "Reviewed" means read and judged; "passed" means executed with
the stated result. Nothing in this file publishes anything; publication
steps are listed last and are performed by the maintainer.

**Status 2026-10-19 (MIT release candidate, this repository's initial
commit).** Sections 1–3 and 5 pass on the exact release tree. Section 4
passes for everything automated; the manual checks, and the hardware that is
not available, are open. Sections 6–7 are the maintainer's.

## 1. Source state

- [x] Release tree is the audited export: a fresh root commit, no imported
      history, no untracked or build files.
- [x] No workstation paths, private integration names or internal-document
      references in published files; relative Markdown links resolve.
- [x] No dependency in `Package.swift`; `Package.resolved` absent.
- [x] `CHANGELOG.md` 0.1.0 entry matches the code (menu-bar reservation
      geometry); date filled in at tag time.
- [x] README, ARCHITECTURE, COMPATIBILITY, TESTING, INTEGRATION_EVIDENCE and
      PRIOR_ART agree with each other and with the test results; documents
      that cite private-history commits say so.

## 2. Licensing and provenance

- [x] `LICENSE`: the standard MIT License text, `Copyright (c) 2026 Brian
      Merchant`.
- [x] Copyright: every commit in the development history is authored and
      committed by Brian Merchant; no other human contributor. AI tools are
      credited as tools, not copyright holders ([PROVENANCE.md](PROVENANCE.md)).
- [x] Every code file carries the MIT copyright header; no third-party
      license header, `[UTM-derived]` region or Apache-2.0 notice remains in
      code.
- [x] `NOTICE` and `THIRD_PARTY_NOTICES.md` separate required notices (none:
      no third-party material included) from the integrations' build-time
      dependencies, platform interfaces and acknowledgments.
- [x] Integration dependency licenses checked against the package sources
      (Tauri: five MPL-2.0 crates; winit: all permissive; Electron:
      development-only npm packages; Chromium's inventory not audited).
      Relevant only to distributed builds of the bridges, which are not part
      of this release.
- [x] Acknowledgments: UTM and its contributors, OmacVM and Gilles Goetsch,
      Try Omarchy pull request #361 and its author, and the AI-assisted
      development statement (README "Development", PROVENANCE.md).
- [ ] **Maintainer:** approve the MIT license, the copyright line and the
      provenance wording.
- [ ] Optional: counsel's view on the residual similarities with UTM's
      implementation (platform interface and general technique) and on
      AI-assisted authorship.

## 3. Automated tests (any Mac; 4 screen-release tests need a display without a housing)

- [x] `swift build` and `swift build --build-tests`: no warnings.
- [x] `swift build -Xswiftc -warnings-as-errors -Xcc -Werror`: clean.
- [x] `swift test`: 103 executed, 0 failures, 4 skipped (external display).
- [x] `swift test --sanitize=address`: same, no reports.
- [x] `Tools/ConsumerCheck/check.sh HEAD`: public API compiles from a clean
      clone; decision SPI not visible.
- [x] Examples, `Tools/SpacesHarness` and the probes build.

## 4. Hardware acceptance (notched MacBook; do not use the Mac while it runs)

macOS 27.0.1 (26A434), MacBook Pro 14-inch (M1 Pro), built-in display only
([TESTING.md](TESTING.md), "MIT release candidate").

- [x] `FullPanelAttachDemo -FullPanelAttachAutotest YES -FullPanelAttachMissionControl NO`: 82/82.
- [x] Same with `-FullPanelAttachAppKitSubclassOnly YES`: 49/49.
- [x] Lifecycle scenario, plain and under `NSZombieEnabled=YES MallocScribble=1`: 28/28 each.
- [x] Mission Control: 100 thumbnail returns (`mccampaign.sh`), 100 PASS.
- [x] Dock, Command-Tab, Space keys, large-preview return, SwiftUI smoke:
      passed on SDK code identical to this release (TESTING.md).
- [x] Display-mode round trip, Split View fallback, lock and sleep: passed
      with the reservation mechanism on an earlier revision; not repeated on
      the release code (documented).
- [ ] `run-scenarios.sh` (scenarios A, B, R1–R5, with Mission Control
      returns; includes restoration into fullscreen) on the release code.
      Run from Terminal.app.
- [ ] Manual: [MANUAL_ACCEPTANCE.md](MANUAL_ACCEPTANCE.md) M1 (gestures,
      trackpad clicks, exit) and M2 (lock, display sleep); M3–M5 where
      applicable.

### Hardware not available

Each is listed as unverified in COMPATIBILITY.md and the release notes. None
may be reported as passed from a simulation.

- [ ] Physical external display: migration, external as main,
      disconnect/reconnect, display sleep and wake.
- [ ] `swift test` with a display without a housing connected (4 tests skip
      otherwise).
- [ ] macOS 13, 14, 15 and 26: `Tools/BehaviorProbes/ReservationProbe`,
      `swift test`, autotests (macOS 15.8.1 statically inspected only).
- [ ] A second notched model (different housing size).

## 5. Integrations (compatibility, not release scope)

- [x] Electron, Tauri and winit bridges build without warnings; automated
      suites pass on the release tree (63/63, 101/101, 140/140).
- [x] [INTEGRATION_EVIDENCE.md](INTEGRATION_EVIDENCE.md) and README
      "Tested integrations" match the evidence. Bridges' Mission Control
      behaviour is not verified and is labelled so.

## 6. Package and release preparation (reviewed, not executed)

- [ ] Tag name decided: `0.1.0` (Swift Package Manager accepts `0.1.0` and
      `v0.1.0`; pick one and keep it).
- [ ] Release notes drafted from the CHANGELOG entry, including the private-API
      warning, verified hardware and the not-verified list.
- [ ] CI: [.github/workflows/ci.yml](../.github/workflows/ci.yml) is manual-only
      (`workflow_dispatch`); it builds and runs `swift test` and the consumer
      check. It cannot run hardware tests. Decide whether to enable it on push.
- [ ] Repository visibility, description and topics reviewed by the maintainer.

## 7. Publication (maintainer only, after everything above)

Not performed during preparation.

1. Fill in the CHANGELOG date; commit.
2. Create the annotated tag and push the branch and tag to the new public
   repository.
3. Create the GitHub release from the tag with the release notes.
4. Optional, later: submit the repository URL to the Swift Package Index.

## Versioning

- 0.x: minor versions (0.2.0) may change public API; patch versions (0.1.1)
  fix bugs without API changes.
- Public API: the declarations reachable through `import FullPanelKit`,
  documented in the headers and README. Not API: `diagnostics()` keys and
  values, trace output, `FullPanelKitCore.Decisions`, internal headers, user
  default names used for diagnosis.
- Behavior that depends on private macOS interfaces may change in any release
  to follow macOS; such changes are listed in the CHANGELOG.
