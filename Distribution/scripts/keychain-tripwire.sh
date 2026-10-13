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
#   keychain-tripwire.sh snapshot <state-file> [keychain]  # before the test run
#   keychain-tripwire.sh verify   <state-file> [keychain]  # after the test run
#
# `snapshot` enumerates every generic-password item under the production
# service, including dynamic mail.appPassword.<email> accounts, and records
# its account and modification date (mdat). `verify` enumerates again and
# fails (exit 1) if any item appeared, disappeared, or changed mdat.
#
# Privacy: the Swift helper requests attributes only from SecItemCopyMatching,
# never password data. The state file and diff contain only service/account
# names and timestamps, JSON-escaped so unusual account names stay unambiguous.
#
# With no keychain argument, searches the normal Keychain search list, like
# the app. An explicit keychain restricts the query for isolated regression
# tests. Use the same scope for snapshot and verify. Requires Xcode's Swift.

set -euo pipefail

SERVICE="com.tookes.Sentwise"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

MODE="${1:-}"
STATE_FILE="${2:-}"
KEYCHAIN_FILE="${3:-}"

if [[ -z "$MODE" || -z "$STATE_FILE" || $# -gt 3 ]]; then
  echo "usage: keychain-tripwire.sh <snapshot|verify> <state-file> [keychain]" >&2
  exit 2
fi

# Only errSecItemNotFound means an empty service. All other lookup failures
# and incomplete metadata abort with exit 3, so two unreadable passes cannot
# compare equal and certify isolation that was never checked.
capture_state() {
  xcrun swift "$SCRIPT_DIR/keychain-snapshot.swift" "$SERVICE" ${KEYCHAIN_FILE:+"$KEYCHAIN_FILE"}
}

case "$MODE" in
  snapshot)
    if ! capture_state > "$STATE_FILE"; then
      rm -f "$STATE_FILE"
      exit 3
    fi
    count=$(awk 'NF { count++ } END { print count+0 }' "$STATE_FILE")
    echo "Snapshotted $count production Keychain item states (service $SERVICE) to $STATE_FILE"
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
