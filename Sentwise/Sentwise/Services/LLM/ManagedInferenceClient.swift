import Foundation

/// Compile-time configuration for the Sentwise managed-inference service
/// (`sentwise-service`, backlog item 56a). The base URL is a constant with a
/// `SENTWISE_INFERENCE_URL` environment override for dev/tests pointing at a
/// local `wrangler dev` or a staging deployment.
enum ManagedInference {
    /// The deployed production Worker. Recorded here and in the service README.
    static let defaultBaseURLString = "https://sentwise-inference.sentwise-service.workers.dev"

    /// The base URL honoring the `SENTWISE_INFERENCE_URL` override.
    static var baseURL: URL {
        let override = ProcessInfo.processInfo.environment["SENTWISE_INFERENCE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty, let url = URL(string: override) {
            return url
        }
        // The default string is a compile-time constant we control, so this is safe.
        return URL(string: defaultBaseURLString)!
    }

    static var draftEndpoint: URL { baseURL.appendingPathComponent("v1/draft") }
    static var meEndpoint: URL { baseURL.appendingPathComponent("v1/me") }
}

/// Supplies a fresh, short-lived account session token for authenticating
/// managed-inference requests. Implemented by `ManagedAccountService`, which
/// mints tokens from Clerk on demand. Kept as a protocol so `ManagedInferenceClient`
/// stays testable against a fake without any account plumbing.
struct ManagedSessionToken: Sendable, Equatable {
    let jwt: String
    /// Identifies the credential generation that minted this JWT. Providers that
    /// cannot track identities leave this nil and fall back to unconditional
    /// invalidation.
    let credentialIdentity: String?
}

protocol ManagedSessionProviding: Sendable {
    /// Returns a session token valid *now*. Throws `LLMError.managedNotSignedIn`
    /// when there is no signed-in account. Implementations are expected to mint a
    /// fresh token per call (session tokens are short-lived), so callers never
    /// cache the result.
    func currentSessionToken() async throws -> String

    /// Returns a session token plus the account credential identity that minted
    /// it, allowing later proxy 401s to invalidate only the matching account.
    func currentManagedSession() async throws -> ManagedSessionToken

    /// Invalidates stored managed-account credentials after an authentication
    /// failure from the proxy. Providers without persistent credentials can no-op.
    func invalidateSession() async

    /// Invalidates the credentials that minted a failed request, when the provider
    /// can prove the same credentials are still current.
    func invalidateSession(matching credentialIdentity: String?) async
}

extension ManagedSessionProviding {
    func currentManagedSession() async throws -> ManagedSessionToken {
        ManagedSessionToken(jwt: try await currentSessionToken(), credentialIdentity: nil)
    }

    func invalidateSession() async {}

    func invalidateSession(matching credentialIdentity: String?) async {
        await invalidateSession()
    }
}

/// A `ManagedSessionProviding` that always reports "not signed in". Used as the
/// default so a managed client constructed without an account wired in fails
/// with a clear, user-facing error instead of a crash.
struct UnavailableManagedSessionProvider: ManagedSessionProviding {
    func currentSessionToken() async throws -> String {
        throw LLMError.managedNotSignedIn
    }
}

/// `LLMClient` adapter for the Sentwise managed-inference proxy.
///
/// Mirrors `AnthropicClient` in shape, but authenticates with the account's
/// Clerk session token (Bearer) instead of a provider API key, and speaks the
/// thin `{ text, usage }` wire format the `sentwise-service` Worker returns.
struct ManagedInferenceClient: LLMClient {
    let sessionProvider: ManagedSessionProviding
    let transport: LLMHTTPTransport
    let endpoint: URL

