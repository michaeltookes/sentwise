import Foundation

/// One HTTP response from the Clerk Frontend API, including headers (we need the
/// rotated `Authorization` client token that Clerk returns on every response).
struct ClerkHTTPResponse: Sendable {
    let statusCode: Int
    /// Header fields with lowercased names.
    let headers: [String: String]
    let body: Data

    var isSuccess: Bool { (200..<300).contains(statusCode) }
    var clientToken: String? {
        guard let raw = headers["authorization"], !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("bearer ") {
            return String(raw.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }
}

/// A form-POST transport for the Clerk Frontend API. Split from the LLM/mail
/// transports because Clerk needs `application/x-www-form-urlencoded` bodies and,
/// crucially, exposes the response headers (for the rotating client token). Kept
/// as a protocol so `ClerkClient` is unit-testable against a fake.
protocol ClerkHTTPTransport: Sendable {
    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse
    /// A GET with the same header/rotating-token semantics. Clerk's OAuth
    /// completion *reloads* the sign-in (`GET /v1/client/sign_ins/{id}?rotating_token_nonce=…`)
    /// rather than posting to it.
    func get(_ url: URL, headers: [String: String]) async throws -> ClerkHTTPResponse
}

extension ClerkHTTPTransport {
    /// Default so lightweight test fakes that only queue responses keep working;
    /// the production transport overrides this with a real GET.
    func get(_ url: URL, headers: [String: String]) async throws -> ClerkHTTPResponse {
        try await postForm(url, headers: headers, form: [:])
    }
}

/// Production `ClerkHTTPTransport` over `URLSession`.
struct ClerkURLSessionTransport: ClerkHTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = Self.encodeForm(form).data(using: .utf8)
        return try await perform(request)
    }

    func get(_ url: URL, headers: [String: String]) async throws -> ClerkHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> ClerkHTTPResponse {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        var lowered: [String: String] = [:]
        for (key, value) in (http?.allHeaderFields ?? [:]) {
            if let name = key as? String, let stringValue = value as? String {
                lowered[name.lowercased()] = stringValue
            }
        }
        return ClerkHTTPResponse(statusCode: statusCode, headers: lowered, body: data)
    }

