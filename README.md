# AtlasKit

The Swift code shared by the Neutrino Atlas apps for macOS and iOS: the Atlas Markdown dialect,
the page index, and later the editor and shared views. Atlas is Neutrino's end-to-end encrypted
knowledge base. See the roadmap in
[`neutrino/agent_docs/neutrino-atlas.md`](https://github.com/wcherry/neutrino/blob/main/agent_docs/neutrino-atlas.md).

## Layout

| Module | What it is | Status |
|---|---|---|
| `AtlasCore` | Foundation, cmark-gfm and Yams only, so share extensions, widgets and App Intents can link it. Holds the Atlas Markdown tree (`MarkdownNode`), parser (`AtlasMarkdown.parse`), serializer (`MarkdownDocument`, `AtlasMarkdown.serializeCanonical`), page extraction (`PageExtract`, SPEC §6), link resolution (`LinkResolver`, SPEC §7), the syntax map an editor styles from (`AtlasMarkdown.syntax(of:)`), the vault index (`VaultIndex`), sync (`Vault`, `VaultSync`), and `VaultWorkspace`, which ties them together for an app. | Done |
| `AtlasDrive` | The Drive adapter for sync (`DriveVaultRemote`, a `VaultRemote`): HTTP against `/api/v1/drive`, the vault's folder tree, and encryption with `NeutrinoCrypto`. Also `DeviceSealer`, which seals a device's copy of a vault with a device key. Depends on `NeutrinoCore` and `NeutrinoCrypto` from `../neutrino_shared_ios`. | Done |
| `AtlasEditor` | The TextKit 2 editor: `AtlasTextView` for AppKit and UIKit, `AtlasEditorView` for SwiftUI. Live Preview, list and quote continuation, indent and outdent, checkbox toggles, formatting commands. Its styling (`MarkdownStyler`) and commands (`MarkdownEditing`) are Foundation-only. Depends on AtlasCore only. | First version |
| `AtlasUI` | SwiftUI views shared by both apps | Not started |

`AtlasCore` has no dependency on `NeutrinoShared`; only `AtlasDrive` does, so the parser, index
and sync engine can be tested without a server or a keyring.

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

### The syntax map

`AtlasMarkdown.syntax(of:)` says where every construct of a page sits in its source, in UTF-16
offsets as TextKit counts them. That covers headings, emphasis, links, wiki links, tags, code,
callouts, list items and the rest. It also marks every syntax character (`**`, `## `, `[[`,
`>`, `[ ]`, fences, escapes, block ids) as a `.syntax` span, so an editor can style the Markdown
in place and hide its syntax away from the cursor (Live Preview).

It doesn't parse a second time. The parser's tree decides what each block contains, and the
map aligns that tree with the block's text, one character at a time. Escapes, character
references, soft breaks, and the `>` and indentation prefixes of nested containers are all
accounted for. A block is `isComplete` when every character matched. Otherwise its spans stop
where alignment did, and the rest of the block stays plain: styling can be incomplete, but
the text is never touched.

`PageSyntaxTests` holds it to the parser in three ways:
- every block of the conformance corpus aligns completely;
- in each complete block, the constructs found are exactly the tree's nodes, payloads included;
- on random pages, at least 99.5% of blocks align, with no traps and no span out of bounds.

The random-page test also found three wrong block ranges in the parser, now fixed:
- a paragraph that a table interrupts;
- the block before such a paragraph;
- an unclosed code fence's trailing blank lines.

Each would have left text behind when the block was replaced.

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

### Sync

A vault on the device is a `Vault`: every file's content, its content at the last sync (the
base of a three-way merge), and a sync record (Drive file id, base `content_version`, dirty and
deleted flags). All local edits go through it. `SealedDiskStorage` keeps it on disk as sealed
blobs with random names, plus a sealed journal of changes, so neither titles nor content
appear on disk. Each change appends one small journal entry. A torn final entry, from a crash,
is cut off on open; a wrong key throws and touches nothing.

