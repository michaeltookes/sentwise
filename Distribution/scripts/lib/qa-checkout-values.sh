#!/usr/bin/env bash
# Validation of a QA build's sign-in and checkout values (item 123), sourced by
# qa-build.sh and Distribution/scripts/tests/test_qa_build_wiring.py. Mirrors
# BuildConfiguration's sandbox rules so --require-checkout fails on a DMG whose
# checkout could not work, not just on empty values. Bash 3.2 compatible.

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

# The production Paddle price ids, read from PaddleConfig.production so they
# never drift from the app.
qa_production_price_ids() {
  sed -n '/static let production = PaddleConfig(/,/^    )/p' \
    "$QA_VALUES_REPO_ROOT/Sentwise/Sentwise/Services/Billing/PaddleConfig.swift" \
    | grep -o 'pri_[a-z0-9]*' || true
}

# Prints one line per problem with the given values and returns 1 if any.
#   qa_checkout_problems CLERK_URL PADDLE_TOKEN STARTER_ID PRO_ID UNLIMITED_ID
qa_checkout_problems() {
  local clerk="$1" token="$2" starter="$3" pro="$4" unlimited="$5" problems=0 host
  local production_ids name value
  production_ids="$(qa_production_price_ids)"

  host="$(qa_normalized_host "$clerk")"
  if [[ -z "$clerk" ]]; then
    echo "SentwiseClerkFrontendAPIURL is not set"; problems=1
  elif [[ -z "$host" || "$clerk" == *YOUR* ]]; then
    echo "SentwiseClerkFrontendAPIURL '$clerk' is not a real https Clerk development URL"; problems=1
  elif [[ "$host" == "$QA_PRODUCTION_CLERK_HOST" ]]; then
    echo "SentwiseClerkFrontendAPIURL points at the production Clerk instance"; problems=1
  fi

  if [[ -z "$token" ]]; then
    echo "SentwisePaddleClientToken is not set"; problems=1
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
    elif [[ ! "$value" =~ ^pri_[a-z0-9]+$ ]]; then
      echo "SentwisePaddle${name}PriceID '$value' is not a Paddle price id (pri_...) or is a placeholder"
      problems=1
    elif printf '%s\n' "$production_ids" | grep -qx "$value"; then
      echo "SentwisePaddle${name}PriceID is a production price id"; problems=1
    fi
  done
  if [[ -n "$starter" && ( "$starter" == "$pro" || "$starter" == "$unlimited" ) ]] \
    || [[ -n "$pro" && "$pro" == "$unlimited" ]]; then
    echo "the three Paddle price ids must be distinct"; problems=1
  fi
  return "$problems"
}