    init(
        sessionProvider: ManagedSessionProviding,
        transport: LLMHTTPTransport,
        endpoint: URL = ManagedInference.draftEndpoint
    ) {
        self.sessionProvider = sessionProvider
        self.transport = transport
        self.endpoint = endpoint
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        // Mint a fresh session token for this request (tokens are short-lived).
        let session = try await sessionProvider.currentManagedSession()

        let body = try Self.encodeBody(request)
        let headers = [
            "authorization": "Bearer \(session.jwt)",
            "content-type": "application/json"
        ]

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
            throw Self.mapError(status: response.statusCode, body: response.body, headers: response)
        }
        return try Self.parse(response.body)
    }

    /// Fetches the account's current usage allotment from `GET /v1/me` (backlog
    /// item 56b). Returns `nil` when the Worker omits `quota` (older build).
    /// Throws the same mapped `LLMError`s as `complete` on failure.
    func fetchAccountQuota(meEndpoint: URL = ManagedInference.meEndpoint) async throws -> ManagedQuota? {
        let session = try await sessionProvider.currentManagedSession()
        let headers = [
            "authorization": "Bearer \(session.jwt)",
            "content-type": "application/json"
        ]

        let response: HTTPResponse
        do {
            response = try await transport.getJSON(meEndpoint, headers: headers)
        } catch {
            throw LLMError.transport(String(describing: error))
        }

        if response.statusCode == 401 {
            await sessionProvider.invalidateSession(matching: session.credentialIdentity)
        }
        guard response.isSuccess else {
            throw Self.mapError(status: response.statusCode, body: response.body, headers: response)
        }

        do {
            let decoded = try JSONDecoder().decode(AccountStatusBody.self, from: response.body)
            return decoded.quota
        } catch {
            throw LLMError.invalidResponse("Unexpected account status response shape. (\(error))")
        }
    }

    // MARK: - Wire format

    private static func encodeBody(_ request: LLMRequest) throws -> Data {
        let body = RequestBody(
            model: request.model,
            system: request.system,
            messages: request.messages.map { RequestBody.Message(role: $0.role.rawValue, content: $0.content) },
            maxTokens: request.maxTokens,
            temperature: request.temperature
        )
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw LLMError.invalidResponse("Couldn't encode the request. (\(error))")
        }
    }

    private static func parse(_ data: Data) throws -> LLMResponse {
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Unexpected response shape. (\(error))")
        }
        return LLMResponse(
            text: decoded.text,
            inputTokens: decoded.usage?.inputTokens,
            outputTokens: decoded.usage?.outputTokens,
            quota: decoded.quota
        )
    }

    /// Maps a structured Worker error into a clear, user-facing `LLMError`. The
    /// Worker's messages are already user-safe (no raw upstream detail), so we
    /// surface them directly; only the transport-level shape is translated. The
    /// full response is passed so metering errors can read the `Retry-After`
    /// header (backlog item 56b) in addition to the body.
    static func mapError(status: Int, body: Data, headers response: HTTPResponse) -> LLMError {
        let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body)
        let type = decoded?.error?.type ?? ""
        let message = decoded?.error?.message

        switch status {
        case 401:
            return .managedNotSignedIn
        case 402:
            return .managedTrialExpired(message ?? "Your Sentwise AI trial has ended.")
        case 429 where type == "quota_exceeded":
            return .managedQuotaExceeded(resetsAt: decoded?.error?.resolvedResetsAt)
        case 429:
            // Both "rate_limited" and any other 429 back off; prefer the body's
            // retryAfterSeconds, falling back to the Retry-After header.
            return .managedRateLimited(
                retryAfter: decoded?.error?.retryAfterSeconds ?? Self.retryAfterHeaderSeconds(response)
            )
        case 413:
            return .managedRequestTooLarge(
                message ?? "That transcript or thread is too large for one draft."
            )
        default:
            if type == "trial_expired" {
                return .managedTrialExpired(message ?? "Your Sentwise AI trial has ended.")
            }
            if type == "quota_exceeded" {
                return .managedQuotaExceeded(resetsAt: decoded?.error?.resolvedResetsAt)
            }
            if type == "rate_limited" {
                return .managedRateLimited(
                    retryAfter: decoded?.error?.retryAfterSeconds ?? Self.retryAfterHeaderSeconds(response)
                )
            }
            if type == "request_too_large" {
                return .managedRequestTooLarge(
                    message ?? "That transcript or thread is too large for one draft."
                )
            }
            return .http(status: status, message: message ?? "The drafting service returned an error.")
        }
    }

    /// Parses the `Retry-After` header (delta-seconds form) into an `Int`.
    private static func retryAfterHeaderSeconds(_ response: HTTPResponse) -> Int? {
        guard let raw = response.headerValue("Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Int(raw)
    }
}

/// A deterministic, zero-network managed client used in Prowl hunt mode so
/// hunts stay offline-safe (backlog 56a). Never touches the transport or the
/// session provider.
struct StubManagedInferenceClient: LLMClient {
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(
            text: "This is a canned Sentwise AI response for offline Prowl hunts.",
            inputTokens: 0,
            outputTokens: 0,
            quota: Self.stubbedQuota
        )
    }

    /// A plausible, fixed quota surfaced in Prowl hunt mode (backlog item 56b) so
    /// the usage display renders deterministically with zero network. Halfway
    /// through the week, soft enforcement, resets at a fixed instant.
    static var stubbedQuota: ManagedQuota {
        ManagedQuota(
            unit: "drafts",
            used: 25,
            limit: 50,
            remaining: 25,
            resetsAt: Date(timeIntervalSince1970: 1_756_512_000), // fixed, deterministic
            tokensUsed: 125_000,
            tokenLimit: 250_000,
            enforcement: .soft,
            extraPurchased: 0
        )
    }
}

// MARK: - Wire-format DTOs (file-private)

private struct RequestBody: Encodable {
    let model: String
    let system: String?
    let messages: [Message]
    let maxTokens: Int
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens
        case temperature
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ResponseBody: Decodable {
    let text: String
    let usage: Usage?
    /// Optional so older Worker builds (no metering) still decode (item 56b).
    let quota: ManagedQuota?

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
    }
}

/// `GET /v1/me` shape — only the `quota` block is consumed here; trial/account
/// fields are ignored for now (item 56b).
private struct AccountStatusBody: Decodable {
    let quota: ManagedQuota?
}

private struct ErrorBody: Decodable {
    let error: Detail?
    struct Detail: Decodable {
        let type: String?
        let message: String?
        /// Present on `429 rate_limited` (item 56b).
        let retryAfterSeconds: Int?
        /// Present on `429 quota_exceeded` (item 56b) — the window reset instant.
        let resetsAt: String?

        /// The parsed `resetsAt`, tolerating the fractional-seconds variant.
        var resolvedResetsAt: Date? {
            guard let resetsAt else { return nil }
            return ManagedQuotaDate.date(from: resetsAt)
        }
    }
}
