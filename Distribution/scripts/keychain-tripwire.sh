#!/usr/bin/env bash
#
# keychain-tripwire.sh — CI tripwire asserting a test run never touched the
# installed app's Keychain items (item 115).
#
# The Lucius self-hosted runner is also the Sentwise QA desktop, so the live
# test run executes in the same login keychain as the installed Developer ID
# app. A dev-signed test process rewriting any item under the production
# service `com.tookes.Sentwise` resets that item's ACL to trust the dev
# certificate instead, which locks the installed app behind a securityd
# login-keychain password prompt (the 2026-10-11 incident). Tests are isolated
# onto `com.tookes.Sentwise.tests` (SENTWISE_TEST_KEYCHAIN=1); this script is
# the independent assertion that the isolation holds.
#
# Usage:
#   keychain-tripwire.sh snapshot <state-file>   # before the test run
#   keychain-tripwire.sh verify   <state-file>   # after the test run
#
# `snapshot` records, for each known account name under the production
# service, whether the item exists and its modification date (mdat). `verify`
# re-reads the same attributes and fails (exit 1) if any item appeared,
# disappeared, or changed mdat since the snapshot.
#
# Privacy: `security find-generic-password` is called WITHOUT -g/-w, so item
# attributes only — never a secret value — are read, stored, or printed. The
# state file and all output hold account names and timestamps only.
#
# Scope: generic-password items are enumerated by known account name (a
# `security dump-keychain` would be far heavier and noisier). Per-account mail
# passwords (`mail.appPassword.<email>`) have dynamic names and are not
# enumerable this way; they are not Clerk/managed items and were not part of
# the incident class. Keep the list in sync with the well-known keys in
# Sentwise/Sentwise/Services/SecretStore.swift.

set -euo pipefail

SERVICE="com.tookes.Sentwise"

# Known account names: the static SecretKey raw values plus the per-provider
# LLM key slots (LLMProviderKind raw values and the OpenRouter slot).
ACCOUNTS=(
  gmail.token
  mail.appPassword
  google.clientID
  google.clientSecret
  managed.clientToken
  managed.sessionID
  managed.credentialsInvalidated
  managed.clerkFrontendAPIBaseURL
  managed.reauthenticationClientToken
  managed.oauthSignInID
  managed.oauthMessageSurface
  managed.oauthFlowID
  managed.oauthCanceledCallbackSurface
  openRouter.pkceVerifier
  openRouter.pkceMessageSurface
  openRouter.pkceFlowID
  openRouter.canceledCallbackSurface
  llm.managed.apiKey
  llm.anthropic.apiKey
  llm.openAICompatible.apiKey
  llm.ollama.apiKey
  llm.openRouter.apiKey
)

MODE="${1:-}"
STATE_FILE="${2:-}"

if [[ -z "$MODE" || -z "$STATE_FILE" ]]; then
  echo "usage: keychain-tripwire.sh <snapshot|verify> <state-file>" >&2
  exit 2
fi

# Prints "<account><TAB><state>" per account, where <state> is ABSENT or the
# item's mdat timestamp (e.g. 20261011182920Z). Attributes only — no -g/-w, so
# no secret value is ever read.
#
# Only errSecItemNotFound (exit 44) means ABSENT. Any other failure (locked or
# unavailable keychain, errSecInteractionNotAllowed 36, a Security Server
# error) aborts with exit 3: a tripwire that cannot read the items must fail
# closed, or two failed passes would compare equal and certify isolation that
# was never checked.
capture_state() {
  local account attrs mdat rc
  for account in "${ACCOUNTS[@]}"; do
    rc=0
    attrs=$(security find-generic-password -s "$SERVICE" -a "$account" 2>/dev/null) || rc=$?
    if [[ $rc -eq 0 ]]; then
      # The mdat attribute line looks like:
      #     "mdat"<timedate>=0x... "20261011182920Z\000"
      mdat=$(printf '%s\n' "$attrs" | sed -nE 's/.*"mdat".*"([0-9]{14}Z).*/\1/p' | head -1)
      printf '%s\t%s\n' "$account" "${mdat:-PRESENT-NO-MDAT}"
    elif [[ $rc -eq 44 ]]; then
      printf '%s\t%s\n' "$account" "ABSENT"
    else
      echo "error: Keychain lookup for account '$account' (service $SERVICE) failed with" >&2
      echo "       security exit status $rc (not item-not-found). Refusing to record a" >&2
      echo "       state the tripwire could not actually read." >&2
      return 3
    fi
  done
}

case "$MODE" in
  snapshot)
    if ! capture_state > "$STATE_FILE"; then
      rm -f "$STATE_FILE"
      exit 3
    fi
    echo "Snapshotted ${#ACCOUNTS[@]} production Keychain item states (service $SERVICE) to $STATE_FILE"
    ;;
  verify)
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "error: snapshot state file not found: $STATE_FILE" >&2
      exit 2
    fi
    current=$(capture_state) || exit 3
    if diff_output=$(diff -u "$STATE_FILE" <(printf '%s\n' "$current")); then
      echo "Keychain tripwire OK: no item under service $SERVICE changed during the test run."
    else
      echo "KEYCHAIN TRIPWIRE FAILED: the test run modified items under the" >&2
      echo "installed app's Keychain service ($SERVICE). Test isolation has" >&2
      echo "regressed (item 115) — the installed QA app's items may now carry" >&2
      echo "a dev-signed ACL and prompt for the login keychain password." >&2
      echo "Changed items (account names + mdat timestamps only):" >&2
      printf '%s\n' "$diff_output" >&2
      exit 1
    fi
    ;;
  *)
    echo "error: unknown mode '$MODE' (expected snapshot or verify)" >&2
    exit 2
    ;;
esac
