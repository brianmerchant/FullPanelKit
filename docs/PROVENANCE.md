# Provenance and acknowledgments

FullPanelKit 0.1.0 is the **first public release of the FullPanelKit SDK**. It is a separate, opt-in macOS fullscreen library maintained by Brian Merchant and distributed under the MIT License ([LICENSE](../LICENSE)).

## Scope of this release

The released implementation lets AppKit control fullscreen window geometry using the fullscreen menu-bar reservation behavior, while FullPanelKit coordinates window and Space state, the backdrop, and menu-bar presentation. The project uses private AppKit and SkyLight interfaces; see [COMPATIBILITY.md](COMPATIBILITY.md).

The reviewed 0.1.0 source distribution contains **no source code copied or adapted from UTM, Try Omarchy, or OmacVM**. This statement concerns the distributed release tree. It is not a claim that FullPanelKit was developed without studying earlier implementations or that it was a clean-room project.

The SDK was developed and tested privately before this first public release. The public repository begins with a fresh root commit from the reviewed 0.1.0 source tree. The maintainer retains the detailed development-history and source-comparison records separately. A fresh Git history alone does not establish code provenance; the source audit is described in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Creator and maintenance

**Brian Merchant** is FullPanelKit's creator and maintainer and is named in the copyright notice (`Copyright (c) 2026 Brian Merchant`). The published source is made available under the MIT License. This statement does not claim exclusive copyright in platform-defined interfaces or other uncopyrightable facts.

## Prior work and acknowledgments

- **[UTM](https://github.com/utmapp/UTM)**, by Turing Software, LLC and contributors, including [PR #7885](https://github.com/utmapp/UTM/pull/7885) and [PR #7910](https://github.com/utmapp/UTM/pull/7910), is important prior work demonstrating native macOS fullscreen presentation beside the MacBook camera housing.
- **[Try Omarchy](https://github.com/omacom/try-omarchy)**, especially [PR #361](https://github.com/omacom/try-omarchy/pull/361) by [themartiano](https://github.com/themartiano), informed the choice to let AppKit lay out the window through its fullscreen menu-bar reservation behavior. The released FullPanelKit hook was separately implemented for the SDK's lifecycle and attachment model.
- **[OmacVM](https://github.com/gillesgoetsch/OmacVM)**, maintained by Gilles Goetsch, provided the original application context in which the FullPanel approach was developed and tested. FullPanelKit is a separate SDK; OmacVM does not maintain or endorse it.
- **[yabai](https://github.com/asmvik/yabai)** and CGSInternal were references for publicly described SkyLight function names and constants, not sources copied into this release.

Credit acknowledges historical work and technical influence. It does not imply sponsorship or endorsement by any of these projects. These acknowledgments are not a substitute for license notices if third-party source material is incorporated into a future distribution.

## Development methodology

FullPanelKit is a **human-directed, AI-assisted** project. Brian Merchant set its goals, directed its development, supervised hardware testing, and makes release decisions. Anthropic Claude Code and OpenAI Codex assisted with implementation, research, debugging, testing, review, and documentation. Naming those tools acknowledges their role; it does not represent their vendors as maintainers or third-party source licensors.

## Limitations of this record

This is a public description of the **0.1.0 release** and its acknowledged influences, not a complete publication of every private experiment. The maintainer retains the more detailed internal provenance audit. As with any source audit, the absence of identified copied code is an engineering finding, not a legal guarantee; no legal counsel has reviewed this release.
