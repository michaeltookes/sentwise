#!/usr/bin/env bash
# Build the Sentwise QA DMG (item 123; docs/qa-build.md).
#
# A QA build is the production code built with the "QA" configuration
# (Sentwise/Config/QA.xcconfig): bundle id com.tookes.Sentwise.qa, name
# "Sentwise QA", its own Keychain service, data folder, and URL scheme, pointed
# at the sandbox deployment of sentwise-service, the Clerk development instance,
# and the Paddle sandbox. It installs beside the production app.
#
# This script NEVER tags, publishes a release, writes an appcast, or bumps the
# Homebrew cask. Output goes to dist-qa/ (git-ignored), not dist/, so it can
# never be picked up by the release pipeline.
#
# Usage:
#   Distribution/scripts/qa-build.sh [--unsigned] [--notarize] [--require-checkout]
#
#   --unsigned          ad-hoc sign instead of Developer ID (no credentials)
#   --notarize          notarize + staple the app and the DMG (signed builds)
#   --require-checkout  fail unless the Clerk URL and all Paddle values are real sandbox values
#   --skip-dmg          stop after the staged app (no create-dmg, which drives Finder)
#
# The QA values not committed in QA.xcconfig come from (in order of precedence)
# these environment variables, passed as xcodebuild build settings when set, or
# from Sentwise/Config/QA.local.xcconfig (git-ignored):
#   SENTWISE_CLERK_FRONTEND_API_URL       Clerk development instance Frontend API URL
#   SENTWISE_PADDLE_CLIENT_TOKEN          Paddle sandbox client-side token (test_...)
#   SENTWISE_PADDLE_STARTER_PRICE_ID      Paddle sandbox price ids (pri_...)
#   SENTWISE_PADDLE_PRO_PRICE_ID
#   SENTWISE_PADDLE_UNLIMITED_PRICE_ID
#
# Signed builds use the same environment as release.sh: DEVELOPMENT_TEAM,
# SIGNING_IDENTITY, and for --notarize NOTARY_PROFILE or NOTARY_APPLE_ID /
# NOTARY_TEAM_ID / NOTARY_PASSWORD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="$REPO_ROOT/Sentwise/Sentwise.xcodeproj"
SCHEME="Sentwise"
APP_DISPLAY_NAME="Sentwise QA"
OUT="$REPO_ROOT/dist-qa"

UNSIGNED=0
NOTARIZE=0
REQUIRE_CHECKOUT=0
SKIP_DMG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned)         UNSIGNED=1; shift ;;
    --notarize)         NOTARIZE=1; shift ;;
    --require-checkout) REQUIRE_CHECKOUT=1; shift ;;
    --skip-dmg)         SKIP_DMG=1; shift ;;
    -h|--help)          sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "qa-build: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ "$UNSIGNED" -eq 1 && "$NOTARIZE" -eq 1 ]]; then
  echo "qa-build: --notarize needs a Developer ID signed build (drop --unsigned)." >&2
  exit 2
fi

# shellcheck source-path=SCRIPTDIR source=lib/qa-checkout-values.sh
source "$SCRIPT_DIR/lib/qa-checkout-values.sh"

log()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m### %s\033[0m\n' "$*"; }

# The version is defined once, in Version.xcconfig (inherited by every configuration).
version_xcconfig="$REPO_ROOT/Sentwise/Config/Version.xcconfig"
VERSION="$(grep -m1 -E '^[[:space:]]*MARKETING_VERSION = ' "$version_xcconfig" | sed 's/.*= //; s/;.*//; s/[[:space:]]*$//')"
SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
ARCHIVE="$OUT/SentwiseQA.xcarchive"
EXPORT_DIR="$OUT/export"
STAGE_DIR="$OUT/stage"
DMG="$OUT/Sentwise-QA-$VERSION-$SHA.dmg"

rm -rf "$OUT"
mkdir -p "$OUT"

# Pass the QA values given in the environment as build settings (they override
# QA.xcconfig and QA.local.xcconfig). Unset values are left to the xcconfigs.
settings=(MARKETING_VERSION="$VERSION")
for name in SENTWISE_CLERK_FRONTEND_API_URL SENTWISE_PADDLE_CLIENT_TOKEN \
  SENTWISE_PADDLE_STARTER_PRICE_ID SENTWISE_PADDLE_PRO_PRICE_ID SENTWISE_PADDLE_UNLIMITED_PRICE_ID; do
  if [[ -n "${!name:-}" ]]; then settings+=("$name=${!name}"); fi
