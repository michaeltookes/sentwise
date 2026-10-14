#!/usr/bin/env bash
#
# Sentwise release pipeline.
#
#   release-notes pre-flight -> archive -> export (Developer ID) ->
#   notarize+staple app -> DMG -> notarize+staple DMG -> launch smoke test ->
#   appcast (with embedded CHANGELOG release notes) -> checksums
#
# Everything credential-related comes from the environment (nothing is
# hardcoded or stored in the repo). A --dry-run mode exercises the whole
# archive -> DMG -> launch-smoke-test path WITHOUT any credentials so the
# pipeline is testable now, locally and on CI.
#
# The SAME script drives the local/manual release (via the release-prep skill)
# and CI (.github/workflows/release.yml) — CI just supplies credentials from
# encrypted secrets. There is deliberately no second pipeline.
#
# Full runbook and prerequisites: docs/releasing.md and docs/ci-release.md
#
# Usage:
#   release.sh --dry-run [--version X.Y.Z] [--build N]
#   release.sh [--version X.Y.Z] [--build N]        # full signed release
#   release.sh --clean-dist ...                     # remove stale dist/ artifacts first
#
# Environment (required for a full signed release, ignored by --dry-run):
#   SIGNING_IDENTITY   Developer ID Application identity, e.g.
#                      "Developer ID Application: Your Name (TEAMID)"
#   DEVELOPMENT_TEAM   10-char Apple Developer Team ID
#   Notarization credentials — supply EITHER:
#     NOTARY_PROFILE   notarytool keychain profile name (local; see releasing.md)
#   OR the three flag-based values (CI; no Keychain profile available):
#     NOTARY_APPLE_ID  Apple ID email
#     NOTARY_TEAM_ID   Apple Team ID
#     NOTARY_PASSWORD  app-specific password
# Optional:
#   SPARKLE_BIN         directory holding Sparkle's generate_appcast / sign_update
#                       (defaults to searching PATH). Needed for the appcast step.
#   SPARKLE_ED_KEY_FILE path to a file holding the EdDSA private key; when set it
#                       is passed to generate_appcast via --ed-key-file (CI path,
#                       where there is no login Keychain). When unset,
#                       generate_appcast reads the key from the login Keychain
#                       (local path).
#
set -euo pipefail

# ---- loud failures ---------------------------------------------------------
# Every step's failure must fail the script. set -e handles non-zero exits; this
# ERR trap makes the failure LOUD by naming the command and line that failed
# (the v0.1.0 release exited 0 while a step had quietly failed).
err_trap() {
  local rc=$?
  printf '\033[1;31m==> release FAILED (exit %s) at line %s: %s\033[0m\n' \
    "$rc" "${BASH_LINENO[0]}" "$BASH_COMMAND" >&2
}
trap err_trap ERR

# ---- paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"            # Distribution/
REPO_ROOT="$(cd "$DIST_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/Sentwise/Sentwise.xcodeproj"
SCHEME="Sentwise"
APP_DISPLAY_NAME="Sentwise"                     # DMG icon label / volume name
OUT="$REPO_ROOT/dist"                               # gitignored artifact dir

# ---- args ------------------------------------------------------------------
DRY_RUN=0
CLEAN_DIST=0
VERSION=""
BUILD=""

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --clean-dist) CLEAN_DIST=1; shift ;;
    --version)    VERSION="${2:?}"; shift 2 ;;
    --build)      BUILD="${2:?}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "release: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# The version is defined once, in Version.xcconfig (inherited by every configuration).
version_xcconfig="$REPO_ROOT/Sentwise/Config/Version.xcconfig"
[[ -z "$VERSION" ]] && VERSION="$(grep -m1 -E '^[[:space:]]*MARKETING_VERSION = ' "$version_xcconfig" | sed 's/.*= //; s/;.*//; s/[[:space:]]*$//')"
[[ -z "$BUILD"   ]] && BUILD="$(grep -m1 -E '^[[:space:]]*CURRENT_PROJECT_VERSION = ' "$version_xcconfig" | sed 's/.*= //; s/;.*//; s/[[:space:]]*$//')"