`VaultSync.sync()` is one pass against a `VaultRemote` (the Drive folder tree; neutrino#292
records why names are real Drive names). It never discards a change:

| Here | There | Result |
|---|---|---|
| edited | unchanged | pushed with `expectedVersion`; a 409 falls through to a merge |
| unchanged | edited | pulled |
| edited | edited | line-level three-way merge (`ThreeWayMerge`), pushed. If the same lines changed, the server's version keeps the page and this device's goes to `Title (conflicted copy 2026-10-29 1405).md` |
| edited | deleted | uploaded again (an edit wins over a deletion) |
| deleted | unchanged / edited | deleted on the server / pulled back |
| moved | anything | the move follows; if both sides moved it, the server's path wins |

Path collisions (Drive allows two files with one name) are resolved deterministically. The
file with the smallest id keeps the path, and the others move to `Title (conflicted copy <id>).md`,
so devices noticing at once agree rather than moving files back and forth. Every outcome is
committed only after the server accepted it, so an interrupted pass resumes safely.

`VaultSyncTests` runs a three-device property test with random edits, moves, deletions and
interrupted syncs. Every device must converge to the server's state, and every line ever
written must survive unless some device removed it. It runs 40 seeds in CI; it has passed
3,000 seeds of 200 operations (`ATLAS_SYNC_SEEDS`, `ATLAS_SYNC_OPS`). At 5,000 files, a first
sync takes 0.19 s and a pass with nothing to do 55 ms, against an in-memory server.

### The workspace

An app opens a vault as a `VaultWorkspace` and does every page operation through it: reading,
writing, creating, renaming, deleting, syncing. It keeps the index (`VaultIndex`) in step with
the files. A rename rewrites the links to the page across the vault, through
`MarkdownDocument.rewriteLinks`, so only the link bytes change.

It lives on the main actor, like the UI. `VaultSync.sync()` takes the caller's isolation
(`#isolation`), so a pass runs there too and only suspends at network calls. Without that, the
pass would touch the vault off the main actor while the UI did on it.

Two more rules close the races that remain:
- **Edits during a pass are held back** and written when the pass ends. The pass commits each
  file only after the server accepted it, so an edit slipped in under a push would be recorded
  as synced, and a later pull would overwrite it.
- **Moves and deletions wait** for the running pass to finish.

"Link it" for unlinked mentions is `VaultWorkspace.linkMentions(of:in:name:)`, built on
`AtlasMarkdown.linkingMentions`. The index finds which pages mention a title
(`unlinkedMentions`), and this finds where:
- **Where it looks:** the plain text of each block, through the syntax map. Never code, math,
  frontmatter, links, tags, or across syntax characters.
- **What it writes:** the words as written. `[[plan]]` when they're the target up to case,
  otherwise `[[Projects/Plan|plan]]`.
- **The check:** like the other in-place edits, the result is checked by parsing it. The page
  must read back as the old tree plus exactly the new links, or nothing is written.

`VaultWorkspaceTests` makes both races happen, with a remote that holds a push until the test
releases it.

A device's copy of a vault is a `SealedDiskStorage` sealed by `DeviceSealer`, which is
NeutrinoCrypto's file encryption with a key the app keeps in its Keychain. That key isn't the
account's keyring: losing it loses only this copy, which the next sync downloads again.

### Daily notes and templates

`DailyNotes` names a day's note: `Daily/2026-10-30.md` by default, with the folder and the
date format configurable. `VaultWorkspace.dailyNote(for:settings:)` opens it, creating it from
its template the first time. `PageTemplate.render` fills `{{title}}`, `{{date}}`, `{{time}}`
and `{{date:FORMAT}}`.

Two devices that create the same day's note before syncing end up with one page, because sync
adopts a file both sides created with the same content. That's why the default template is
empty, and why a template shouldn't use what differs between devices, such as `{{time}}`.

