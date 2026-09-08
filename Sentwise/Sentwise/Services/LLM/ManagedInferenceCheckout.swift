import Foundation

/// The result of `POST /v1/paddle/checkout` (backlog item 56c): a server-minted
/// Paddle transaction the app opens the overlay with. The Worker has already
/// bound the signed-in account to the transaction via a signed `custom_data`, so
/// the app opens by `transactionId` alone — it does not (and must not) pass raw
/// `items` / `customData` / `customer` client-side. `checkoutUrl` is Paddle's
/// hosted fallback URL when present; the overlay path uses only `transactionId`.
struct PaddleCheckoutTransaction: Equatable, Sendable {
    let transactionID: String
    let checkoutURL: String?

    init(transactionID: String, checkoutURL: String? = nil) {
        self.transactionID = transactionID
        self.checkoutURL = checkoutURL
    }
}

/// The `action` on `GET /v1/paddle/manage-billing` (backlog item 90). The default
/// (no query) returns the update/portal URL; `.cancel` returns the cancellation
/// flow URL. Kept as a typed value so callers can't send an arbitrary query.
enum PaddleBillingAction: String, Sendable, Equatable {
    case cancel
}

/// The result of `POST /v1/paddle/change-plan` (backlog item 90): the account's
/// tier and lifecycle status *after* the Paddle subscription update. The app
/// reconciles `/v1/me` on top of this, but the immediate response lets the pane
/// confirm the switch without waiting for the poll.
struct PaddlePlanChange: Equatable, Sendable {
    let plan: ManagedSubscription.Plan
    let status: ManagedSubscription.Status
}

/// Server-minted Paddle checkout on the managed-inference client (backlog item
/// 56c). Split out of `ManagedInferenceClient` so that file stays within length
/// limits. Extended for in-app plan management (item 90): the on-demand
/// management-URL fetch and the subscription-update (change-plan) call.
extension ManagedInferenceClient {

    /// Fetches a *fresh* Paddle management URL via
    /// `GET /v1/paddle/manage-billing[?action=cancel]` (item 90). Paddle portal
    /// URLs are short-lived, so this is called on tap rather than trusting the
    /// webhook-stored URL (which comes back empty in sandbox — the bug this fixes).
    /// Returns a validated `http(s)` URL. Throws `LLMError.managedNotSignedIn` on
    /// `401` and `LLMError.managedManageBillingUnavailable` (with the Worker's
    /// plain message) on any other non-2xx or a missing/blank URL.
    func fetchManageBillingURL(
        action: PaddleBillingAction? = nil,
        endpoint: URL = ManagedInference.paddleManageBillingEndpoint
    ) async throws -> URL {
        let session = try await sessionProvider.currentManagedSession()
        let headers = [
            "authorization": "Bearer \(session.jwt)",
            "content-type": "application/json"
        ]
        let requestURL = Self.manageBillingURL(base: endpoint, action: action)

        let response: HTTPResponse
        do {
            response = try await transport.getJSON(requestURL, headers: headers)
        } catch {
            throw LLMError.transport(String(describing: error))
        }

        if response.statusCode == 401 {
            await sessionProvider.invalidateSession(matching: session.credentialIdentity)
        }
        guard response.isSuccess else {
            throw Self.mapManageBillingError(status: response.statusCode, body: response.body)
        }

        let decoded: ManageBillingResponseBody
        do {
            decoded = try JSONDecoder().decode(ManageBillingResponseBody.self, from: response.body)
        } catch {
            throw LLMError.managedManageBillingUnavailable(
                "We couldn't open your billing portal just now. Please try again."
            )
        }
        guard let raw = decoded.managementUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw LLMError.managedManageBillingUnavailable(
                "We couldn't open your billing portal just now. Please try again."
            )
        }
        return url
    }

    /// Switches the account's subscription to `priceID`'s tier via
    /// `POST /v1/paddle/change-plan` (item 90). This is a Paddle subscription
    /// update with proration — not a second recurring checkout. Returns the
    /// account's tier/status after the update. Throws `LLMError.managedNotSignedIn`
    /// on `401` and `LLMError.managedChangePlanFailed` (with the Worker's plain
    /// message) on other non-2xx responses (`400 invalid_request` / same price,
    /// `404 billing_subscription_not_found`, `502`, `503 checkout_unavailable`).
    func changePlan(
        priceID: String,
        endpoint: URL = ManagedInference.paddleChangePlanEndpoint
    ) async throws -> PaddlePlanChange {
        let session = try await sessionProvider.currentManagedSession()
        let headers = [
            "authorization": "Bearer \(session.jwt)",
            "content-type": "application/json"
        ]
        let body: Data
        do {
            body = try JSONEncoder().encode(ChangePlanRequestBody(priceId: priceID))
        } catch {
            throw LLMError.invalidResponse("Couldn't encode the change-plan request. (\(error))")
        }

        let response: HTTPResponse
        do {
            response = try await transport.postJSON(endpoint, headers: headers, body: body)
        } catch {
            throw LLMError.transport(String(describing: error))
        }

        if response.statusCode == 401 {
            await sessionProvider.invalidateSession(matching: session.credentialIdentity)
        }
        guard response.isSuccess else {
            throw Self.mapChangePlanError(status: response.statusCode, body: response.body)
        }

        let decoded: ChangePlanResponseBody
        do {
            decoded = try JSONDecoder().decode(ChangePlanResponseBody.self, from: response.body)
        } catch {
            throw LLMError.invalidResponse("Unexpected change-plan response shape. (\(error))")
        }
        let plan = decoded.plan.flatMap(ManagedSubscription.Plan.init(rawValue:)) ?? .unknown
        let status = decoded.status.flatMap(ManagedSubscription.Status.init(rawValue:)) ?? .active
        return PaddlePlanChange(plan: plan, status: status)
    }

    /// Builds the `manage-billing` request URL, appending `?action=` only when a
    /// typed action is supplied.
    static func manageBillingURL(base: URL, action: PaddleBillingAction?) -> URL {
        guard let action,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.queryItems = [URLQueryItem(name: "action", value: action.rawValue)]
        return components.url ?? base
    }

    /// Maps a `GET /v1/paddle/manage-billing` failure into a clear `LLMError`.
    /// `401` is "not signed in"; everything else surfaces the Worker's plain
    /// message (already user-safe), falling back to billing-only copy.
    static func mapManageBillingError(status: Int, body: Data) -> LLMError {
        if status == 401 { return .managedNotSignedIn }
        let decoded = try? JSONDecoder().decode(CheckoutErrorBody.self, from: body)
        return .managedManageBillingUnavailable(
            decoded?.error?.message ?? "We couldn't open your billing portal just now. Please try again."
        )
    }

    /// Maps a `POST /v1/paddle/change-plan` failure into a clear `LLMError`.
    /// `401` is "not signed in"; every other non-2xx surfaces the Worker's plain
    /// message (bad/same price, no active subscription, Paddle unavailable),
    /// falling back to billing-only copy.
    static func mapChangePlanError(status: Int, body: Data) -> LLMError {
        if status == 401 { return .managedNotSignedIn }
        let decoded = try? JSONDecoder().decode(CheckoutErrorBody.self, from: body)
        return .managedChangePlanFailed(
            decoded?.error?.message ?? "We couldn't switch your plan just now. Please try again."
        )
    }
}

