# Tier feature matrix

The committed feature-by-tier decision record (backlog item 98; owner decisions 2026-09-16). Pricing surfaces (landing page), the app's plan picker and client-side gates, and the Worker's per-tier caps all implement from this document. Change it only with an owner decision, dated.

**Managed inference only** (item 100, 2026-09-16): every tier drafts through the managed proxy — no BYO-key or local-model option exists in the product or pricing. Tiers differentiate on **features + follow-up volume**, all managed.

## The matrix

| | **Trial** (14 days) | **Starter** $9/mo | **Pro** $19/mo (featured) | **Unlimited** $39/mo |
|---|---|---|---|---|
| Follow-up drafts | 56b trial default | **30 / month** | **120 / month** | **Unlimited (fair-use)** |
| Connected email accounts | **2** (Pro-equivalent) | **1** | **2** | **up to 5** |
| Calling-tool integrations (Zoom/Teams — item 53, not yet built) | per Pro | — | **✓** when shipped | **✓** when shipped |
| CRM integrations (item 55, not yet built) | — | — | — | **✓** when shipped |
| Slack approval channel (item 30, not yet built) | *placement TBD — leaning Pro-family* | | | |
| Managed AI drafting, voice learning, notifications + in-app review | ✓ all tiers | ✓ | ✓ | ✓ |

Notes:
- **"Unlimited" refers to follow-up volume, not accounts** (owner, 2026-09-16). The fair-use ceiling is a server-side backstop (`UNLIMITED_DRAFT_LIMIT`), never marketed as a number.
- **Trial is Pro-equivalent on features** (2 accounts) so the trial showcases the featured tier; its draft allotment follows the 56b trial default, and trials are always hard-enforced (item 94).
- The `team` plan value exists in the app/Worker enums but is **not sold** — reserved for a future Team tier (Enterprise remains parked).

## Enforcement posture per gate

| Gate | Enforced | Notes |
|---|---|---|
| Follow-up allotments, rate limits, trial expiry | **Server** (Worker) | Unbypassable — every draft passes through `/v1/draft`. Trials hard-enforced regardless of `ENFORCEMENT_MODE` (item 94). |
| Connected-account count | **Client** (app UI gate) | Keyed off `subscription.plan` from `/v1/me` (verified 2026-09-16: the payload already carries the tier id; no wire change needed). Accepted A-L5-style posture: a source-builder can bypass a client gate — open core accepts this. Optional future hardening: a per-account distinct-hash cap on managed drafting (fully effective now that managed is the only path, item 100). Build only if abuse appears. |
| Integration gates (53/55/30) | **Client** when they ship | Same posture as account count; record per-item at build time. |

## Display rule (pricing cards)

**Cards only ever show shipped capabilities** (owner, 2026-09-16) — no "coming soon". Account-count lines may now appear: **item 99 shipped** (branch `multi-account-support`) — concurrent multi-account with a client-side connected-account gate keyed off `subscription.plan` from `/v1/me`, enforcing Starter 1 / Pro 2 / Unlimited 5 / Trial 2. Integration lines still appear only after 53/55/30 ship. Site ticket: `sentwise-landing-page` item 14 (carries the per-card copy).

## Alignment work owed at cutover (item 74)

- **Window unit mismatch:** the Worker's per-tier limits (`STARTER_DRAFT_LIMIT=30`, `PRO_DRAFT_LIMIT=120`) are enforced over a **weekly** window, but the site markets those numbers as **monthly**. The marketed monthly caps are canonical; before launch, either switch the quota window to monthly or set weekly limits to ~monthly/4.33 (7 / 28). Tracked on item 74.
- **Live Paddle products/prices** must match this matrix exactly: Starter $9 / Pro $19 / Unlimited $39, plan ids `starter`/`pro`/`unlimited`. Tracked on item 74.

## References

- Multi-account build: item 99 (**shipped**, branch `multi-account-support`) — uses this matrix as its gating spec; the app enforces the connected-account caps client-side at connect time.
- Metering defaults and wire contract: item 56b; `sentwise-service/wrangler.jsonc`.
- Security postures cited: A-L5 and the 2026-09-13 security pass report.