log()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m### %s\033[0m\n' "$*"; }

ARCHIVE="$OUT/Sentwise.xcarchive"
EXPORT_DIR="$OUT/export"
STAGE_DIR="$OUT/stage"
DMG="$OUT/Sentwise-$VERSION.dmg"
DMG_NAME="$(basename "$DMG")"

# Legacy all-zero SUPublicEDKey placeholder from before the v0.1.0 Sparkle
# keypair was established. Signed releases must use the private key matching the
# public key already committed in Info.plist; this guard only prevents shipping
# an empty or legacy verifier in the built app.
PLACEHOLDER_EDKEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

step "Sentwise release  (version $VERSION, build $BUILD, dry-run=$DRY_RUN)"

# ---- 0. stale-dist guard ---------------------------------------------------
# generate_appcast scans the ENTIRE dist/ dir for update archives (*.dmg / *.zip
# / *.pkg). A leftover DMG from another version — e.g. a prior dry-run — with a
# duplicate bundle version silently broke appcast generation for v0.1.0. Refuse
# to build on top of a dirty dist/ unless --clean-dist is given.
mkdir -p "$OUT"
stale=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  base="$(basename "$f")"
  [[ "$base" == "$DMG_NAME" ]] && continue        # this run overwrites its own DMG
  stale+=("$f")
done < <(find "$OUT" -maxdepth 1 -type f \( -name '*.dmg' -o -name '*.zip' -o -name '*.pkg' \) 2>/dev/null)

