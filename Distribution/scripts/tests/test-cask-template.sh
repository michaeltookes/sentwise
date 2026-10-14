#!/usr/bin/env bash
# Guards the Homebrew cask template (Distribution/sentwise.rb) that the release
# workflow copies into michaeltookes/homebrew-tap on every tagged release.
#
# - `depends_on macos:` must use the bare-symbol form (`:sonoma`, meaning
#   "this version or newer"). The string-comparison form (`">= :sonoma"`) is
#   deprecated by Homebrew and prints a warning on every `brew install`.
# - The symbol must match the app's MACOSX_DEPLOYMENT_TARGET.
# - The release workflow's version/sha256 stamping must leave that line intact.
# Never installs anything; the optional Homebrew check only parses the value.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
CASK="$REPO_ROOT/Distribution/sentwise.rb"
PBXPROJ="$REPO_ROOT/Sentwise/Sentwise.xcodeproj/project.pbxproj"

fail() { echo "FAIL: $*" >&2; exit 1; }

depends_lines=$(grep -E '^[[:space:]]*depends_on[[:space:]]+macos:' "$CASK" || true)
[ "$(printf '%s\n' "$depends_lines" | grep -c .)" -eq 1 ] \
  || fail "expected exactly one 'depends_on macos:' line in $CASK, got: '$depends_lines'"

if printf '%s' "$depends_lines" | grep -q '"'; then
  fail "deprecated string-comparison form in cask: $depends_lines (use 'depends_on macos: :<codename>')"
fi

symbol=$(printf '%s' "$depends_lines" | sed -nE 's/^[[:space:]]*depends_on[[:space:]]+macos:[[:space:]]+:([a-z_]+)[[:space:]]*$/\1/p')
[ -n "$symbol" ] || fail "could not parse a bare macOS symbol from: $depends_lines"

targets=$(sed -nE 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);/\1/p' "$PBXPROJ" | sort -u)
[ "$(printf '%s\n' "$targets" | grep -c .)" -eq 1 ] \
  || fail "expected one MACOSX_DEPLOYMENT_TARGET in $PBXPROJ, got: $targets"
major=${targets%%.*}

case "$major" in
  13) expected=ventura ;;
  14) expected=sonoma ;;
  15) expected=sequoia ;;
  26) expected=tahoe ;;
  *) fail "no codename mapping for deployment target $targets; extend this test" ;;
esac
[ "$symbol" = "$expected" ] \
  || fail "cask requires :$symbol but MACOSX_DEPLOYMENT_TARGET $targets is :$expected"

# Replay the release workflow's stamping (same sed expressions as
# .github/workflows/release.yml, using whichever sed is on PATH).
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$CASK" "$TMP/sentwise.rb"
sed -E "s/^  version \".*\"/  version \"9.9.9\"/" "$TMP/sentwise.rb" \
  | sed -E "s/^  sha256 \".*\"/  sha256 \"$(printf 'a%.0s' $(seq 64))\"/" > "$TMP/stamped.rb"
grep -q '^  version "9.9.9"$' "$TMP/stamped.rb" || fail "version stamp did not apply"
grep -qE '^  sha256 "a{64}"$' "$TMP/stamped.rb" || fail "sha256 stamp did not apply"
grep -qxF "$depends_lines" "$TMP/stamped.rb" || fail "stamping altered the depends_on line"

# Optional: ask Homebrew itself to parse the value and confirm no deprecation.
if command -v brew >/dev/null 2>&1; then
  out=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew ruby -e \
    "require 'requirements/macos_requirement'; MacOSRequirement.parse([:$symbol], comparator: '>=')" 2>&1) \
    || fail "brew could not parse :$symbol: $out"
  if printf '%s' "$out" | grep -qi deprecat; then
    fail "Homebrew reports a deprecation for depends_on macos: :$symbol: $out"
  fi
  echo "brew parse check: ok"
fi

echo "cask template: ok (depends_on macos: :$symbol, deployment target $targets)"
