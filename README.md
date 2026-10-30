# AtlasKit

The Swift code shared by the Neutrino Atlas apps for macOS and iOS: the Atlas Markdown dialect,
the page index, and later the editor and shared views. Atlas is Neutrino's end-to-end encrypted
knowledge base. See the roadmap in
[`neutrino/agent_docs/neutrino-atlas.md`](https://github.com/wcherry/neutrino/blob/main/agent_docs/neutrino-atlas.md).

## Layout

| Module | What it is | Status |
|---|---|---|
| `AtlasCore` | Foundation, cmark-gfm and Yams only, so share extensions, widgets and App Intents can link it. Holds the Atlas Markdown tree (`MarkdownNode`), parser (`AtlasMarkdown.parse`), serializer (`MarkdownDocument`, `AtlasMarkdown.serializeCanonical`), page extraction (`PageExtract`, SPEC §6), link resolution (`LinkResolver`, SPEC §7) and the vault index (`VaultIndex`). | Parser, serializer and index done |
| `AtlasEditor` | The TextKit 2 editor, with AppKit and UIKit adapters | Not started |
| `AtlasUI` | SwiftUI views shared by both apps | Not started |

AtlasCore will later hold the sync engine.

### How the parser works

The CommonMark + GFM base is GitHub's cmark-gfm (`swift-cmark`), used directly rather than
through `swift-markdown`. That wrapper always turns on a non-GFM table-spans extension and
leaves out GFM's autolinks. The Atlas extensions are layered around cmark:

1. **`SourcePreprocessor`** works on the raw text, before cmark processes escapes and inline
   syntax:
   - lifts frontmatter out;
   - turns `$$` blocks into sentinel code fences;
   - turns escaped trigger characters into markers;
   - swaps wiki links, embeds and inline math for opaque placeholders, because their content
     is raw by spec.

   Markers and placeholders use the private-use range U+E000–U+E0FF. A user's own characters
   from that range are protected as literal tokens.
2. **`CMarkConverter`** runs cmark-gfm with exactly the spec's GFM extensions and converts its
   tree. It recomputes list `spread` from source lines, and puts footnote definitions back in
   source order.
3. **`ExtensionPasses`**:
   - expands placeholders;
   - pairs `==highlights==` and finds `#tags`;
   - lifts block ids;
   - turns `[!type]` blockquotes into callouts;
   - restores markers by context: an escaped `\#` is `#` in text and `\#` in code.

The preprocessor also works around cmark behaviour that loses text, all found by fuzzing.
With footnotes on, some `[^…` that can't be footnotes drop text. Apple's fork always parses
`^[text](attrs)` inline attributes. `ParserRegressionTests` pins each case, and
`ParserFuzzTests` checks 5,000 deterministic inputs for traps and lost characters. Identity, keys
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

`ConformanceCorpusTests` runs every check in SPEC §9:
- P (parse);
- R (save unedited, byte for byte);
- C (canonical form, which parses back);
- E (extraction);
- the link-resolution and link-writing fixtures.

### How saving works

`MarkdownDocument` holds a page as its top-level blocks plus the exact bytes of each block and of
every gap between them (SPEC §8.1). Saving without edits gives back the file byte for byte. A
replaced or inserted block is written in canonical form, in the file's own line endings. Everything
else stays as it was: Obsidian tab indentation, reference definitions, unused footnotes.

Canonical form (`AtlasMarkdown.serializeCanonical`, SPEC §8.3) escapes only what the tree needs.
SPEC §8.3.1 defines that by parsing, so every implementation escapes the same characters. It
starts with every candidate escaped, then unescapes candidates right to left, keeping each
unescaped only if the block still reads back the same. A handful of pathological trees, built
from characters decoded out of unusual entities, have no exact canonical text. Edits report this
(`replaceBlock` returns `false`) rather than saving a silent change.

### The vault index

`VaultIndex` is what backlinks, unlinked mentions, the tag browser, the quick switcher and
search read. It never leaves the device.

- **Storage:** an in-memory SQLite database (the system library, FTS5 for full text). At rest
  it is one snapshot sealed by an `IndexSealer`. The app implements that with NeutrinoCrypto;
  AtlasCore has no crypto of its own. A snapshot from another schema version, or one that won't
  open, is rejected, and the app rebuilds the index from the pages.
- **Links** are stored with the file they resolve to. When files appear, disappear or move,
  only links whose target names that file are re-resolved. `batch { }` defers resolution to
  one pass at the end, for a first import or a large sync.
- **Search:**
  - words match as prefixes, `"phrases"` exactly, and `-word` excludes;
  - `#tag` / `tag:x` filter by tag, nested tags included; `path:folder` filters by folder;
  - case and diacritics are ignored, and titles rank above aliases, which rank above body text.
- **Renames:** `pagesLinking(to:)` lists the pages to rewrite (`MarkdownDocument.rewriteLinks`)
  before `renameFile(from:to:)`.

Measured at 5,000 pages (~11 MB of Markdown) on an M-series Mac, release build:

| Operation | Time |
|---|---|
| Parse all pages | 0.8 s |
| Build the index | 0.35 s |
| Open a sealed snapshot (26 MB) | 53 ms |
| Search | ~5 ms |
| Quick switcher | ~10 ms |
| Backlinks | < 0.1 ms |
| Re-index one edited page | 0.6 ms |

The roadmap's Phase 1 target is under 1 s to open and under 100 ms to search.
`VaultIndexTests.testFiveThousandPages` holds the build to those bounds, on macOS and iOS.

### In-place edits

`setTask(at:checked:)` and `rewriteLinks` (renames, SPEC §7) change only the bytes of the
construct (SPEC §8.2). A toggle changes the one character between the brackets. A rewrite
changes a link's target or destination and keeps its alias, heading, inner whitespace and
URL style. Each edit is checked by reparsing the whole page. If the bytes can't express it,
the block is rewritten canonically instead, and the result says so (`EditResult.inPlace`).
"Exact" (`EditResult.exact`, `MarkdownDocument.isExact`) always means the whole page's bytes
parse to its tree. The in-repo fuzz test checks that this is never wrong.

## Building and testing

```bash
swift test                                                   # macOS
xcodebuild test -scheme AtlasKit -destination 'id=<simulator>'  # iOS
```

The Atlas apps consume this package by local path, so keep it checked out as a sibling of them
and of `neutrino_shared_ios`.