if [[ ${#stale[@]} -gt 0 ]]; then
  if [[ "$CLEAN_DIST" -eq 1 ]]; then
    log "Removing ${#stale[@]} stale dist artifact(s):"
    for f in "${stale[@]}"; do echo "    rm $f"; rm -f "$f" "$f.sha256" "${f%.*}.html"; done
  else
    {
      echo "release: dist/ contains artifacts from another version:"
      for f in "${stale[@]}"; do echo "    $f"; done
      echo "These would corrupt appcast generation (duplicate bundle versions)."
      echo "Re-run with --clean-dist to remove them, or clear dist/ by hand."
    } >&2
    exit 1
  fi
fi

# Always start the build stages from clean archive/export/stage dirs.
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGE_DIR"

# ---- release-notes pre-flight ----------------------------------------------
# Every appcast item embeds the version's CHANGELOG.md section so the Sparkle
# update dialog shows what changed (item 114: 0.2.0 shipped with a blank one).
# Check it BEFORE the long archive/notarize steps: a signed release with no
# '## [VERSION]' section fails here. A dry run only warns, so layout testing
# still works mid-cycle; the rendered notes land in dist/ for inspection.
NOTES_HTML="$OUT/${DMG_NAME%.dmg}.html"
if "$SCRIPT_DIR/changelog-to-html.sh" "$VERSION" > "$NOTES_HTML.tmp"; then
  mv "$NOTES_HTML.tmp" "$NOTES_HTML"
  log "Release notes for $VERSION rendered from CHANGELOG.md -> $NOTES_HTML"
else
  rm -f "$NOTES_HTML.tmp"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "WARNING: no CHANGELOG.md section for $VERSION; a signed release would abort here."
  else
    echo "release: CHANGELOG.md has no usable '## [$VERSION]' section — refusing to ship" >&2
    echo "         an update with blank Sparkle release notes. Write the section first." >&2
    exit 1
  fi
fi

# ---- credential pre-flight (signed only) -----------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
  : "${SIGNING_IDENTITY:?set SIGNING_IDENTITY (Developer ID Application: …)}"
  : "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (Apple Team ID)}"
  if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    : "${NOTARY_APPLE_ID:?set NOTARY_PROFILE, or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD}"
    : "${NOTARY_TEAM_ID:?set NOTARY_TEAM_ID (or use NOTARY_PROFILE)}"
    : "${NOTARY_PASSWORD:?set NOTARY_PASSWORD (or use NOTARY_PROFILE)}"
  fi
fi

# notarytool submit, using whichever credential style is configured.
notarize_submit() {
  local artifact="$1"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$artifact" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --wait
  fi
}

# ---- launch smoke test -----------------------------------------------------
# Mandatory gate. v0.1.0 shipped notarized, Gatekeeper-accepted and 905 tests
# green yet crashed instantly at launch (missing LD_RUNPATH_SEARCH_PATHS) —
# signatures and unit tests validate a binary without ever executing it. Mount
# the FINAL DMG, (signed only) assess it with spctl, launch the app, confirm the
# process is still alive after a few seconds, then kill and detach. Hard-fails if
# the process is not running.
smoke_test() {
  local dmg="$1"
  local mnt app exe rc=0
  mnt="$(mktemp -d /tmp/sentwise-smoke.XXXXXX)"
  log "Mounting $dmg for launch smoke test"
  hdiutil attach "$dmg" -nobrowse -noverify -mountpoint "$mnt" >/dev/null

  app="$mnt/$APP_DISPLAY_NAME.app"
  exe="$app/Contents/MacOS/$APP_DISPLAY_NAME"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    if spctl --assess --type execute -vv "$app"; then
      log "spctl assessment: accepted"
    else
      echo "release: spctl assessment REJECTED the app in the DMG" >&2
      rc=1
    fi
  else
    log "spctl assessment — SKIPPED (dry-run app is ad-hoc signed, not notarized)"
  fi

  if [[ $rc -eq 0 ]]; then
    log "Launching app from the mounted DMG"
    if open -n "$app"; then
      sleep 5
      if pgrep -f "$exe" >/dev/null 2>&1; then
        log "Launch smoke test PASSED — process alive 5s after launch"
        pkill -f "$exe" >/dev/null 2>&1 || true
      else
        echo "release: LAUNCH SMOKE TEST FAILED — process not running 5s after launch (dyld/startup crash)" >&2
        rc=1
      fi
    else
      echo "release: LAUNCH SMOKE TEST FAILED — 'open' could not launch the app" >&2
      rc=1
    fi
  fi

  # Always unmount, even on failure.
  hdiutil detach "$mnt" -quiet 2>/dev/null \
    || hdiutil detach "$mnt" -force -quiet 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
  return $rc
}

# ---- 1. archive ------------------------------------------------------------
step "1/7  Archiving Release"
# "Sign in with Google" client (item 104, docs/gmail-oauth.md): passed through
# only when set, so an unset variable never overrides a local
# Sentwise/Config/GoogleOAuth.local.xcconfig. Neither set => feature off.
GOOGLE_OAUTH_SETTINGS=()
if [[ -n "${SENTWISE_GOOGLE_CLIENT_ID:-}" ]]; then
  GOOGLE_OAUTH_SETTINGS+=("SENTWISE_GOOGLE_CLIENT_ID=$SENTWISE_GOOGLE_CLIENT_ID")
fi
if [[ -n "${SENTWISE_GOOGLE_CLIENT_SECRET:-}" ]]; then
  GOOGLE_OAUTH_SETTINGS+=("SENTWISE_GOOGLE_CLIENT_SECRET=$SENTWISE_GOOGLE_CLIENT_SECRET")
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    ${GOOGLE_OAUTH_SETTINGS[@]+"${GOOGLE_OAUTH_SETTINGS[@]}"} \
    CODE_SIGNING_ALLOWED=NO
else
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    ${GOOGLE_OAUTH_SETTINGS[@]+"${GOOGLE_OAUTH_SETTINGS[@]}"} \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
fi

# ---- 2. export a distributable .app ----------------------------------------
step "2/7  Exporting app bundle"
mkdir -p "$EXPORT_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  # No Developer ID signing: lift the .app straight out of the archive, then
  # ad-hoc sign it so it can execute on Apple Silicon (required for the launch
  # smoke test — an unsigned arm64 binary is killed by the kernel).
  cp -R "$ARCHIVE/Products/Applications/Sentwise.app" "$EXPORT_DIR/Sentwise.app"
  codesign --force --deep --sign - "$EXPORT_DIR/Sentwise.app"
else
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR"
fi

# ---- 2b. guard the update-signing key --------------------------------------
# Validate what actually SHIPS (the built app's merged Info.plist), not the
# source plist. A signed release with the legacy placeholder key would install fine
# but never accept an update, so this is a hard stop for real releases.
built_edkey="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  "$EXPORT_DIR/Sentwise.app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$built_edkey" == "$PLACEHOLDER_EDKEY" || -z "$built_edkey" ]]; then
    log "NOTE: SUPublicEDKey is empty or still the legacy placeholder; a real signed release would abort here."
  fi
else
  if [[ -z "$built_edkey" || "$built_edkey" == "$PLACEHOLDER_EDKEY" ]]; then
    echo "release: SUPublicEDKey is empty or still the legacy placeholder in the built app." >&2
    echo "         Keep the committed v0.1.0 public key in Sentwise/Info.plist and" >&2
    echo "         sign appcasts with the matching private key. See docs/releasing.md." >&2
    exit 1
  fi
  log "SUPublicEDKey verified present (non-placeholder)"
fi

# ---- 3. stage under the branded name ---------------------------------------
step "3/7  Staging \"$APP_DISPLAY_NAME.app\""
mkdir -p "$STAGE_DIR"
cp -R "$EXPORT_DIR/Sentwise.app" "$STAGE_DIR/$APP_DISPLAY_NAME.app"

# ---- 4. notarize + staple the APP (signed only) ----------------------------
# Staple the ticket to the .app BEFORE it goes into the DMG, so the app itself
# is independently notarized/stapled (not only the DMG). notarytool cannot take
# a raw .app, so submit a throwaway zip; the ticket is then stapled onto the app
# bundle. The zip lives outside dist/ so generate_appcast never sees it.
if [[ "$DRY_RUN" -eq 1 ]]; then
  step "4/7  Notarize + staple app — SKIPPED (dry-run)"
else
  step "4/7  Notarizing + stapling the app bundle"
  app_zip="$(mktemp -d)/Sentwise-app.zip"
  ditto -c -k --keepParent "$STAGE_DIR/$APP_DISPLAY_NAME.app" "$app_zip"
  notarize_submit "$app_zip"
  log "Stapling ticket to $APP_DISPLAY_NAME.app"
  xcrun stapler staple "$STAGE_DIR/$APP_DISPLAY_NAME.app"
  xcrun stapler validate "$STAGE_DIR/$APP_DISPLAY_NAME.app"
  rm -rf "$(dirname "$app_zip")"
fi

# ---- 5. build the DMG ------------------------------------------------------
step "5/7  Building DMG"
"$SCRIPT_DIR/make-dmg.sh" "$STAGE_DIR/$APP_DISPLAY_NAME.app" "$DMG"

# ---- 5b. notarize + staple the DMG (signed only) ---------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Notarize + staple DMG — SKIPPED (dry-run)"
else
  step "5b/7  Notarizing + stapling the DMG"
  notarize_submit "$DMG"
  log "Stapling ticket to the DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# ---- 6. launch smoke test (both modes) -------------------------------------
step "6/7  Launch smoke test (mount, assess, launch, verify alive)"
smoke_test "$DMG"

# ---- 7. appcast + checksums ------------------------------------------------
step "7/7  Appcast + checksums"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Appcast — SKIPPED (dry-run; needs the EdDSA private key)"
else
  # write-appcast.sh re-renders the CHANGELOG notes next to the DMG, runs
  # generate_appcast --embed-release-notes over $OUT (signing every archive;
  # SPARKLE_BIN / SPARKLE_ED_KEY_FILE pass through from the environment), and
  # fails loudly unless appcast.xml references the DMG AND its item carries a
  # non-empty <description> (the release notes).
  "$SCRIPT_DIR/write-appcast.sh" --dist "$OUT" --version "$VERSION" --archive "$DMG_NAME"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

step "Done"
log "DMG:       $DMG"
[[ "$DRY_RUN" -eq 0 ]] && log "Appcast:   $OUT/appcast.xml"
[[ -f "$NOTES_HTML" ]] && log "Notes:     $NOTES_HTML (embedded in the appcast item)"
log "Checksums: $DMG.sha256"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  log "Dry run complete — unsigned, un-notarized artifact for layout testing only."
fi
