#!/usr/bin/env bash
# Copies the Atlas Markdown conformance corpus from the sibling neutrino checkout, where its
# only editable copy lives (neutrino/specs/atlas-markdown/corpus, SPEC §9.3). Never edit the
# vendored copy in place: change the spec and corpus in neutrino, merge, then re-run this.
#
#   scripts/sync-atlas-markdown-corpus.sh          copy, and record the neutrino commit
#   scripts/sync-atlas-markdown-corpus.sh --check  fail if the vendored copy differs
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
neutrino="${NEUTRINO_DIR:-$here/../neutrino}"
src="$neutrino/specs/atlas-markdown/corpus"
dest="$here/Tests/AtlasCoreTests/Fixtures/atlas-markdown"

[ -d "$src" ] || { echo "no corpus at $src (set NEUTRINO_DIR)" >&2; exit 1; }

if [ "${1:-}" = "--check" ]; then
  if diff -r "$src" "$dest" --exclude VENDORED_FROM >/dev/null; then
    echo "vendored corpus matches $src"
  else
    echo "vendored corpus differs from $src — run scripts/sync-atlas-markdown-corpus.sh" >&2
    exit 1
  fi
  exit 0
fi

if [ -n "$(git -C "$neutrino" status --porcelain -- specs/atlas-markdown/corpus)" ]; then
  echo "refusing to vendor uncommitted corpus changes in $neutrino" >&2
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"
cp -R "$src/." "$dest/"
sha="$(git -C "$neutrino" rev-parse HEAD)"
printf 'wcherry/neutrino %s specs/atlas-markdown/corpus\n' "$sha" > "$dest/VENDORED_FROM"
echo "vendored corpus from neutrino@${sha:0:8}"