done

step "Sentwise QA build  (version $VERSION, commit $SHA, unsigned=$UNSIGNED, notarize=$NOTARIZE)"

# ---- 1. archive the QA configuration ----------------------------------------
step "1/5  Archiving the QA configuration"
if [[ "$UNSIGNED" -eq 1 ]]; then
  xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration QA \
    -archivePath "$ARCHIVE" "${settings[@]}" CODE_SIGNING_ALLOWED=NO
else
  xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration QA \
    -archivePath "$ARCHIVE" "${settings[@]}" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
fi

# ---- 2. export ---------------------------------------------------------------
step "2/5  Exporting the app bundle"
mkdir -p "$EXPORT_DIR"
if [[ "$UNSIGNED" -eq 1 ]]; then
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
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT_DIR"
fi

# ---- 3. verify it is a QA build, not a production one ------------------------
step "3/5  Verifying the built Info.plist is a QA build"
plist="$EXPORT_DIR/Sentwise.app/Contents/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
fail=0
expect() {
  local key="$1" want="$2" got
  got="$(read_key "$key")"
  if [[ "$got" != "$want" ]]; then
    echo "qa-build: $key is '$got', expected '$want'" >&2
    fail=1
  fi
}
expect CFBundleIdentifier com.tookes.Sentwise.qa
expect CFBundleDisplayName "Sentwise QA"
expect "CFBundleURLTypes:0:CFBundleURLSchemes:0" sentwise-qa
expect SentwiseKeychainServiceSuffix .qa
expect SentwiseAppSupportDirectoryName "Sentwise QA"
expect SentwisePaddleEnvironment sandbox
service="$(read_key SentwiseServiceBaseURL)"
if ! service_problem="$(qa_url_problem SentwiseServiceBaseURL "$service" "$QA_PRODUCTION_SERVICE_HOST")"; then
  echo "qa-build: $service_problem; it must be the sandbox deployment" >&2
  fail=1
fi
[[ "$fail" -eq 0 ]] || exit 1

# Same rules as BuildConfiguration: placeholders, live tokens, production
# prices, and the production Clerk host all leave checkout unavailable.
if ! problems="$(qa_checkout_problems "$(read_key SentwiseClerkFrontendAPIURL)" \
  "$(read_key SentwisePaddleClientToken)" "$(read_key SentwisePaddleStarterPriceID)" \
  "$(read_key SentwisePaddleProPriceID)" "$(read_key SentwisePaddleUnlimitedPriceID)")"; then
  echo "qa-build: sign-in and/or checkout are unavailable in this build:" >&2
  printf '%s\n' "$problems" | sed 's/^/  /' >&2
  [[ "$REQUIRE_CHECKOUT" -eq 1 ]] && exit 1
fi
log "QA identity verified (service $service)"

# ---- 4. stage + notarize the app ----------------------------------------------
step "4/5  Staging \"$APP_DISPLAY_NAME.app\""
mkdir -p "$STAGE_DIR"
# Renaming the bundle directory does not touch the signed contents.
cp -R "$EXPORT_DIR/Sentwise.app" "$STAGE_DIR/$APP_DISPLAY_NAME.app"

notarize_submit() {
  local artifact="$1"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$artifact" --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  fi
}
if [[ "$NOTARIZE" -eq 1 ]]; then
  app_zip="$(mktemp -d)/SentwiseQA-app.zip"
  ditto -c -k --keepParent "$STAGE_DIR/$APP_DISPLAY_NAME.app" "$app_zip"
  notarize_submit "$app_zip"
  xcrun stapler staple "$STAGE_DIR/$APP_DISPLAY_NAME.app"
  rm -rf "$(dirname "$app_zip")"
fi

if [[ "$SKIP_DMG" -eq 1 ]]; then
  log "Staged app: $STAGE_DIR/$APP_DISPLAY_NAME.app (DMG skipped)"
  exit 0
fi

# ---- 5. DMG --------------------------------------------------------------------
step "5/5  Building the DMG"
"$SCRIPT_DIR/make-dmg.sh" "$STAGE_DIR/$APP_DISPLAY_NAME.app" "$DMG"
if [[ "$NOTARIZE" -eq 1 ]]; then
  notarize_submit "$DMG"
  xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG" > "$DMG.sha256"
log "QA DMG: $DMG"
