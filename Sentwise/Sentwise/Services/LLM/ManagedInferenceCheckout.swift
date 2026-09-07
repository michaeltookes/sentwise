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

/// Server-minted Paddle checkout on the managed-inference client (backlog item
/// 56c). Split out of `ManagedInferenceClient` so that file stays within length
/// limits.
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
