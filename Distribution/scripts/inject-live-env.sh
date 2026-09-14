#!/usr/bin/env bash
#
# inject-live-env.sh — inject the SENTWISE_LIVE_* env vars into an .xctestrun so
# the app-hosted live tests can read them.
#
# Why this exists: a plain shell `env` (or TEST_RUNNER_… prefix) does NOT
# propagate into a macOS *app-hosted* XCTest bundle launched by `xcodebuild
# test`. The documented recipe (docs/managed-inference.md, docs/live-testing.md)
# is: `build-for-testing` → write the vars into the generated `.xctestrun`
# EnvironmentVariables → `test-without-building`. This script is the middle step,
# extracted so it is shellcheck-clean and testable outside the workflow.
#
# It injects ONLY the vars that are set and non-empty in the current environment;
# unset ones are left out, so their gated tests skip cleanly. Values are read
# from the environment and never printed — only the injected variable NAMES are
# logged, so secrets never reach CI logs.
#
# Usage:
#   inject-live-env.sh <path-to.xctestrun> [test-target-name]
#
#   <path-to.xctestrun>  the .xctestrun emitted by `build-for-testing`
#                        (Build/Products/<Scheme>_<platform>.xctestrun).
#   [test-target-name]   the XCTest target key (default: SentwiseTests).

set -euo pipefail

XCTESTRUN="${1:-}"
TEST_TARGET="${2:-SentwiseTests}"

if [[ -z "$XCTESTRUN" ]]; then
  echo "usage: inject-live-env.sh <path-to.xctestrun> [test-target-name]" >&2
  exit 2
fi
if [[ ! -f "$XCTESTRUN" ]]; then
  echo "error: xctestrun not found: $XCTESTRUN" >&2
  exit 1
fi

# The full set of live-test env vars the suite reads. Keep in sync with the
# gates in Sentwise/SentwiseTests/*LiveTests.swift + ClerkLiveSignInTests
# (grep SENTWISE_LIVE_ / SENTWISE_INFERENCE_URL). Optional host/port vars are
# included so a non-default IMAP endpoint can be supplied.
LIVE_VARS=(
  SENTWISE_LIVE_PADDLE_CHECKOUT
  SENTWISE_LIVE_CLERK_TEST
  SENTWISE_LIVE_MANAGED_INFERENCE
  SENTWISE_LIVE_MANAGED_DRAFT
  SENTWISE_INFERENCE_URL
  SENTWISE_LIVE_GMAIL_EMAIL
  SENTWISE_LIVE_GMAIL_APP_PASSWORD
  SENTWISE_LIVE_GMAIL_HOST
  SENTWISE_LIVE_GMAIL_PORT
  SENTWISE_LIVE_ATTNET_EMAIL
  SENTWISE_LIVE_ATTNET_APP_PASSWORD
  SENTWISE_LIVE_ATTNET_HOST
  SENTWISE_LIVE_ATTNET_PORT
)

# The EnvironmentVariables container keypaths to inject into. FormatVersion 1
# (the current Xcode default) is a flat dict keyed by the test-target name;
# FormatVersion 2 nests targets under TestConfigurations. We detect and support
# both so a future Xcode bump does not silently break env plumbing.
declare -a ENV_BASES=()

# NOTE: every `plutil -extract` MUST pass `-o -` (write to stdout). Without it,
# plutil rewrites the *input file* with the extracted subtree — silently
# corrupting the .xctestrun. These are read-only existence probes.
if plutil -extract "TestConfigurations" json -o - "$XCTESTRUN" >/dev/null 2>&1; then
  # FormatVersion 2: iterate every configuration × test target.
  config_index=0
  while plutil -extract "TestConfigurations.${config_index}" json -o - "$XCTESTRUN" >/dev/null 2>&1; do
    target_index=0
    while plutil -extract "TestConfigurations.${config_index}.TestTargets.${target_index}" json -o - "$XCTESTRUN" >/dev/null 2>&1; do
      ENV_BASES+=("TestConfigurations.${config_index}.TestTargets.${target_index}.EnvironmentVariables")
      target_index=$((target_index + 1))
    done
    config_index=$((config_index + 1))
  done
else
  # FormatVersion 1: flat, keyed by the test-target name.
  if ! plutil -extract "${TEST_TARGET}" json -o - "$XCTESTRUN" >/dev/null 2>&1; then
    echo "error: test target '${TEST_TARGET}' not found in $XCTESTRUN" >&2
    exit 1
  fi
  ENV_BASES+=("${TEST_TARGET}.EnvironmentVariables")
fi

if [[ ${#ENV_BASES[@]} -eq 0 ]]; then
  echo "error: no EnvironmentVariables container found in $XCTESTRUN" >&2
  exit 1
fi

injected=()
skipped=()

for var_name in "${LIVE_VARS[@]}"; do
  var_value="${!var_name:-}"
  if [[ -z "$var_value" ]]; then
    skipped+=("$var_name")
    continue
  fi
  for base in "${ENV_BASES[@]}"; do
    # Set-or-add the leaf. `plutil -replace` only rewrites an existing key
    # ("Key path not found" otherwise), so `plutil -insert` adds it when absent.
    # Both are value-safe: the value is passed as a single -string argument, so
    # spaces/special chars are preserved (and never word-split).
    if plutil -extract "${base}.${var_name}" raw -o - "$XCTESTRUN" >/dev/null 2>&1; then
      plutil -replace "${base}.${var_name}" -string "$var_value" "$XCTESTRUN"
    else
      plutil -insert "${base}.${var_name}" -string "$var_value" "$XCTESTRUN"
    fi
  done
  injected+=("$var_name")
done

# Log NAMES only — never values.
if [[ ${#injected[@]} -gt 0 ]]; then
  echo "Injected ${#injected[@]} live env var(s): ${injected[*]}"
else
  echo "No live env vars were set; injected none (all gated tests will skip)."
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "Not set (skipped): ${skipped[*]}"
fi

plutil -lint "$XCTESTRUN" >/dev/null
