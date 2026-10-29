import Foundation

/// Exchanges authorization codes for tokens and refreshes access tokens against
/// Google's token endpoint. Pure logic over an injectable `HTTPTransport`.
struct OAuthTokenService {
    let transport: HTTPTransport

    /// Exchanges an authorization code (with its PKCE verifier) for a token set.
    /// An omitted scope means the grant matches the authorization request.
    func exchange( // swiftlint:disable:this function_parameter_count
        code: String,
        verifier: String,
        client: OAuthProviderConfiguration,
        redirectURI: String,
        requestedScopes: [String],
        now: Date
    ) async throws -> OAuthToken {
        let response = try await transport.postForm(client.tokenEndpoint, fields: Self.withClient(client, [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ]))
        return try token(
            from: response, phase: .exchange, now: now, fallbackRefreshToken: nil,
            fallbackScope: requestedScopes.joined(separator: " ")
        )
    }

    /// Refreshes an access token using a refresh token. Google does not return a
    /// new refresh token on refresh, so the existing one is carried forward;
    /// Microsoft rotates it, and the rotated token in the response replaces the
    /// old one (the caller persists the returned token as a whole, so the old
    /// refresh token is never used again).
    /// An omitted scope also carries forward the previously granted scopes.
    func refresh(
        refreshToken: String,
        grantedScope: String = "",
        client: OAuthProviderConfiguration,
        now: Date
    ) async throws -> OAuthToken {
        let response = try await transport.postForm(client.tokenEndpoint, fields: Self.withClient(client, [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]))
        return try token(
            from: response, phase: .refresh, now: now,
            fallbackRefreshToken: refreshToken, fallbackScope: grantedScope
        )
    }

    /// Revokes a token at Google (refresh tokens revoke the whole grant).
    /// Google answers 200 on success and 400 for an already-invalid token; both
    /// leave nothing to clean up, so only transport errors throw.
    /// A provider without a revocation endpoint has nothing to revoke.
    func revoke(token: String, client: OAuthProviderConfiguration) async throws {
        guard let endpoint = client.revocationEndpoint else { return }
        _ = try await transport.postForm(endpoint, fields: ["token": token])
    }

    /// Adds the client identity. The secret is sent only when the build has
    /// one (Google "Desktop app" clients require it at the token endpoint).
    static func withClient(
        _ client: OAuthProviderConfiguration,
        _ fields: [String: String]
    ) -> [String: String] {
        var fields = fields
        fields["client_id"] = client.clientID
        if let secret = client.clientSecret {
            fields["client_secret"] = secret
        }
        return fields
    }

    // MARK: - Response parsing

    private func token(
        from response: HTTPResponse,
        phase: OAuthErrorMapping.Phase,
        now: Date,
        fallbackRefreshToken: String?,
        fallbackScope: String = ""
    ) throws -> OAuthToken {
        guard response.isSuccess else {
            // 5xx/429 are outages and throttling, never a verdict on the grant,
            // even when Google includes an error body.
            if OAuthError.isTransientHTTPStatus(response.statusCode) {
                throw OAuthError.temporarilyUnavailable(httpStatus: response.statusCode)
            }
            if let error = try? JSONDecoder().decode(TokenErrorResponse.self, from: response.body) {
                throw OAuthErrorMapping.tokenEndpointError(
                    code: error.error,
                    description: error.errorDescription,
                    errorCodes: error.errorCodes ?? [],
                    phase: phase
                )
            }
            throw OAuthError.invalidResponse
        }

        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
            throw OAuthError.invalidResponse
        }

        return OAuthToken(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? fallbackRefreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(decoded.expiresIn)),
            scope: decoded.scope ?? fallbackScope,
            tokenType: decoded.tokenType ?? "Bearer",
            idToken: decoded.idToken
        )
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String?
        let tokenType: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
            case idToken = "id_token"
        }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
        let errorDescription: String?
        /// Microsoft lists the numeric AADSTS codes here.
        let errorCodes: [Int]?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case errorCodes = "error_codes"
        }
    }
}
