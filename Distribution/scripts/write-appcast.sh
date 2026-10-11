#!/usr/bin/env bash
#
# Release step 7: write dist/appcast.xml with release notes (backlog item 114).
#
#   1. Render the version's CHANGELOG.md section to an HTML fragment placed next
#      to the update archive (dist/Sentwise-<version>.html). Sparkle's
#      generate_appcast (2.x) pairs a .html file with the archive of the same
#      basename and, with --embed-release-notes, embeds it as the item's
#      <description> — so the update dialog shows what changed.
#   2. Run generate_appcast over the dist dir (signs the archive, writes
#      appcast.xml).
#   3. Verify loudly: appcast.xml exists, references the archive, and the
#      archive's <item> carries a non-empty <description>.
#
# Called by release.sh; also runnable on its own against a fixture dist dir
# (Distribution/scripts/tests/test-release-notes.sh does exactly that).
#
# Usage:
#   write-appcast.sh --dist DIR --version X.Y.Z --archive NAME [--changelog PATH]
#
# Environment:
#   SPARKLE_BIN         directory holding generate_appcast (else PATH)
#   SPARKLE_ED_KEY_FILE EdDSA private key file, passed as --ed-key-file (CI).
#                       Unset: generate_appcast reads the login Keychain.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST=""
VERSION=""
ARCHIVE_NAME=""
CHANGELOG_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist)      DIST="${2:?}"; shift 2 ;;
    --version)   VERSION="${2:?}"; shift 2 ;;
    --archive)   ARCHIVE_NAME="${2:?}"; shift 2 ;;
    --changelog) CHANGELOG_ARGS=(--changelog "${2:?}"); shift 2 ;;
    -h|--help)   sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "write-appcast: unknown argument: $1" >&2; exit 2 ;;
  esac
done

: "${DIST:?write-appcast: --dist is required}"
: "${VERSION:?write-appcast: --version is required}"
: "${ARCHIVE_NAME:?write-appcast: --archive is required}"

if [[ ! -f "$DIST/$ARCHIVE_NAME" ]]; then
  echo "write-appcast: archive $DIST/$ARCHIVE_NAME not found." >&2
  exit 1
fi

# ---- 1. release notes next to the archive ----------------------------------
notes="$DIST/${ARCHIVE_NAME%.*}.html"
# Render to a temp file first so a failed render never leaves a stale/partial
# notes file behind for generate_appcast to pick up.
tmp_notes="$(mktemp)"
trap 'rm -f "$tmp_notes"' EXIT
if ! "$SCRIPT_DIR/changelog-to-html.sh" ${CHANGELOG_ARGS[@]+"${CHANGELOG_ARGS[@]}"} "$VERSION" > "$tmp_notes"; then
  echo "write-appcast: refusing to write an appcast without release notes for $VERSION." >&2
  exit 1
fi
mv "$tmp_notes" "$notes"
echo "write-appcast: release notes -> $notes"

# ---- 2. generate_appcast ---------------------------------------------------
gen_appcast="$(command -v generate_appcast || true)"
[[ -z "$gen_appcast" && -n "${SPARKLE_BIN:-}" ]] && gen_appcast="$SPARKLE_BIN/generate_appcast"
if [[ -z "$gen_appcast" || ! -x "$gen_appcast" ]]; then
  echo "write-appcast: generate_appcast not found. Set SPARKLE_BIN to Sparkle's bin dir." >&2
  exit 1
fi

gen_args=(--embed-release-notes)
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && gen_args+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
"$gen_appcast" "${gen_args[@]}" "$DIST"

# ---- 3. verify -------------------------------------------------------------
appcast="$DIST/appcast.xml"
if [[ ! -s "$appcast" ]]; then
  echo "write-appcast: generate_appcast did not write $appcast." >&2
  exit 1
fi
if ! grep -q "$ARCHIVE_NAME" "$appcast"; then
  echo "write-appcast: $appcast has no entry for $ARCHIVE_NAME — appcast generation failed silently." >&2
  echo "               (Check for stale/duplicate artifacts in the dist dir.)" >&2
  exit 1
fi
description="$(xmllint --xpath \
  "string(//item[enclosure[contains(@url, '$ARCHIVE_NAME')]]/description)" \
  "$appcast" 2>/dev/null || true)"
if [[ -z "${description//[[:space:]]/}" ]]; then
  echo "write-appcast: the $ARCHIVE_NAME item in $appcast has no release notes (<description>)." >&2
  echo "               The Sparkle update dialog would be blank (item 114)." >&2
  exit 1
fi
echo "write-appcast: wrote $appcast (verified $ARCHIVE_NAME item embeds release notes)"
