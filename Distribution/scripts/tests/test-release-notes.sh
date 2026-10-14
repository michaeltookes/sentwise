#!/usr/bin/env bash
#
# Tests for the release-notes step of the release pipeline (backlog item 114):
# changelog-to-html.sh (CHANGELOG section -> HTML fragment) and
# write-appcast.sh (notes embedded in the appcast item), run against a fixture
# CHANGELOG and a fixture dist dir — no real build, signing, or upload.
#
# Usage:
#   Distribution/scripts/tests/test-release-notes.sh
#
# The appcast cases need Sparkle's generate_appcast (SPARKLE_BIN or PATH; use
# the same pinned 2.9.5 bin/ as CI). Without it they are SKIPPED with a notice;
# set REQUIRE_SPARKLE=1 to make a missing generate_appcast a failure.
#
# "check && ok || bad" is intentional: ok() always succeeds, so bad() only runs on a failed check.
# shellcheck disable=SC2015
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
TO_HTML="$SCRIPTS/changelog-to-html.sh"
WRITE_APPCAST="$SCRIPTS/write-appcast.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sentwise-notes-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }
skp()  { skip=$((skip + 1)); printf '  SKIP  %s\n' "$1"; }
has()  { [[ "$1" == *"$2"* ]]; }

# ---- fixture CHANGELOG -----------------------------------------------------
CL="$WORK/CHANGELOG.md"
cat > "$CL" <<'MD'
# Changelog

All notable changes are documented here.

## [Unreleased]

- Not shipped yet.

## [9.9.9] - 2026-10-11

