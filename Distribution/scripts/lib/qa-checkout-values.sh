#!/usr/bin/env bash
# Validation of a QA build's sign-in and checkout values (item 123), sourced by
# qa-build.sh and Distribution/scripts/tests/test_qa_build_wiring.py, so
# --require-checkout fails on a DMG whose sign-in or checkout could not work.
# Bash 3.2 compatible.
#
# MIRROR: Sentwise/Sentwise/Services/BuildConfiguration.swift (resolve,
# nonProductionURL, sandboxPaddleConfig) applies the same rules in the app.
# Change both together, keeping the rules in this order:
#   1. Placeholder: any value containing "YOUR" (any case) is rejected.
#   2. URL shape (service and Clerk URLs): https, a non-empty host, no
#      userinfo, no query, no fragment.
#   3. Production host: the host, lowercased with terminal dots trimmed, must
#      not be the production service or Clerk host.
#   4. Paddle environment: sandbox (checked in qa-build.sh).
#   5. Client token: ^test_[A-Za-z0-9]+$
#   6. Price ids: ^pri_[a-z0-9]+$, none a production id
#      (PaddleConfig.production), all three distinct.

QA_VALUES_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC2034 # used by qa-build.sh
QA_PRODUCTION_SERVICE_HOST="sentwise-inference.sentwise-service.workers.dev"
QA_PRODUCTION_CLERK_HOST="clerk.sentwise.ai"

# The host of an https URL, lowercased with terminal dots trimmed (so
# `clerk.sentwise.ai.` compares equal to production). Empty when the value is
# not an https URL with a host.
qa_normalized_host() {
  local url="$1" rest host
  case "$url" in
    [Hh][Tt][Tt][Pp][Ss]://*) rest="${url#*://}" ;;
    *) return 0 ;;
  esac
  host="${rest%%[/?#]*}"
  [[ "$host" == *@* ]] && return 0   # userinfo is refused, as in BuildConfiguration
  host="${host%%:*}"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  while [[ "$host" == *. ]]; do host="${host%.}"; done
  printf '%s' "$host"
}

# Rule 1: an unfilled QA.local.xcconfig.example placeholder (contains YOUR, any case).
qa_is_placeholder() {
  [[ "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" == *YOUR* ]]
}

# Rules 1-3 for a URL value. Prints the problem and returns 1, or returns 0.
#   qa_url_problem KEY VALUE PRODUCTION_HOST
qa_url_problem() {
  local key="$1" url="$2" production_host="$3" rest authority
  if [[ -z "$url" ]]; then
    echo "$key is not set"; return 1
  fi
  if qa_is_placeholder "$url"; then
    echo "$key '$url' is an unfilled placeholder"; return 1
  fi
  rest="${url#*://}"
  authority="${rest%%[/?#]*}"
  case "$url" in
    [Hh][Tt][Tt][Pp][Ss]://*) ;;
    *) echo "$key '$url' is not an https URL"; return 1 ;;
  esac
  if [[ "$url" == *[[:space:]]* || "$url" == *\?* || "$url" == *#* || "$authority" == *@* ]]; then
    echo "$key '$url' must have no query, fragment, userinfo, or whitespace"; return 1
  fi
  if [[ -z "$(qa_normalized_host "$url")" ]]; then
    echo "$key '$url' has no host"; return 1
  fi
  if [[ "$(qa_normalized_host "$url")" == "$production_host" ]]; then
    echo "$key points at production"; return 1
  fi
  return 0
}

# The production Paddle price ids, read from PaddleConfig.production so they
# never drift from the app. Prints the reason to stderr and returns 1 when the
# block is missing or yields no pri_ ids, so the check can never run against
# an empty list (item 6j).
qa_production_price_ids() {
  local file="$QA_VALUES_REPO_ROOT/Sentwise/Sentwise/Services/Billing/PaddleConfig.swift"
  local range='/static let production = PaddleConfig(/,/^    )/' block ids
  if ! block="$(LC_ALL=C sed -n "${range}p" "$file")"; then
    echo "qa_production_price_ids: sed '$range' failed on $file" >&2; return 1
  fi
  ids="$(LC_ALL=C grep -o 'pri_[a-z0-9]*' <<<"$block" || true)"
  if [[ -z "$ids" ]]; then
    echo "qa_production_price_ids: no pri_ ids in sed range '$range' of $file" >&2; return 1
  fi
  printf '%s\n' "$ids"
}

# Prints one line per problem with the given values and returns 1 if any.
#   qa_checkout_problems CLERK_URL PADDLE_TOKEN STARTER_ID PRO_ID UNLIMITED_ID
qa_checkout_problems() {
  local clerk="$1" token="$2" starter="$3" pro="$4" unlimited="$5" problems=0
  local production_ids name value
  if ! production_ids="$(qa_production_price_ids)"; then
    echo "could not read the production price ids from PaddleConfig.swift"; problems=1
  fi

  qa_url_problem SentwiseClerkFrontendAPIURL "$clerk" "$QA_PRODUCTION_CLERK_HOST" || problems=1

  if [[ -z "$token" ]]; then
    echo "SentwisePaddleClientToken is not set"; problems=1
  elif qa_is_placeholder "$token"; then
    echo "SentwisePaddleClientToken is an unfilled placeholder"; problems=1
  elif [[ ! "$token" =~ ^test_[A-Za-z0-9]+$ ]]; then
    echo "SentwisePaddleClientToken must be a Paddle sandbox token (test_...), not a live token or placeholder"
    problems=1
  fi

  for name in Starter Pro Unlimited; do
    case "$name" in
      Starter) value="$starter" ;;
      Pro) value="$pro" ;;
      Unlimited) value="$unlimited" ;;
    esac
    if [[ -z "$value" ]]; then
      echo "SentwisePaddle${name}PriceID is not set"; problems=1
    elif qa_is_placeholder "$value"; then
      echo "SentwisePaddle${name}PriceID is an unfilled placeholder"; problems=1
    elif [[ ! "$value" =~ ^pri_[a-z0-9]+$ ]]; then
      echo "SentwisePaddle${name}PriceID '$value' is not a Paddle price id (pri_...) or is a placeholder"
      problems=1
    # A here-string, not `printf | grep -q`: grep -q exits on the first match,
    # so a printf still writing gets SIGPIPE and pipefail turns the match into
    # a failure (the 2026-10-14 flake that accepted the production starter id).
    elif grep -qxF -- "$value" <<<"$production_ids"; then
      echo "SentwisePaddle${name}PriceID is a production price id"; problems=1
    fi
  done
  if [[ -n "$starter" && ( "$starter" == "$pro" || "$starter" == "$unlimited" ) ]] \
    || [[ -n "$pro" && "$pro" == "$unlimited" ]]; then
    echo "the three Paddle price ids must be distinct"; problems=1
  fi
  return "$problems"
}