Page templates are pages in a templates folder (`Templates` by default, as in Obsidian), so
they sync and are encrypted like any page. `VaultWorkspace.templates(in:)` lists them by title,
along with the built-in `Template.builtIn` (a Meeting template) that a page of the same name
replaces. `createPage(from:titled:in:)` renders one into a new page, and `{{title}}` is the
title the page actually gets, numbered if the one asked for was taken.

### Import and export

`FolderSnapshot.read(folder)` reads a folder of Markdown and attachments, such as an Obsidian
vault, leaving out:
- hidden files and folders: `.obsidian`, `.trash`, `.git`;
- symbolic links, so nothing outside the folder is read;
- files over 100 MB, which it lists.

`VaultWorkspace.importFiles(_:into:)` writes the files into the vault with their bytes
unchanged. Atlas Markdown reads Obsidian's dialect as it is, and links resolve the way
Obsidian resolves them, so nothing is rewritten.
- A file that's already there with the same content is skipped.
- A file with other content goes beside the existing one as `Name (imported).md`, so nothing
  is overwritten, and importing the same folder twice adds nothing.
- The report lists the wiki links that still resolve to nothing.

`exportFiles()` is the vault, decrypted. `FolderSnapshot.write(to:)` writes it into a folder
that must be new or empty, so an export never mixes with other files or overwrites them.

### The Drive adapter

