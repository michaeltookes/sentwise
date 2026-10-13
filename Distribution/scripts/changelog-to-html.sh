#!/usr/bin/env bash
#
# Extract one version's section from CHANGELOG.md and render it as an HTML
# fragment for the Sparkle update dialog (backlog item 114).
#
# The fragment is written next to the update archive as
# dist/Sentwise-<version>.html, where Sparkle's generate_appcast picks it up and
# embeds it as the appcast item's <description> (see write-appcast.sh).
#
# Usage:
#   changelog-to-html.sh [--changelog PATH] VERSION   # HTML fragment on stdout
#
# Exits non-zero (with a message on stderr) when CHANGELOG has no "## [VERSION]"
# section, or the section is empty — a release must never ship blank notes.
#
# Markdown support is the subset CHANGELOG.md actually uses (Keep a Changelog):
# ### / #### headings, "- " / "* " bullets with indented continuation lines,
# paragraphs, **bold**, *italic*, `code` (contents rendered literally), and
# [text](url) links. Link reference definitions ("[0.2.0]: https://…") are
# dropped. Text is HTML-escaped. No
# external dependencies (POSIX awk only), so it runs the same locally and on CI.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHANGELOG="$(cd "$SCRIPT_DIR/../.." && pwd)/CHANGELOG.md"
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changelog) CHANGELOG="${2:?--changelog needs a path}"; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "changelog-to-html: unknown option: $1" >&2; exit 2 ;;
    *)           VERSION="$1"; shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "changelog-to-html: usage: changelog-to-html.sh [--changelog PATH] VERSION" >&2
  exit 2
fi
if [[ ! -r "$CHANGELOG" ]]; then
  echo "changelog-to-html: cannot read $CHANGELOG" >&2
  exit 1
fi

html="$(awk -v ver="$VERSION" '
function esc(s) {
  gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
  return s
}
# Replace every delimited span matched by re. lt/rt = delimiter lengths.
function wrap(s, re, lt, rt, opn, cls,    out, inner) {
  out = ""
  while (match(s, re)) {
    inner = substr(s, RSTART + lt, RLENGTH - lt - rt)
    out = out substr(s, 1, RSTART - 1) opn inner cls
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
function links(s,    out, m, mid, text, url) {
  out = ""
  while (match(s, /\[[^\]]*\]\([^) ]*\)/)) {
    m = substr(s, RSTART, RLENGTH)
    mid = index(m, "](")
    text = substr(m, 2, mid - 2)
    url = substr(m, mid + 2, length(m) - mid - 2)
    out = out substr(s, 1, RSTART - 1) "<a href=\"" url "\">" text "</a>"
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
# Code spans are lifted out first (placeholder \001<n>\002) so that `*.vtt`,
# `**x**` or `[a](b)` inside backticks are rendered literally instead of being
# re-interpreted by the emphasis and link passes; they are put back, escaped,
# at the end. Placeholders are replaced with index/substr, never sub(), so an
# "&" in the escaped code can not be mangled.
function inline(s,    out, n, i, code, pos, ph) {
  n = 0; out = ""
  while (match(s, /`[^`]+`/)) {
    n++; code[n] = substr(s, RSTART + 1, RLENGTH - 2)
    out = out substr(s, 1, RSTART - 1) "\001" n "\002"
    s = substr(s, RSTART + RLENGTH)
  }
  s = esc(out s)
  s = wrap(s, "\\*\\*[^*]+\\*\\*", 2, 2, "<strong>", "</strong>")
  s = wrap(s, "\\*[^* ][^*]*\\*", 1, 1, "<em>", "</em>")
  s = links(s)
  for (i = 1; i <= n; i++) {
    ph = "\001" i "\002"
    pos = index(s, ph)
    if (pos > 0) s = substr(s, 1, pos - 1) "<code>" esc(code[i]) "</code>" substr(s, pos + length(ph))
  }
  return s
}
function flush() {
  if (buf != "") {
    if (inli) print "<li>" inline(buf) "</li>"
    else      print "<p>" inline(buf) "</p>"
  }
  buf = ""; inli = 0
}
function endlist() { flush(); if (inul) { print "</ul>"; inul = 0 } }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# Section boundaries: "## [X.Y.Z] - date" starts; the next "## " ends.
/^## / {
  if (grab) exit
  if (substr($0, 1, 4) == "## [" && substr($0, 5, index($0, "]") - 5) == ver) { grab = 1; found = 1 }
  next
}
!grab { next }
/^\[[^\]]+\]: / { next }                       # link reference definitions
/^[ \t]*$/ { endlist(); next }
/^####+ / { endlist(); h = $0; sub(/^#+ +/, "", h); print "<h4>" inline(h) "</h4>"; next }
/^### /   { endlist(); h = $0; sub(/^#+ +/, "", h); print "<h3>" inline(h) "</h3>"; next }
/^[-*]( |$)/ {                                  # bullet; a bare "-" is an empty one
  flush()
  if (!inul) { print "<ul>"; inul = 1 }
  buf = trim(substr($0, 3)); inli = 1
  next
}
/^[ \t]/ && inli { buf = buf " " trim($0); next }  # bullet continuation
{
  if (inul) endlist()
  buf = (buf == "") ? trim($0) : buf " " trim($0)
}
END {
  endlist()
  if (!found) exit 3
}
' "$CHANGELOG")" || rc=$?

if [[ "${rc:-0}" -eq 3 ]]; then
  echo "changelog-to-html: $CHANGELOG has no '## [$VERSION]' section." >&2
  echo "                   Write the release notes for $VERSION before releasing." >&2
  exit 1
elif [[ "${rc:-0}" -ne 0 ]]; then
  echo "changelog-to-html: awk failed (exit $rc) rendering $CHANGELOG" >&2
  exit 1
fi
# "Empty" means no readable note text, not just no HTML: a section holding only
# "### Added" / "### Fixed" headings or bare "- " bullets renders as headings
# and <ul></ul>, which Sparkle shows as a notes area with nothing under the
# headings. Heading text itself does not count.
text="$(printf '%s' "$html" | sed -E -e 's#<h[1-6]>.*</h[1-6]>##g' -e 's/<[^>]*>//g' | tr -d '[:space:]')"
if [[ -z "$text" ]]; then
  echo "changelog-to-html: the '## [$VERSION]' section of $CHANGELOG has no release-note text" >&2
  echo "                   (headings or bullets with nothing in them do not count)." >&2
  exit 1
fi
printf '%s\n' "$html"