/// Reuse the checkout endpoint's Paddle-family helpers (backlog item 56c).
extension ManagedInferenceClient {

    /// Mints a server-side Paddle checkout transaction for `priceID` via
    /// `POST /v1/paddle/checkout`. Subscriptions require quantity 1 (the Worker
    /// enforces this); the returned `transactionId` is what the app hands to
    /// `Paddle.Checkout.open({ transactionId })`. The transaction already carries
    /// the signed `custom_data` + customer binding server-side, so the webhook
    /// attributes the completed purchase reliably. Throws
    /// `LLMError.managedNotSignedIn` on `401` and `LLMError.managedCheckoutFailed`
    /// (with the Worker's plain message) on other non-2xx responses
    /// (`400 invalid_request`, `404 account_not_found`, `409` eligibility errors,
    /// `503 checkout_unavailable`, `502`).
    func createCheckoutTransaction(
        priceID: String,
        quantity: Int = 1,
        checkoutEndpoint: URL = ManagedInference.paddleCheckoutEndpoint
    ) async throws -> PaddleCheckoutTransaction {
        let session = try await sessionProvider.currentManagedSession()
        let headers = [
            "authorization": "Bearer \(session.jwt)",
            "content-type": "application/json"
        ]
        let body: Data
        do {
            body = try JSONEncoder().encode(CheckoutRequestBody(priceId: priceID, quantity: quantity))
        } catch {
            throw LLMError.invalidResponse("Couldn't encode the checkout request. (\(error))")
        }

        let response: HTTPResponse
        do {
            response = try await transport.postJSON(checkoutEndpoint, headers: headers, body: body)
        } catch {
            throw LLMError.transport(String(describing: error))
        }

        if response.statusCode == 401 {
            await sessionProvider.invalidateSession(matching: session.credentialIdentity)
        }
        guard response.isSuccess else {
            throw Self.mapCheckoutError(status: response.statusCode, body: response.body)
        }

        let decoded: CheckoutResponseBody
        do {
            decoded = try JSONDecoder().decode(CheckoutResponseBody.self, from: response.body)
        } catch {
            throw LLMError.invalidResponse("Unexpected checkout response shape. (\(error))")
        }
        let transactionID = decoded.transactionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transactionID.isEmpty else {
            throw LLMError.invalidResponse("Checkout response was missing a transaction id.")
        }
        return PaddleCheckoutTransaction(transactionID: transactionID, checkoutURL: decoded.checkoutUrl)
    }

    /// Maps a `POST /v1/paddle/checkout` failure into a clear `LLMError`. `401` is
    /// "not signed in"; every other non-2xx surfaces the Worker's plain,
    /// user-facing message (already scrubbed of upstream Paddle/Clerk detail),
    /// falling back to a generic checkout message.
    static func mapCheckoutError(status: Int, body: Data) -> LLMError {
        let decoded = try? JSONDecoder().decode(CheckoutErrorBody.self, from: body)
        let message = decoded?.error?.message
        if status == 401 {
            return .managedNotSignedIn
        }
        return .managedCheckoutFailed(
            message ?? "We couldn't start checkout. Please try again."
        )
    }
}

// MARK: - Wire-format DTOs (file-private)

private struct CheckoutRequestBody: Encodable {
    let priceId: String
    let quantity: Int
}

private struct CheckoutResponseBody: Decodable {
    let transactionId: String
    /// Paddle's hosted checkout URL when present; the overlay path ignores it.
    let checkoutUrl: String?
}

/// The Worker's structured error shape: `{ "error": { "type", "message" } }`.
private struct CheckoutErrorBody: Decodable {
    let error: Detail?
    struct Detail: Decodable {
        let type: String?
        let message: String?
    }
}

private struct ManageBillingResponseBody: Decodable {
    let managementUrl: String?
}

private struct ChangePlanRequestBody: Encodable {
    let priceId: String
}

private struct ChangePlanResponseBody: Decodable {
    let ok: Bool?
    /// `"starter" | "pro" | "unlimited"` — the tier after the update.
    let plan: String?
    /// `"active" | ...` — the subscription lifecycle status after the update.
    let status: String?
}
