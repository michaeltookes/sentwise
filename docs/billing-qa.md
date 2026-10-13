# Billing QA: testing the purchase path without a real charge

Backlog item 123. The comp entitlement (item 111) skips checkout, so this document covers how QA
proves the trial → checkout → paid path end to end, every release, without charging a real card.
TC-M3-05 runs on the method described here.

Secrets never go in this file. Every key and webhook secret lives in GitHub repository secrets, in
the Worker's environment (`wrangler secret put … --env sandbox`), or in the operator's local
`~/.config/sentwise-service/.env`.

## How it works

The purchase test runs on a **separate sandbox deployment** of the Worker plus a **QA build** of the
app. Production is never involved:

| Piece | Production | Purchase test |
| --- | --- | --- |
| Worker | `sentwise-inference` (live Paddle, production Clerk) | `sentwise-inference-sandbox`, the same code configured for the Paddle sandbox and the Clerk development instance (`sentwise-service/docs/sandbox-deployment.md`) |
| App | **Sentwise** (Release build) | **Sentwise QA** (QA build, `docs/qa-build.md`) |
| Paddle checkout | live token and prices | sandbox token and prices, sandbox mode |
| Accounts | production Clerk | Clerk development instance |

The production Worker and the production app carry no sandbox configuration at all, so a sandbox
price cannot reach a customer by construction. `{sandbox}` in the test cases is
`https://sentwise-inference-sandbox.sentwise-service.workers.dev`, and it runs the same release tag as
production (the lockstep rule).

## One-time setup (vendor-ops, with Michael for anything that needs his login)

### 1. Paddle sandbox account

1. Sign in to the Paddle **sandbox** account at `sandbox-vendors.paddle.com`. It is separate from the
   live account; nothing in it can move real money.
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
| --- | --- | --- |
| Sentwise Starter | $9.00 USD | monthly |
| Sentwise Pro | $19.00 USD | monthly |
| Sentwise Unlimited | $39.00 USD | monthly |

No trial period on the Paddle prices (the 14-day trial is enforced by the Worker, not by Paddle).
Copy the three `pri_…` ids. A catalog from the 56c era may already exist in the sandbox; reuse it only
after checking that its names and amounts match the table.

### 3. Sandbox notification destination

**Developer tools → Notifications → New destination**

- URL: `https://sentwise-inference-sandbox.sentwise-service.workers.dev/v1/paddle/webhook` (the
  sandbox Worker's ordinary webhook route; there is no special sandbox route).
- Events: the same set as the live destination (`subscription.*`, `transaction.completed`,
  `adjustment.*`).
- Copy the destination's secret key (`pdl_ntfset_…`).

### 4. Where each value goes

| Value | Goes to |
| --- | --- |
| Sandbox API key | `sentwise-service` repository secret `SANDBOX_PADDLE_API_KEY` |
| Destination secret (`pdl_ntfset_…`) | `sentwise-service` repository secret `SANDBOX_PADDLE_WEBHOOK_SECRET` |
| Three price ids | `sentwise-service` `wrangler.jsonc` `env.sandbox.vars.PADDLE_{STARTER,PRO,UNLIMITED}_PRICE_ID`, **and** this repo's QA build (`SENTWISE_PADDLE_{STARTER,PRO,UNLIMITED}_PRICE_ID`; repository variables `SENTWISE_QA_PADDLE_*_PRICE_ID`) |
| Client-side token (`test_…`) | this repo's QA build (`SENTWISE_PADDLE_CLIENT_TOKEN`; repository variable `SENTWISE_QA_PADDLE_CLIENT_TOKEN`) |

Then deploy the sandbox Worker (**Deploy sandbox**) and build the QA app (**QA build**) from the same
tag. Until every value is set, the sandbox Worker refuses to deploy and the QA build shows checkout as
unavailable; it never falls back to live prices.

### 5. Clerk development instance and QA account

See `docs/qa-build.md` ("Vendor setup") for the Clerk development instance. The purchaser is F3 from
`docs/qa/test-cases.md`, an `@prowlqa.dev` address whose sign-in codes arrive in F1's inbox. It is
created by signing in to **Sentwise QA** and exists only in the Clerk development instance. Make sure
F3 has no comp entitlement on the sandbox (`GET {sandbox}/admin/comp`): a comped account shows as paid
and the app never offers checkout.

## Running TC-M3-05 on the sandbox

The step-by-step procedure is in `docs/qa-build.md` ("TC-M3-05 on this design"). At the payment step,
the Paddle overlay shows a sandbox banner. Pay with a Paddle test card:

| Card number | Result |
| --- | --- |
| `4242 4242 4242 4242` | succeeds |
| `4000 0038 0000 0446` | succeeds after a 3-D Secure challenge |
| `4000 0000 0000 0002` | declined |

Any future expiry date, any 3-digit CVC, any cardholder name. Check Paddle's current "test cards"
page if one of these stops working; Paddle owns the list.

Expected: the sheet shows "You're on Starter — you're all set."; the Subscription tab shows Current
plan Starter renewing about one month out. The sandbox webhook writes the entitlement exactly as the
live one does, because it is the same code.

Clean-up: cancel the sandbox subscription and delete F3 from the Clerk development instance. No
refund, no lane reset: the sandbox account never touched production.

## Fallback methods (in order, if the sandbox deployment slips)

1. **Single-use 100%-off discount on production.** In the **live** Paddle dashboard create a discount:
   100% off, usage limit 1, restricted to the Starter price, expiring within a day. Enter it at the
   payment step with a production trial-ended QA account (F2) in **Sentwise**. Paddle still creates a
   real subscription at $0, so the webhook and entitlement path is exercised. Cancel the subscription
   immediately afterwards and archive the discount.
2. **Real $9 Starter purchase refunded the same day.** Buy Starter with a real card (Michael's) on F2,
   verify TC-M3-05/06, then refund the transaction in the live dashboard and cancel the subscription
   the same day. Costs Paddle's fees, which are not returned on refund; use only when the method
   above is unavailable.

Never purchase on F1, the daily Pro fixture: an active Paddle subscription takes precedence over its
comp.
