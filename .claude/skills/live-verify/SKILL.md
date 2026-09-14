---
name: live-verify
description: Dispatch the live-verification suite to the Lucius self-hosted runner via the live-tests GitHub Actions workflow, poll for the result, and report pass/fail with failure excerpts. Use when the user says "/live-verify", "live-verify this branch", "run the live tests on Lucius", or after a /kickoff branch is pushed and needs live verification. NEVER runs tests on the invoking machine.
allowed-tools: Bash
model: claude-opus-4-8
---

# Live verify

Dispatch-only. This skill triggers the `live-tests.yml` GitHub Actions workflow
on the **Lucius Mac mini** self-hosted runner, waits for it, and reports the
result. It is the on-demand counterpart to the automatic push-to-main run.

## Hard rules

- **This skill NEVER executes any test on the invoking machine.** No
  `xcodebuild`, no `SENTWISE_LIVE_*` env var, no `build-for-testing`, no
  `test-without-building` locally. All live execution happens on Lucius, inside
  the workflow. If `gh` is unavailable or the dispatch fails, STOP and report —
  do not fall back to running anything locally.
- **Scope guardrail (standing, 2026-09-10 billing-guardrail decision):** the
  live suite signs in, drafts, checks the checkout overlay *loads*, and fetches
  portal links. It NEVER completes a purchase, enters card data, or touches any
  billing change control. Never add, request, or suggest a payload that would.

## What it does

1. **Resolve the requested checkout ref.** Default to the current branch; accept
   an explicit ref argument (branch, tag, or SHA). A SHA is passed only through
   the workflow's `ref` input; the workflow file itself must be dispatched from
   a branch or tag.

   ```bash
   REQUESTED_REF="${1:-$(git rev-parse --abbrev-ref HEAD)}"
   DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
   WORKFLOW_REF="$DEFAULT_BRANCH"
   ```

   Prefer dispatching the workflow definition from the same branch/tag when that
   branch/tag exists on `origin`. If the requested ref is a local branch that is
   not pushed, stop and ask the owner to push it first. If it is a commit SHA,
   dispatch the workflow definition from the default branch and let the workflow
   checkout step use the SHA input.

   ```bash
   if git ls-remote --exit-code --heads origin "$REQUESTED_REF" >/dev/null 2>&1; then
     WORKFLOW_REF="$REQUESTED_REF"
   elif git ls-remote --exit-code --tags origin "$REQUESTED_REF" >/dev/null 2>&1; then
     WORKFLOW_REF="$REQUESTED_REF"
   elif git show-ref --verify --quiet "refs/heads/$REQUESTED_REF"; then
     echo "error: branch '$REQUESTED_REF' is not on origin; push it first." >&2
     exit 1
   else
     echo "info: dispatching live-tests.yml from '$WORKFLOW_REF' and checking out '$REQUESTED_REF'."
   fi
   ```

2. **Dispatch the workflow** with a unique correlation id:

   ```bash
   CORRELATION_ID="live-verify-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
   CREATED_AFTER="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
   gh workflow run live-tests.yml \
     --ref "$WORKFLOW_REF" \
     -f ref="$REQUESTED_REF" \
     -f correlation_id="$CORRELATION_ID"
   ```

3. **Find the exact run** it started, then **watch** it to completion. Do not use
   `--limit 1` unfiltered; another workflow_dispatch or push-to-main run may
   register while Actions is still creating this one.

   ```bash
   RUN_ID=""
   for _ in {1..24}; do
     RUN_ID=$(gh run list \
       --workflow=live-tests.yml \
       --event workflow_dispatch \
       --created ">=$CREATED_AFTER" \
       --json databaseId,displayTitle \
       --jq "map(select((.displayTitle // \"\") | contains(\"$CORRELATION_ID\"))) | .[0].databaseId // \"\"")
     [ -n "$RUN_ID" ] && break
     sleep 5
   done
   [ -n "$RUN_ID" ] || { echo "error: dispatched run '$CORRELATION_ID' was not found." >&2; exit 1; }
   gh run watch "$RUN_ID" --exit-status
   ```

   `--exit-status` makes `gh` exit non-zero if the run failed, so the skill can
   branch on it.

4. **Report the result.**
   - **Pass:** state that live verification passed on Lucius, name the ref and
     the run URL (`gh run view "$RUN_ID" --json url --jq .url`), and note how
     many live tests ran vs skipped if visible.
   - **Fail:** pull the failing excerpts and surface them:

     ```bash
     gh run view "$RUN_ID" --log-failed
     ```

     Report which live class failed and the relevant excerpt. Do NOT attempt to
     reproduce locally.

## Notes

- A run may report tests **skipped** rather than run — that means the matching
  repo secret is not provisioned (see `docs/live-testing.md` for the owner
  checklist). Skipped is not a failure, but call it out so the owner knows that
  payload was not actually exercised.
- Only one live run happens at a time (the workflow's concurrency group). If a
  run is already in progress, the dispatched run queues behind it — watch is
  still correct, it just waits.
- Merges to `main` are live-verified automatically by the workflow's push
  trigger; this skill is for verifying a branch **before** merge, or re-running
  on demand.
