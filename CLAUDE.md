# CLAUDE.md — AtlasKit

The shared Swift package of the Neutrino Atlas apps (macOS + iOS). Read the platform root
`CLAUDE.md` first, then `README.md` here. The product roadmap is
`../neutrino/agent_docs/neutrino-atlas.md`.

## Rules

- **The Atlas Markdown spec lives in `../neutrino/specs/atlas-markdown/`, not here.** If
  behaviour here and the spec disagree, fix the spec and corpus in `neutrino` first, merge,
  then re-vendor with `scripts/sync-atlas-markdown-corpus.sh`. Never edit
  `Tests/AtlasCoreTests/Fixtures/atlas-markdown/` by hand: CI compares it with `neutrino` main.
- **The web and Android implementations must produce identical results** for the same input.
  A behaviour that the corpus doesn't pin is a gap: add a case to the corpus rather than
  deciding it here.
- **`AtlasCore` stays Foundation-only (plus cmark-gfm and Yams).** It must link from share extensions,
  widgets and App Intents, so no SwiftUI, AppKit or UIKit there.
- **No plaintext leaves the device.** Titles, content, tags and the link graph are resolved
  and indexed here, on the client. Nothing in this package sends them to the server
  unencrypted (roadmap, constraint 2).
- **Encryption comes from `NeutrinoCrypto`.** Never add another E2EE implementation (root
  `CLAUDE.md`, rule 5). The index is sealed through the `IndexSealer` protocol, which the app
  implements with NeutrinoCrypto. Tests may use CryptoKit; production code in AtlasCore may not.
- **Keep `VaultIndexTests.testFiveThousandPages` within the roadmap's bounds** (open < 1 s,
  search < 100 ms). If a change slows the parser or the index, measure in release before
  shipping.
- **The parser reserves U+E000–U+E0FF** for its markers (see README). Any change to the
  preprocessor must keep `ParserFuzzTests` green: no traps, and no lost characters.
- Test on both platforms: `swift test`, plus `xcodebuild test -scheme AtlasKit` on an iOS
  simulator.