Intro paragraph with a [link](https://example.com/a?b=1&c=2) & an <angle>.

### Added

- **Bold lead** — first bullet with `inline code`
  continued on an indented line.
- An *emphasized* word.
- See [open issues](https://example.com/?q="bug"&x=1) for "known" gaps.
- Accepts `*.vtt` and `*.srt` files, plus `**not bold**`, `[not](a-link)` and `a & b`.

### Fixed

- A fix.

## [9.9.8] - 2026-10-01

### Fixed

- Older release only.

## [9.9.7] - 2026-09-01

## [9.9.6] - 2026-08-01

### **Added**

-

### Fixed

[9.9.9]: https://github.com/example/compare/v9.9.8...v9.9.9
[9.9.8]: https://github.com/example/compare/v9.9.7...v9.9.8
MD

echo "changelog-to-html.sh"

out="$("$TO_HTML" --changelog "$CL" 9.9.9)"
has "$out" '<p>Intro paragraph with a <a href="https://example.com/a?b=1&amp;c=2">link</a> &amp; an &lt;angle&gt;.</p>' \
  && ok "paragraph: link, & and <> escaped" || bad "paragraph: link, & and <> escaped" "$out"
has "$out" '<h3>Added</h3>' && has "$out" '<h3>Fixed</h3>' \
  && ok "### headings -> <h3>" || bad "### headings -> <h3>" "$out"
has "$out" '<li><strong>Bold lead</strong> — first bullet with <code>inline code</code> continued on an indented line.</li>' \
  && ok "bullet: bold, code, continuation line joined" || bad "bullet: bold, code, continuation line joined" "$out"
has "$out" '<li>An <em>emphasized</em> word.</li>' \
  && ok "bullet: *emphasis*" || bad "bullet: *emphasis*" "$out"
has "$out" '<li>Accepts <code>*.vtt</code> and <code>*.srt</code> files, plus <code>**not bold**</code>, <code>[not](a-link)</code> and <code>a &amp; b</code>.</li>' \
  && ok "bullet: markdown inside code spans stays literal" || bad "bullet: markdown inside code spans stays literal" "$out"
has "$out" '<li>See <a href="https://example.com/?q=&quot;bug&quot;&amp;x=1">open issues</a> for &quot;known&quot; gaps.</li>' \
  && ok "bullet: quotes in link url escaped in href, link text intact" || bad "bullet: quotes in link url escaped in href, link text intact" "$out"
[[ "$(grep -c '<ul>' <<< "$out")" -eq 2 && "$(grep -c '</ul>' <<< "$out")" -eq 2 ]] \
  && ok "lists opened and closed per section" || bad "lists opened and closed per section" "$out"
! has "$out" 'Older release only' && ! has "$out" 'Not shipped yet' \
  && ok "only the requested version's section" || bad "only the requested version's section" "$out"

out="$("$TO_HTML" --changelog "$CL" 9.9.8)"
has "$out" '<li>Older release only.</li>' && ! has "$out" 'A fix.' \
  && ok "middle section sliced at the next ## heading" || bad "middle section sliced at the next ## heading" "$out"

if err="$("$TO_HTML" --changelog "$CL" 1.2.3 2>&1)"; then
  bad "missing version fails" "$err"
else
  has "$err" "no '## [1.2.3]' section" && ok "missing version fails loudly" || bad "missing version fails loudly" "$err"
fi

if err="$("$TO_HTML" --changelog "$CL" 9.9.7 2>&1)"; then
  bad "empty section (only link refs) fails" "$err"
else
  has "$err" "no release-note text" && ok "empty section (only link refs) fails loudly" || bad "empty section (only link refs) fails loudly" "$err"
fi

if err="$("$TO_HTML" --changelog "$CL" 9.9.6 2>&1)"; then
  bad "markup-only section (empty headings/bullets) fails" "$err"
else
  has "$err" "no release-note text" && ok "markup-only section (empty headings/bullets) fails loudly" || bad "markup-only section (empty headings/bullets) fails loudly" "$err"
fi

# Version strings are matched literally, not as regexes ("9.9.9" != "9x9x9").
if "$TO_HTML" --changelog "$CL" 9x9x9 >/dev/null 2>&1; then
  bad "version matched literally"
else
  ok "version matched literally"
fi

# Real CHANGELOG renders for every released version (guards format drift).
repo_cl="$(cd "$SCRIPTS/../.." && pwd)/CHANGELOG.md"
while IFS= read -r v; do
  # Capture first: piping into grep -q under pipefail flakes (SIGPIPE).
  if rendered="$("$TO_HTML" --changelog "$repo_cl" "$v")" && has "$rendered" '<li>'; then
    ok "repo CHANGELOG $v renders"
  else
    bad "repo CHANGELOG $v renders"
  fi
done < <(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "$repo_cl")

# ---- write-appcast.sh against a fixture dist dir ---------------------------
echo "write-appcast.sh"

gen="$(command -v generate_appcast || true)"
[[ -z "$gen" && -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN/generate_appcast" ]] && gen="$SPARKLE_BIN/generate_appcast"

if [[ -z "$gen" ]]; then
  if [[ "${REQUIRE_SPARKLE:-0}" == "1" ]]; then
    bad "generate_appcast available (REQUIRE_SPARKLE=1; set SPARKLE_BIN)"
  else
    skp "appcast cases — generate_appcast not found (set SPARKLE_BIN to Sparkle 2.9.5 bin/)"
  fi
else
  export SPARKLE_BIN; SPARKLE_BIN="$(dirname "$gen")"

  # Throwaway EdDSA key (random 32-byte seed) — never the release key.
  key="$WORK/ed-key"
  head -c 32 /dev/urandom | base64 > "$key"
  export SPARKLE_ED_KEY_FILE="$key"

  make_dist() {  # $1 = dist dir; minimal app bundle zipped as the update archive
    local dist="$1" app="$WORK/app-src/Sentwise.app"
    rm -rf "$WORK/app-src"; mkdir -p "$app/Contents/MacOS" "$dist"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.tookes.Sentwise.release-notes-fixture</string>
  <key>CFBundleName</key><string>Sentwise</string>
  <key>CFBundleExecutable</key><string>Sentwise</string>
  <key>CFBundleVersion</key><string>99</string>
  <key>CFBundleShortVersionString</key><string>9.9.9</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
    printf '#!/bin/sh\n' > "$app/Contents/MacOS/Sentwise"
    chmod +x "$app/Contents/MacOS/Sentwise"
    (cd "$WORK/app-src" && ditto -c -k --keepParent Sentwise.app "$dist/Sentwise-9.9.9.zip")
  }

  dist="$WORK/dist-ok"; make_dist "$dist"
  if log="$("$WRITE_APPCAST" --dist "$dist" --version 9.9.9 --archive Sentwise-9.9.9.zip --changelog "$CL" 2>&1)"; then
    ok "write-appcast succeeds on fixture dist"
    desc="$(xmllint --xpath "string(//item[enclosure[contains(@url,'Sentwise-9.9.9.zip')]]/description)" "$dist/appcast.xml")"
    has "$desc" '<h3>Added</h3>' && has "$desc" '<strong>Bold lead</strong>' && has "$desc" '<li>A fix.</li>' \
      && ok "appcast item <description> embeds the 9.9.9 notes" || bad "appcast item <description> embeds the 9.9.9 notes" "$(cat "$dist/appcast.xml")"
    ! has "$desc" 'Older release only' \
      && ok "appcast notes exclude other versions" || bad "appcast notes exclude other versions" "$desc"
    [[ -f "$dist/Sentwise-9.9.9.html" ]] \
      && ok "notes file written next to the archive" || bad "notes file written next to the archive"
  else
    bad "write-appcast succeeds on fixture dist" "$log"
  fi

  dist="$WORK/dist-missing"; make_dist "$dist"
  if log="$("$WRITE_APPCAST" --dist "$dist" --version 1.2.3 --archive Sentwise-9.9.9.zip --changelog "$CL" 2>&1)"; then
    bad "write-appcast fails when CHANGELOG lacks the version" "$log"
  else
    has "$log" "refusing to write an appcast without release notes" \
      && ok "write-appcast fails loudly when CHANGELOG lacks the version" || bad "write-appcast fails loudly when CHANGELOG lacks the version" "$log"
    [[ ! -e "$dist/appcast.xml" && ! -e "$dist/Sentwise-9.9.9.html" ]] \
      && ok "no appcast or notes left behind on failure" || bad "no appcast or notes left behind on failure"
  fi
fi

echo
echo "release-notes tests: $pass passed, $fail failed, $skip skipped"
[[ "$fail" -eq 0 ]]
