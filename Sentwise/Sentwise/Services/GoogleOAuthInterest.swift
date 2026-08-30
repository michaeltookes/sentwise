import CryptoKit
import Foundation

/// Registers demand for reviving the bundled "Sign in with Google" (OAuth + CASA)
/// path (item 75, feeding the parked item 3 decision). Behind a protocol so
/// `AppState` can be tested with a fake that records calls and simulates failures
/// without any network.
protocol GoogleOAuthInterestRegistering: Sendable {
    /// Posts the interest signal for `topic` under the managed account session.
    /// Throws on transport or auth failure; returns normally on the Worker's
    /// `204 No Content`.
    func registerInterest(topic: String) async throws
}

/// `GoogleOAuthInterestRegistering` calling the managed service's
/// `POST /v1/interest` (item 75). Mirrors `ManagedInferenceClient`'s shape:
/// authenticates with a fresh Clerk session token (Bearer), sends a tiny JSON
/// body, and maps the shared error envelope. The service half is built in
/// parallel to this exact contract — `204` on success, `401` when unauthenticated.
struct GoogleOAuthInterestClient: GoogleOAuthInterestRegistering {
    let sessionProvider: ManagedSessionProviding
    let transport: LLMHTTPTransport
    let endpoint: URL

    init(
        sessionProvider: ManagedSessionProviding,
        transport: LLMHTTPTransport,
        endpoint: URL = ManagedInference.interestEndpoint
    ) {
        self.sessionProvider = sessionProvider
        self.transport = transport
        self.endpoint = endpoint
    }

    func registerInterest(topic: String) async throws {
        let session = try await sessionProvider.currentManagedSession()
        let headers = [
            "authorization": "Bearer \(session.jwt)",
            "content-type": "application/json"
        ]
        let body: Data
        do {
            body = try JSONEncoder().encode(InterestBody(topic: topic))
        } catch {
            throw LLMError.invalidResponse("Couldn't encode the interest request. (\(error))")
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
            throw ManagedInferenceClient.mapError(
                status: response.statusCode,
                body: response.body,
                headers: response
            )
        }
    }

    private struct InterestBody: Encodable {
        let topic: String
    }
}

/// Local, durable record of which managed accounts have already registered
/// interest, so the capture button isn't re-offered after a click (item 75).
/// Keyed by a hashed account id (never the email), matching the usage-alert
/// store's privacy stance. Injectable so the state machine is unit-testable.
protocol GoogleOAuthInterestStoring: AnyObject, Sendable {
    func isRegistered(accountKey: String) -> Bool
    func markRegistered(accountKey: String)
}

/// A `UserDefaults`-backed interest store. Persistence is intentionally light —
/// this is a per-viewer "don't re-offer" flag, not shared or reconstructable
/// state — so it follows the `UserDefaultsUsageAlertStore` pattern rather than a
/// Settings-schema migration.
final class UserDefaultsGoogleOAuthInterestStore: GoogleOAuthInterestStoring, @unchecked Sendable {
    static let defaultsKey = "googleOAuthInterestRegisteredAccounts"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = UserDefaultsGoogleOAuthInterestStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func isRegistered(accountKey: String) -> Bool {
        registeredKeys().contains(accountKey)
    }

    func markRegistered(accountKey: String) {
        var keys = registeredKeys()
        guard !keys.contains(accountKey) else { return }
        keys.insert(accountKey)
        defaults.set(Array(keys), forKey: key)
    }

    private func registeredKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