A vault is a Drive folder; `DriveVaultRemote.createVault(named:)` makes one. Pages and
attachments are ordinary Drive files at their real paths (neutrino#292), so folder and file
names are visible to the server, and content is not. Each file is encrypted the way Drive's own
clients do it, with `NeutrinoCrypto`: a fresh key per file (`DriveFileCrypto.newDEK`), sealed to
the keyring's active public key, chunked content encryption, and `encrypted_metadata` holding
the name and MIME type.

- `list` walks the folder tree breadth-first (Drive has no change feed).
- `download` reads the file's `content_version` before and after the content and retries if they
  differ, so the version it reports is the version of the bytes.
- `replace` is Drive's autosave with `expectedContentVersion`; a 409 becomes
  `VaultRemoteError.conflict`, which `VaultSync` turns into a merge. It sends no `metadata`
  part, because autosave applies its `title` as a plaintext rename.
- `create` and `move` create missing folders, checking the listing first so two passes don't
  make two folders of one name.
- A 401 retries once with `accessToken(forceRefresh: true)`.

A rename or move changes the plaintext Drive name but not `encrypted_metadata`, which keeps the
name the file was created with: Drive has no endpoint to update it. That's the accepted cost of
mirroring the tree (neutrino#292); Atlas reads names from the tree, never from the metadata.

`DriveVaultIntegrationTests` runs the adapter and two-device sync against a real server: it
checks that the server stores ciphertext, that a stale write gets a 409 and merges, moves,
deletions, attachments, key rotation, and a short randomized run. It's skipped unless
`ATLAS_TEST_SERVER` is set. `scripts/test-against-server.sh` builds `../neutrino`, starts it with
a throwaway database, and runs them.

### In-place edits

`setTask(at:checked:)` and `rewriteLinks` (renames, SPEC §7) change only the bytes of the
construct (SPEC §8.2). A toggle changes the one character between the brackets. A rewrite
changes a link's target or destination and keeps its alias, heading, inner whitespace and
URL style. Each edit is checked by reparsing the whole page. If the bytes can't express it,
the block is rewritten canonically instead, and the result says so (`EditResult.inPlace`).
"Exact" (`EditResult.exact`, `MarkdownDocument.isExact`) always means the whole page's bytes
parse to its tree. The in-repo fuzz test checks that this is never wrong.

### The editor

The text in `AtlasTextView` is the page's Markdown, always, so what's saved is exactly what was
typed. Everything the reader sees is attributes:
- `MarkdownStyler` turns the syntax map into style runs, which `EditorTheme` turns into fonts and
  colours.
- In **Live Preview**, syntax that only decorates is hidden: `**`, `## `, `[[Target|`,
  `(url)`, escapes and `^id` take no space (a near-zero font size, transparent). It shows again
  when the cursor touches its construct, ends included, so the cursor never moves through
  hidden characters.
- List markers, checkboxes, quote markers, fences and table pipes stay visible, dimmed: they're
  the structure. **Source** mode shows everything.
- After a keystroke the page is mapped again (well under a millisecond for a usual page). After
  a selection change, only the blocks the cursor left or entered are restyled.

Commands are pure functions in `MarkdownEditing`, returning a `TextEdit`, and both views run
them through the text system so they're undoable:
- **Return** continues a list item, task or quote. On an empty item it removes the marker, which
  ends the list.
- **Tab** and **Shift-Tab** indent and outdent list items: under the sibling above, and back to
  the parent's level.
- Clicking or tapping a checkbox, or **⌘↩**, ticks a task by changing the one character
  between the brackets (SPEC §8.2).
- **⌘B**, **⌘I** and **⌘E** wrap or unwrap the selection in `**`, `_` or a backtick.
- **Links** are followed by a click when they show as links (Live Preview, cursor elsewhere),
  and by ⌘-click always. With the cursor in a link, a click edits it. The view calls
  `onOpenLink` with a `LinkTarget`; the app resolves wiki links with `LinkResolver` (and
  creates the page if none matches).
- **Typing `[[`** suggests pages from `linkCompletions(context)`, which the app answers from its
  index. On macOS that's the system completion list; on iOS it's a bar above the keyboard.
  Accepting inserts the link target and closes it with `]]`, unless it already was.
- **After `[[Page#`** the context names the page (`LinkCompletionContext.page`, empty for
  `[[#`, this page) and the app suggests its headings (`VaultIndex.headings(of:)`,
  `matchingHeadings`). A heading goes into a link as `AtlasMarkdown.headingLinkText` writes it:
  without `[`, `]`, `|` and `^`, which a link can't hold there.
- **Following a heading link** (`[[Page#Heading]]`, `[[Page#^id]]`): the app opens the page and
  passes an `EditorAnchor`. `AtlasTextView.reveal` finds it with `PageSyntax.anchor` (the first
  heading whose link text matches, ignoring case; or the list item or line carrying `^id`), puts
  the cursor there and scrolls it to the top.

- **Pasting a copied link** gives `[Title](url)`. That happens when the clipboard holds one
  http(s) URL as text, and as HTML just one link to it with a title, which is what Neutrino
  Notes' and browsers' "Copy link" write (`MarkdownEditing.pastedLink`). The title is escaped
  so it shows as written. Anything else, and anything pasted into code, pastes as plain text.
- **Typing `/`** at a line's start or after a space opens the `/` menu, from `slashCommands`
  (`SlashCommand.builtIn()` by default; the app adds its templates). The text after the `/`
  narrows it by title, title word or keyword. A command replaces the `/` and its text.
  - **Line commands** (headings, lists, task, quote) change the line's marker and keep its text.
  - **Insert commands** (code, math, table, divider, callout, link, date, time) insert text.
    Blocks go on a line of their own, after a blank line if the line before has text: a
    `---` right under a paragraph would make it a heading.
  - Not in code, math or frontmatter, and not inside a word: `and/or` and `1/2` are text.

Smart quotes, dashes and other substitutions are off: they would change the Markdown.

Not yet: rendered images, embeds and
checkboxes, and syntax highlighting inside code blocks.

## Building and testing

```bash
swift test                                                   # macOS
xcodebuild test -scheme AtlasKit-Package -destination 'id=<simulator>'  # iOS
scripts/test-against-server.sh                               # AtlasDrive against a real server
```

The Atlas apps consume this package by local path, so keep it checked out as a sibling of them
and of `neutrino_shared_ios`.
