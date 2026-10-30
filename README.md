# AtlasKit

The Swift code shared by the Neutrino Atlas apps for macOS and iOS: the Atlas Markdown dialect,
the page index, and later the editor and shared views. Atlas is Neutrino's end-to-end encrypted
knowledge base. See the roadmap in
[`neutrino/agent_docs/neutrino-atlas.md`](https://github.com/wcherry/neutrino/blob/main/agent_docs/neutrino-atlas.md).

## Layout

| Module | What it is | Status |
|---|---|---|
| `AtlasCore` | Foundation + Yams only, so share extensions, widgets and App Intents can link it. Holds the Atlas Markdown tree (`MarkdownNode`), page extraction (`PageExtract`, SPEC §6) and link resolution (`LinkResolver`, SPEC §7). | Started: no parser yet |
| `AtlasEditor` | The TextKit 2 editor, with AppKit and UIKit adapters | Not started |
| `AtlasUI` | SwiftUI views shared by both apps | Not started |

AtlasCore will later hold the parser, serializer, encrypted index and sync engine. Identity, keys
and encryption come from `NeutrinoShared` (`../neutrino_shared_ios`), which never depends on
this package.

## The spec and its corpus

Atlas pages are Markdown files edited by three independent implementations: this package, the
web app and the Android app. They agree through
[`neutrino/specs/atlas-markdown/SPEC.md`](https://github.com/wcherry/neutrino/blob/main/specs/atlas-markdown/SPEC.md)
and its conformance corpus. A copy of the corpus is vendored in
`Tests/AtlasCoreTests/Fixtures/atlas-markdown/`. **Never edit that copy.** Change the spec and
corpus in `neutrino`, merge, then run:

```bash
scripts/sync-atlas-markdown-corpus.sh          # copy from ../neutrino, record the commit
scripts/sync-atlas-markdown-corpus.sh --check  # fail if the copy has drifted
```

CI runs `--check` against `neutrino`'s `main`.

`ConformanceCorpusTests` currently runs:
- the tree-model round trip;
- check E (extraction) on the expected trees;
- the link-resolution and link-writing fixtures.

Checks P, R and C (parse, round-trip, canonical) arrive with the parser and serializer.

## Building and testing

```bash
swift test                                                   # macOS
xcodebuild test -scheme AtlasKit -destination 'id=<simulator>'  # iOS
```

The Atlas apps consume this package by local path, so keep it checked out as a sibling of them
and of `neutrino_shared_ios`.
