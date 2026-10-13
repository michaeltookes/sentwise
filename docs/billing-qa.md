# Billing QA: testing the purchase path without a real charge

Backlog item 123. The comp entitlement (item 111) skips checkout, so this document covers how QA
proves the trial → checkout → paid path end to end, every release, without charging a real card.
TC-M3-05 runs on the method described here.

Secrets never go in this file. Every key and webhook secret lives in the Worker's environment
(`wrangler secret put`) or in the operator's local `~/.config/sentwise-service/.env`.

## How the sandbox lane works

One production Worker and one shipped app serve both Paddle environments. Nothing about a real
customer's checkout changes.

| Piece | Behavior |
|---|---|
| Worker `PADDLE_ENV` | `production` (committed default): everyone uses live Paddle. `sandbox`: accounts whose primary email is exactly `@prowlqa.dev` use the Paddle **sandbox**; everyone else stays on live Paddle. |
| Sandbox lane values | Sandbox API base, `PADDLE_SANDBOX_API_KEY`, `PADDLE_SANDBOX_WEBHOOK_SECRET`, `PADDLE_SANDBOX_*_PRICE_ID`. They replace the live values for a QA request; there is no fallback to a live key, secret, or price id. |
| Webhooks | Live destination `POST /v1/paddle/webhook` verifies with the live secret only. Sandbox destination `POST /v1/paddle/webhook/sandbox` exists only while `PADDLE_ENV=sandbox`, verifies with the sandbox secret only, and drops any event that maps to a non-QA account. |
| `GET /v1/me` | Adds `billing`. Production accounts always get `{ "environment": "production" }`. A QA account in the sandbox lane gets `{ "environment": "sandbox", "clientSideToken": "test_…", "prices": {…} }`. |
| App | Opens the sandbox checkout only when `/v1/me` says `sandbox` **and** the account email is `@prowlqa.dev` **and** the lane carries a `test_` token and three distinct sandbox price ids that aren't live ids (`PaddleConfig.resolved(billing:accountEmail:)`). Anything else uses the embedded live config. |

Both gates (Worker and app) are unit-tested in `sentwise-service/test/paddle-sandbox-lane.test.ts`
and `Sentwise/SentwiseTests/PaddleSandboxLaneTests.swift` (plus the AppState wiring tests in
`AppStateCheckoutModelTests.swift`), including the case where the service is in sandbox and a
production account still only sees live prices.

## One-time setup (owner)

### 1. Paddle sandbox account

1. Sign up for a Paddle **sandbox** account at `sandbox-vendors.paddle.com`. It is separate from
   the live account; nothing in it can move real money.
2. **Checkout settings → Approved domains:** add `sentwise.ai`. The app's checkout page loads under
   that origin (`PaddleConfig.checkoutOrigin`), so the sandbox needs it approved too.
3. **Developer tools → Authentication:** create
   - an **API key** with `transaction.write`, `transaction.read`, `subscription.read`,
     `subscription.write`, and `customer.read` (the same scopes as the live key), and
   - a **client-side token** (starts with `test_`).

### 2. Catalog mirroring `docs/tier-matrix.md`

Create one product per tier, each with one monthly recurring USD price. Names and amounts must match
the tier matrix so the sandbox exercises the same tiers the live store sells:

| Product | Price | Billing |
|---|---|---|
| Sentwise Starter | $9.00 USD | monthly |
| Sentwise Pro | $19.00 USD | monthly |
| Sentwise Unlimited | $39.00 USD | monthly |

No trial period on the Paddle prices (the 14-day trial is enforced by the Worker, not by Paddle).
Copy the three `pri_…` ids. A one-time "extra drafts" price is optional; set
`PADDLE_SANDBOX_EXTRA_DRAFTS_PRICE_ID` only if overage purchases are being tested.

### 3. Sandbox notification destination

**Developer tools → Notifications → New destination**

- URL: `https://sentwise-inference.sentwise-service.workers.dev/v1/paddle/webhook/sandbox`
- Events: the same set as the live destination (`subscription.*`, `transaction.completed`,
  `adjustment.*`).
- Copy the destination's secret key (`pdl_ntfset_…`).

### 4. Worker configuration

Add to `~/.config/sentwise-service/.env` (sandbox values only), then push the two secrets:

```bash
grep '^PADDLE_SANDBOX_API_KEY='        ~/.config/sentwise-service/.env | cut -d= -f2- | npx wrangler secret put PADDLE_SANDBOX_API_KEY
grep '^PADDLE_SANDBOX_WEBHOOK_SECRET=' ~/.config/sentwise-service/.env | cut -d= -f2- | npx wrangler secret put PADDLE_SANDBOX_WEBHOOK_SECRET
```

Set these as Worker vars (they are public: the client token is frontend-scoped and price ids aren't
secret), then set `PADDLE_ENV` to `sandbox` and deploy:

- `PADDLE_SANDBOX_CLIENT_TOKEN` = the `test_…` token
- `PADDLE_SANDBOX_STARTER_PRICE_ID`, `PADDLE_SANDBOX_PRO_PRICE_ID`, `PADDLE_SANDBOX_UNLIMITED_PRICE_ID`

Until every one of those is set, `/v1/me` keeps reporting `production` to QA accounts and the app
stays on the live config. Live customers are unaffected either way. Set `PADDLE_ENV` back to
`production` to close the lane.

### 5. QA account

The QA account signs in with an `@prowlqa.dev` address (the address's mailbox must receive Clerk's
sign-in code). Remove any comp entitlement first (`DELETE /admin/comp`, item 111): a comped account
shows as paid and the app never offers checkout.

## Running TC-M3-05 on the sandbox

1. Confirm the lane: `GET /v1/me` for the QA account returns `billing.environment = "sandbox"`.
2. In the app: **Settings… → Subscription → Subscribe**, choose Starter.
3. The Paddle overlay shows a sandbox banner. Pay with a Paddle test card:

   | Card number | Result |
   |---|---|
   | `4242 4242 4242 4242` | succeeds |
   | `4000 0038 0000 0446` | succeeds after a 3-D Secure challenge |
   | `4000 0000 0000 0002` | declined |

   Any future expiry date, any 3-digit CVC, any cardholder name. Check Paddle's current
   "test cards" page if one of these stops working; Paddle owns the list.
4. Expected: the sheet shows "You're on Starter — you're all set."; the Account section shows
   Current plan Starter with a renewal date about one month out. The sandbox webhook writes the
   entitlement exactly as the live one does.
5. **Production unaffected:** sign in with any non-QA account on the same build and confirm
   `/v1/me` returns `billing.environment = "production"` and the plan cards open the live overlay
   (no sandbox banner). Close it without paying.
6. Clean up: cancel the sandbox subscription in the sandbox dashboard (or via Manage billing, which
   opens the sandbox portal for the QA account) so the next run starts from trial.

## Fallback methods (in order, if the sandbox lane slips)

1. **Single-use 100%-off discount on production.** In the **live** Paddle dashboard create a
   discount: 100% off, usage limit 1, restricted to the Starter price, expiring within a day. Enter
   it at step 3 of TC-M3-05 with the QA account on production (`PADDLE_ENV=production`, or any
   non-sandbox lane). Paddle still creates a real subscription at $0, so the webhook and
   entitlement path is exercised. Cancel the subscription afterwards and archive the discount.
2. **Real $9 Starter purchase refunded the same day.** Buy Starter with a real card on the QA
   account, verify TC-M3-05/06, then refund the transaction in the live dashboard and cancel the
   subscription the same day. Costs Paddle's fees, which are not returned on refund; use only when
   both methods above are unavailable.
