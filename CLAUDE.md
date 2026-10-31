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
- **Only `AtlasDrive` depends on `NeutrinoShared`** (`../neutrino_shared_ios`, by path), and
  only on `NeutrinoCore` and `NeutrinoCrypto`. A change there can break this package; after
  one, run `scripts/test-against-server.sh` as well as the unit tests. The adapter never sends
  autosave's `metadata` part: its `title` becomes a plaintext rename.
- **Encryption comes from `NeutrinoCrypto`.** Never add another E2EE implementation (root
  `CLAUDE.md`, rule 5). The index is sealed through the `IndexSealer` protocol, which the app
  implements with NeutrinoCrypto. Tests may use CryptoKit; production code in AtlasCore may not.
- **Apps change pages through `VaultWorkspace`, never `Vault` directly.** It keeps the index
  current and holds back edits made during a sync pass (see README). `VaultSync.sync()` runs on
  its caller's actor; keep the `isolation:` parameter on it and on every async helper it calls,
  or a pass touches the vault off the main actor.
- **Keep `VaultIndexTests.testFiveThousandPages` within the roadmap's bounds** (open < 1 s,
  search < 100 ms). If a change slows the parser or the index, measure in release before
  shipping.
- **The parser reserves U+E000–U+E0FF** for its markers (see README). Any change to the
  preprocessor must keep `ParserFuzzTests` green: no traps, and no lost characters.
- Test on both platforms: `swift test`, plus `xcodebuild test -scheme AtlasKit-Package` on an iOS
  simulator. Changes to `AtlasDrive` or the sync engine also need
  `scripts/test-against-server.sh`.
- **Never add a macOS (or iOS) job to GitHub Actions.** macOS runners bill at ten times Linux
  minutes, so CI runs only the Linux corpus check, and the tests above run locally before every
  PR. Say in the PR that they passed.
