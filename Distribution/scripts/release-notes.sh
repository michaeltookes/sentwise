#!/usr/bin/env bash
#
# Build the GitHub release notes file for a version (backlog item 144).
#
#   release-notes.sh <version> <CHANGELOG.md> <output-file>
#
# Copies the '## [X.Y.Z]' CHANGELOG section and appends a fixed Quickstart
# footer. Fails closed: a missing or empty section exits non-zero naming the
# version (no placeholder notes), and the result is checked to contain the
# Quickstart URL exactly once. The footer depends on the README '## Quickstart'
# heading (see docs/ci-release.md).
set -euo pipefail

QUICKSTART_URL="https://github.com/michaeltookes/sentwise#quickstart"

if [[ $# -ne 3 ]]; then
  echo "usage: release-notes.sh <version> <CHANGELOG.md> <output-file>" >&2
  exit 2
fi
ver="$1"; changelog="$2"; out="$3"

[[ -f "$changelog" ]] || { echo "release-notes: $changelog not found" >&2; exit 1; }

notes="$(awk -v ver="$ver" '
  index($0, "## [" ver "]") == 1 { grab=1; next }
  grab && /^## \[/ { exit }
  grab { print }
' "$changelog")"
# Strip leading/trailing blank lines.
notes="$(printf '%s\n' "$notes" | sed -e '/./,$!d' | tail -r | sed -e '/./,$!d' | tail -r)"

if [[ -z "$notes" ]]; then
  echo "release-notes: CHANGELOG.md has no section, or an empty one, for version $ver; refusing to publish placeholder notes" >&2
  exit 1
fi

printf '%s\n\nQuickstart: %s\n' "$notes" "$QUICKSTART_URL" > "$out"

count="$(grep -cF "$QUICKSTART_URL" "$out" || true)"
if [[ "$count" -ne 1 ]]; then
  echo "release-notes: notes file must contain the Quickstart URL exactly once (found $count): $QUICKSTART_URL" >&2
  exit 1
fi
