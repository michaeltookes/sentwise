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

1. **Resolve the requested checkout ref.** Default to the current branch, or to
   the checked-out commit SHA when the invoking checkout is detached; accept an
   explicit ref argument (branch, tag, or SHA). A SHA is passed only through the
   workflow's `ref` input; the workflow file itself must be dispatched from a
   branch or tag.

   ```bash
   REQUESTED_REF="${1:-$(git rev-parse --abbrev-ref HEAD)}"
   if [ "$REQUESTED_REF" = "HEAD" ]; then
     REQUESTED_REF="$(git rev-parse HEAD)"
   fi
   DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
   WORKFLOW_REF="$DEFAULT_BRANCH"
   CHECKOUT_REF="$REQUESTED_REF"
   ```

   Prefer dispatching the workflow definition from the same branch/tag only when
   that branch/tag exists on `origin` and contains `.github/workflows/live-tests.yml`.
   Query fully qualified remote refs (not suffix patterns) so `foo` cannot
   accidentally match `team/foo`. If the requested ref is a local branch or tag,
   its local object id must match the remote object id; otherwise stop and ask
   the owner to push or sync it first. For a matched branch or tag, pass the exact
   pushed SHA through the workflow's checkout `ref` input so the run verifies the
   code that was checked. If the requested remote branch/tag is historical and
   lacks the workflow file, or if the requested ref is a commit SHA, dispatch the
   workflow definition from the default branch and let the workflow checkout step
   use the exact requested SHA/OID input.

   ```bash
   remote_oid_for_ref() {
     full_ref="$1"
     matches="$(git ls-remote origin "$full_ref" | awk -v ref="$full_ref" '$2 == ref {print $1}')"
     match_count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
     if [ "$match_count" -gt 1 ]; then
       echo "error: origin returned multiple matches for '$full_ref'; refusing to guess." >&2
       exit 1
     fi
     printf '%s\n' "$matches" | sed -n '1p'
   }

   remote_ref_has_live_workflow() {
     full_ref="$1"
     checkout_oid="$2"
     if ! git fetch --quiet origin "$full_ref" >/dev/null 2>&1; then
       echo "warning: could not fetch '$full_ref' to inspect workflow file; dispatching from default branch." >&2
       return 1
     fi
     git cat-file -e "$checkout_oid:.github/workflows/live-tests.yml" 2>/dev/null
   }

   REMOTE_BRANCH_OID="$(remote_oid_for_ref "refs/heads/$REQUESTED_REF")"
   REMOTE_TAG_OID="$(remote_oid_for_ref "refs/tags/$REQUESTED_REF")"
   REMOTE_TAG_TARGET_OID="$(remote_oid_for_ref "refs/tags/$REQUESTED_REF^{}")"

   if [ -n "$REMOTE_BRANCH_OID" ]; then
     if git show-ref --verify --quiet "refs/heads/$REQUESTED_REF"; then
       LOCAL_BRANCH_OID="$(git rev-parse "refs/heads/$REQUESTED_REF")"
       if [ "$LOCAL_BRANCH_OID" != "$REMOTE_BRANCH_OID" ]; then
         echo "error: branch '$REQUESTED_REF' differs from origin; push or sync it before live verification." >&2
         echo "local:  $LOCAL_BRANCH_OID" >&2
         echo "origin: $REMOTE_BRANCH_OID" >&2
         exit 1
       fi
     fi
     CHECKOUT_REF="$REMOTE_BRANCH_OID"
     if remote_ref_has_live_workflow "refs/heads/$REQUESTED_REF" "$CHECKOUT_REF"; then
       WORKFLOW_REF="$REQUESTED_REF"
     else
       echo "info: origin branch '$REQUESTED_REF' lacks live-tests.yml; dispatching from '$WORKFLOW_REF'."
     fi
   elif [ -n "$REMOTE_TAG_OID" ]; then
     if git show-ref --verify --quiet "refs/tags/$REQUESTED_REF"; then
       LOCAL_TAG_OID="$(git rev-parse "refs/tags/$REQUESTED_REF")"
       if [ "$LOCAL_TAG_OID" != "$REMOTE_TAG_OID" ]; then
         echo "error: tag '$REQUESTED_REF' differs from origin; push or sync it before live verification." >&2
         echo "local:  $LOCAL_TAG_OID" >&2
         echo "origin: $REMOTE_TAG_OID" >&2
         exit 1
       fi
     fi
     CHECKOUT_REF="${REMOTE_TAG_TARGET_OID:-$REMOTE_TAG_OID}"
     if remote_ref_has_live_workflow "refs/tags/$REQUESTED_REF" "$CHECKOUT_REF"; then
       WORKFLOW_REF="$REQUESTED_REF"
     else
       echo "info: origin tag '$REQUESTED_REF' lacks live-tests.yml; dispatching from '$WORKFLOW_REF'."
     fi
   elif git show-ref --verify --quiet "refs/heads/$REQUESTED_REF"; then
     echo "error: branch '$REQUESTED_REF' is not on origin; push it first." >&2
     exit 1
   elif git show-ref --verify --quiet "refs/tags/$REQUESTED_REF"; then
     echo "error: tag '$REQUESTED_REF' is not on origin; push it first." >&2
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
     -f ref="$CHECKOUT_REF" \
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
- Only one live run happens at a time because Lucius is the single eligible
  self-hosted macOS runner. If a run is already in progress, the dispatched run
  queues behind it — watch is still correct, it just waits. Do not add a global
  workflow concurrency group; GitHub can cancel older pending dispatches even
  when `cancel-in-progress` is false.
- Merges to `main` are live-verified automatically by the workflow's push
  trigger; this skill is for verifying a branch **before** merge, or re-running
  on demand.