    static func encodeForm(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Results

/// A started email-code sign-in (or first-time sign-up) awaiting the user's OTP.
struct ClerkSignInHandle: Sendable, Equatable {
    /// Which Clerk flow produced this handle. A brand-new email has no Clerk user
    /// yet, so it goes through `sign_ups`; an existing one through `sign_ins`. The
    /// user experience (enter email → enter code) is identical either way.
    enum Flow: Sendable, Equatable { case signIn, signUp }

    /// The `sign_in` id (`.signIn`) or `sign_up` id (`.signUp`).
    let signInId: String
    let emailAddressId: String
    /// The latest device/client token, to be carried into the verify call.
    let clientToken: String
    var flow: Flow = .signIn
}

/// A started OAuth sign-in (e.g. Google) awaiting the browser round-trip. The
/// app opens `externalRedirectURL` in the default browser; Clerk completes the
/// external handshake and redirects back to the app's custom URL scheme with a
/// `rotating_token_nonce`, which the caller passes to `completeOAuthSignIn`.
struct ClerkOAuthHandle: Sendable, Equatable {
    let signInId: String
    /// The Clerk-hosted URL to open so the user authenticates with the provider.
    let externalRedirectURL: URL
    let clientToken: String
}

/// A completed sign-in: the created session plus the latest client token, and
/// the display identifier (email) when Clerk includes it — used by the OAuth
/// path, where the app doesn't otherwise know the email the user chose.
struct ClerkVerifiedSession: Sendable, Equatable {
    let sessionId: String
    let clientToken: String
    var identifier: String?
}

/// A freshly minted, short-lived session JWT plus the latest client token and
/// Clerk user id (`sub`) when it can be decoded from the JWT payload.
struct ClerkMintedToken: Sendable, Equatable {
    let jwt: String
    let clientToken: String
    let userID: String?
}

enum ClerkError: Error, Equatable, Sendable {
    /// Transport failure (offline, DNS, TLS).
    case transport(String, clientToken: String? = nil)
    /// The API returned a non-2xx with an optional user-facing message.
    case http(status: Int, message: String?, clientToken: String? = nil)
    /// A required field was missing from an otherwise-2xx response.
    case malformedResponse(String, clientToken: String? = nil)
    /// The sign-in didn't reach `complete` (e.g. needs a second factor we don't
    /// support in 56a).
    case notComplete(status: String?, missingFields: [String] = [], clientToken: String? = nil)
    /// No `email_code` first factor is available for this identifier.
    case emailCodeUnsupported
    /// Clerk has no user for this email (`form_identifier_not_found`); the caller
    /// falls back to the sign-up flow.
    case accountNotFound

    var clientToken: String? {
        switch self {
        case .transport(_, let clientToken),
             .http(_, _, let clientToken),
             .malformedResponse(_, let clientToken),
             .notComplete(_, _, let clientToken):
            return clientToken
        default:
            return nil
        }
    }

    func preservingClientToken(_ token: String?) -> ClerkError {
        guard let token, !token.isEmpty, clientToken == nil else { return self }
        switch self {
        case .transport(let detail, _):
            return .transport(detail, clientToken: token)
        case .http(let status, let message, _):
            return .http(status: status, message: message, clientToken: token)
        case .malformedResponse(let detail, _):
            return .malformedResponse(detail, clientToken: token)
        case .notComplete(let status, let missingFields, _):
            return .notComplete(status: status, missingFields: missingFields, clientToken: token)
        case .emailCodeUnsupported, .accountNotFound:
            return self
        }
    }
}

/// A minimal native client for Clerk's Frontend API email-code sign-in.
///
/// Implements Clerk's native (non-browser) mechanism: every request carries an
/// `Authorization: Bearer <clientToken>` header (empty on the very first call);
/// Clerk returns a rotated client token in the `Authorization` response header,
/// which the caller stores and echoes on the next call. No `Origin` header is
/// sent (that would put Clerk into browser mode). Google/OAuth sign-in is out of
/// scope for 56a — email code is the enabled primary method. See
/// `docs/managed-inference.md` for the rationale and live-verification note.
struct ClerkClient: Sendable {
    let frontendAPIBaseURL: URL
    let transport: ClerkHTTPTransport

    /// Clerk's default dev instance for Sentwise (peaceful-eel-9660).
    static let defaultFrontendAPIBaseURLString = "https://peaceful-eel-9660.clerk.accounts.dev"

    init(
        frontendAPIBaseURL: URL = URL(string: ClerkClient.defaultFrontendAPIBaseURLString)!,
        transport: ClerkHTTPTransport = ClerkURLSessionTransport()
    ) {
        self.frontendAPIBaseURL = frontendAPIBaseURL
        self.transport = transport
    }

    /// Starts an email-code sign-in and triggers the OTP email. Returns a handle
    /// the caller passes to `verifyEmailCode`.
    func sendEmailCode(email: String, clientToken: String) async throws -> ClerkSignInHandle {
        let created = try await createEmailCodeSignIn(email: email, clientToken: clientToken)
        return try await prepareEmailCode(for: created)
    }

    /// Creates the Clerk sign-in/sign-up resource but does not send the OTP yet.
    /// Callers that persist rotating client tokens should store the returned
    /// token before preparing the code, so a prepare failure does not strand the
    /// flow on an older token.
    func createEmailCodeSignIn(email: String, clientToken: String) async throws -> ClerkSignInHandle {
        // 1. Create the sign-in with the email identifier. A first-time user has
        //    no Clerk account yet, which Clerk reports as `form_identifier_not_found`;
        //    in that case create the account via the sign-up flow instead.
        let created = try await post(
            path: "v1/client/sign_ins",
            form: ["identifier": email],
            clientToken: clientToken
        )
        let createdResource: SignInResource
        do {
            createdResource = try Self.decodeSignIn(
                created.body,
                status: created.statusCode,
                clientToken: created.clientToken
            )
        } catch ClerkError.accountNotFound {
            let token = created.clientToken ?? clientToken
            do {
                return try await createSignUp(email: email, clientToken: token)
            } catch let error as ClerkError {
                throw error.preservingClientToken(token)
            }
        }
        let token = created.clientToken ?? clientToken

        guard let signInId = createdResource.id else {
            throw ClerkError.malformedResponse("sign_in id missing", clientToken: token)
        }
        guard let emailAddressId = createdResource.supportedFirstFactors?
            .first(where: { $0.strategy == "email_code" })?.emailAddressId
        else {
            throw ClerkError.emailCodeUnsupported
        }

        return ClerkSignInHandle(signInId: signInId, emailAddressId: emailAddressId, clientToken: token)
    }

    /// Sends the email code for an already-created sign-in/sign-up resource.
    func prepareEmailCode(for handle: ClerkSignInHandle) async throws -> ClerkSignInHandle {
        let path: String
        let form: [String: String]
        switch handle.flow {
        case .signIn:
            path = "v1/client/sign_ins/\(handle.signInId)/prepare_first_factor"
            form = ["strategy": "email_code", "email_address_id": handle.emailAddressId]
        case .signUp:
            path = "v1/client/sign_ups/\(handle.signInId)/prepare_verification"
            form = ["strategy": "email_code"]
        }

        let prepared = try await post(
            path: path,
            form: form,
            clientToken: handle.clientToken
        )
        let token = prepared.clientToken ?? handle.clientToken
        _ = try Self.decodeSignIn(
            prepared.body,
            status: prepared.statusCode,
            clientToken: token
        )

        return ClerkSignInHandle(
            signInId: handle.signInId,
            emailAddressId: handle.emailAddressId,
            clientToken: token,
            flow: handle.flow
        )
    }

    /// First-time users: create a Clerk account for the email. The caller then
    /// prepares verification to send the OTP.
    private func createSignUp(email: String, clientToken: String) async throws -> ClerkSignInHandle {
        let created = try await post(
            path: "v1/client/sign_ups",
            form: ["email_address": email],
            clientToken: clientToken
        )
        let createdResource = try Self.decodeSignIn(
            created.body,
            status: created.statusCode,
            clientToken: created.clientToken
        )
        let token = created.clientToken ?? clientToken
        guard let signUpId = createdResource.id else {
            throw ClerkError.malformedResponse("sign_up id missing", clientToken: token)
        }

        return ClerkSignInHandle(signInId: signUpId, emailAddressId: "", clientToken: token, flow: .signUp)
    }

    /// Submits the OTP code, completing the sign-in (or sign-up) and yielding a
    /// session id.
    func verifyEmailCode(
        signInId: String,
        code: String,
        clientToken: String,
        flow: ClerkSignInHandle.Flow = .signIn
    ) async throws -> ClerkVerifiedSession {
        let path: String
        switch flow {
        case .signIn: path = "v1/client/sign_ins/\(signInId)/attempt_first_factor"
        case .signUp: path = "v1/client/sign_ups/\(signInId)/attempt_verification"
        }
        let attempted = try await post(
            path: path,
            form: ["strategy": "email_code", "code": code],
            clientToken: clientToken
        )
        let token = attempted.clientToken ?? clientToken
        let resource = try Self.decodeSignIn(
            attempted.body,
            status: attempted.statusCode,
            clientToken: token
        )

        guard resource.status == "complete", let sessionId = resource.createdSessionId else {
            throw ClerkError.notComplete(
                status: resource.status,
                missingFields: resource.missingFields ?? [],
                clientToken: token
            )
        }
        return ClerkVerifiedSession(sessionId: sessionId, clientToken: token)
    }

    // MARK: - OAuth (Google) sign-in

    /// Starts an OAuth sign-in (e.g. `oauth_google`). Creates the Clerk sign-in
    /// with the external strategy and the app's `redirectURL`; Clerk responds with
    /// a hosted URL to open in the browser. The user completes the provider
    /// handshake there and Clerk redirects back to `redirectURL` with a
    /// `rotating_token_nonce`, which `completeOAuthSignIn` exchanges for a session.
    func startOAuthSignIn(
        strategy: String,
        redirectURL: String,
        clientToken: String
    ) async throws -> ClerkOAuthHandle {
        let created = try await post(
            path: "v1/client/sign_ins",
            form: ["strategy": strategy, "redirect_url": redirectURL],
            clientToken: clientToken
        )
        let token = created.clientToken ?? clientToken
        let resource = try Self.decodeSignIn(created.body, status: created.statusCode, clientToken: token)
        guard let signInId = resource.id else {
            throw ClerkError.malformedResponse("sign_in id missing", clientToken: token)
        }
        guard let redirect = resource.firstFactorVerification?.externalVerificationRedirectURL,
              let url = URL(string: redirect) else {
            throw ClerkError.malformedResponse("external verification redirect url missing", clientToken: token)
        }
        return ClerkOAuthHandle(signInId: signInId, externalRedirectURL: url, clientToken: token)
    }

    /// Completes an OAuth sign-in after the browser redirect. Reloads the sign-in
    /// resource with the `rotating_token_nonce` Clerk handed back; a successful
    /// external handshake leaves it `complete` with a `created_session_id`.
    func completeOAuthSignIn(
        signInId: String,
        rotatingTokenNonce: String,
        clientToken: String
    ) async throws -> ClerkVerifiedSession {
        let reloaded = try await get(
            path: "v1/client/sign_ins/\(signInId)",
            clientToken: clientToken,
            extraQuery: [URLQueryItem(name: "rotating_token_nonce", value: rotatingTokenNonce)]
        )
        let token = reloaded.clientToken ?? clientToken
        let resource = try Self.decodeSignIn(reloaded.body, status: reloaded.statusCode, clientToken: token)
        guard resource.status == "complete", let sessionId = resource.createdSessionId else {
            throw ClerkError.notComplete(
                status: resource.status,
                missingFields: resource.missingFields ?? [],
                clientToken: token
            )
        }
        return ClerkVerifiedSession(sessionId: sessionId, clientToken: token, identifier: resource.identifier)
    }

    /// Mints a fresh, short-lived session JWT for the given session. This is the
    /// token the `sentwise-service` Worker verifies. Refresh by calling again.
    func mintSessionToken(sessionId: String, clientToken: String) async throws -> ClerkMintedToken {
        let response = try await post(
            path: "v1/client/sessions/\(sessionId)/tokens",
            form: [:],
            clientToken: clientToken
        )
        guard response.isSuccess else {
            throw ClerkError.http(
                status: response.statusCode,
                message: Self.firstErrorMessage(response.body),
                clientToken: response.clientToken
            )
        }
        let decoded = try? JSONDecoder().decode(TokenEnvelope.self, from: response.body)
        guard let jwt = decoded?.jwt, !jwt.isEmpty else {
            throw ClerkError.malformedResponse("session token jwt missing", clientToken: response.clientToken)
        }
        return ClerkMintedToken(jwt: jwt, clientToken: response.clientToken ?? clientToken, userID: ClerkJWT.subject(from: jwt))
    }

    // MARK: - Internals

    private func post(
        path: String,
        form: [String: String],
        clientToken: String,
        extraQuery: [URLQueryItem] = []
    ) async throws -> ClerkHTTPResponse {
        let url = Self.buildURL(base: frontendAPIBaseURL, path: path, extraQuery: extraQuery)
        // Native mode: send the Authorization header (never an Origin header).
        let headers = ["authorization": "Bearer \(clientToken)"]
        do {
            return try await transport.postForm(url, headers: headers, form: form)
        } catch {
            throw ClerkError.transport(String(describing: error))
        }
    }

    private func get(path: String, clientToken: String, extraQuery: [URLQueryItem]) async throws -> ClerkHTTPResponse {
        let url = Self.buildURL(base: frontendAPIBaseURL, path: path, extraQuery: extraQuery)
        let headers = ["authorization": "Bearer \(clientToken)"]
        do {
            return try await transport.get(url, headers: headers)
        } catch {
            throw ClerkError.transport(String(describing: error))
        }
    }

    static func buildURL(base: URL, path: String, extraQuery: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        // Mark the request as native so Clerk uses header-token auth, not cookies.
        components?.queryItems = [URLQueryItem(name: "_is_native", value: "1")] + extraQuery
        return components?.url ?? base.appendingPathComponent(path)
    }

    private static func decodeSignIn(_ data: Data, status: Int, clientToken: String? = nil) throws -> SignInResource {
        let envelope = try? JSONDecoder().decode(SignInEnvelope.self, from: data)
        guard (200..<300).contains(status) else {
            if envelope?.errors?.contains(where: { $0.code == "form_identifier_not_found" }) == true {
                throw ClerkError.accountNotFound
            }
            throw ClerkError.http(
                status: status,
                message: envelope?.errors?.first?.longMessage
                    ?? envelope?.errors?.first?.message
                    ?? firstErrorMessage(data),
                clientToken: clientToken
            )
        }
        guard let resource = envelope?.response else {
            throw ClerkError.malformedResponse("missing response object", clientToken: clientToken)
        }
        return resource
    }

    private static func firstErrorMessage(_ data: Data) -> String? {
        let envelope = try? JSONDecoder().decode(ErrorsEnvelope.self, from: data)
        return envelope?.errors?.first?.longMessage ?? envelope?.errors?.first?.message
    }
}
