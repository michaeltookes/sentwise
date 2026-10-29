import SentwiseMail
import XCTest
@testable import Sentwise

/// Typed OAuth error mapping (sign-in-first architecture 4.6, TC-M6-09/10):
/// every row of the table, the exchange-versus-refresh distinction, the IMAP
/// reclassification, and refresh-token rotation persistence.
@MainActor
final class OAuthErrorMappingTests: XCTestCase {

    private typealias Mapping = OAuthErrorMapping

    // MARK: - Admin consent

    func testAdminConsentCodesMapOnBothPhases() {
        for code in [65001, 90094, 90095] {
            for phase in [Mapping.Phase.exchange, .refresh] {
                let error = Mapping.tokenEndpointError(
                    code: "invalid_grant",
                    description: "AADSTS\(code): Need admin approval. Trace ID: abc",
                    phase: phase, tenantID: "tid-1"
                )
                XCTAssertEqual(error, .adminConsentRequired(tenantID: "tid-1"), "AADSTS\(code) \(phase)")
            }
        }
    }

    func testConsentRequiredErrorCodeAndErrorCodesArrayMapToAdminConsent() {
        XCTAssertEqual(
            Mapping.tokenEndpointError(code: "consent_required", description: nil, phase: .exchange),
            .adminConsentRequired(tenantID: nil)
        )
        XCTAssertEqual(
            Mapping.tokenEndpointError(code: "invalid_grant", description: "no code in text", errorCodes: [90094], phase: .exchange),
            .adminConsentRequired(tenantID: nil)
        )
    }

    func testRedirectErrorsMapAdminConsentAndKeepCancellation() {
        XCTAssertEqual(
            Mapping.redirectError(code: "access_denied", description: "AADSTS90094: admin approval required"),
            .adminConsentRequired(tenantID: nil)
        )
        XCTAssertEqual(Mapping.redirectError(code: "consent_required", description: nil), .adminConsentRequired(tenantID: nil))
        XCTAssertEqual(
            Mapping.redirectError(code: "access_denied", description: "The user denied access"),
            .authorizationDenied("access_denied")
        )
        XCTAssertEqual(Mapping.redirectError(code: "access_denied", description: nil), .authorizationDenied("access_denied"))
    }

    // MARK: - Re-authentication

    func testReauthenticationCodesMapOnRefresh() {
        for code in [50173, 70000, 70008, 50076, 50079, 53003, 50158] {
            let error = Mapping.tokenEndpointError(
                code: "invalid_grant", description: "AADSTS\(code): sign in again", phase: .refresh
            )
            XCTAssertEqual(error, .reauthenticationRequired, "AADSTS\(code)")
        }
    }

    func testInvalidGrantAndInteractionRequiredOnRefreshMapToReauthentication() {
        for code in ["invalid_grant", "interaction_required"] {
            XCTAssertEqual(
                Mapping.tokenEndpointError(code: code, description: nil, phase: .refresh),
                .reauthenticationRequired, code
            )
        }
    }

    func testInvalidGrantOnExchangeStaysAServerError() {
        XCTAssertEqual(
            Mapping.tokenEndpointError(code: "invalid_grant", description: "bad code", phase: .exchange),
            .server(code: "invalid_grant", description: "bad code")
        )
    }

    func testUnmappedErrorsStayServerErrors() {
        for phase in [Mapping.Phase.exchange, .refresh] {
            XCTAssertEqual(
                Mapping.tokenEndpointError(code: "invalid_client", description: "AADSTS700016: not found", phase: phase),
                .server(code: "invalid_client", description: "AADSTS700016: not found")
            )
        }
    }

    func testAADSTSCodeParsingFindsEveryCodeInText() {
        XCTAssertEqual(Mapping.aadstsCodes(in: "AADSTS50076: MFA. also AADSTS65001 here"), [50076, 65001])
        XCTAssertEqual(Mapping.aadstsCodes(in: nil, listed: [1, 2]), [1, 2])
        XCTAssertEqual(Mapping.aadstsCodes(in: "AADSTS without digits"), [])
    }

    // MARK: - Mailbox protocol disabled

    func testFreshTokenRejectedByIMAPMeansTheProtocolIsDisabled() {
        let result = MailboxProtocolMapping.classifyIMAPAuthenticationFailure(
            .authenticationFailed("AUTHENTICATE failed"), tokenAge: 5
        )
        XCTAssertEqual(result, .mailboxProtocolDisabled(.imap, "AUTHENTICATE failed"))
    }

    func testOldTokenOrOtherErrorsAreNotReclassified() {
        let auth = MailError.authenticationFailed("expired")
        XCTAssertEqual(MailboxProtocolMapping.classifyIMAPAuthenticationFailure(auth, tokenAge: 3600), auth)
        XCTAssertEqual(
            MailboxProtocolMapping.classifyIMAPAuthenticationFailure(auth, tokenAge: MailboxProtocolMapping.freshTokenWindow),
            auth
        )
        let other = MailError.connectionFailed("offline")
        XCTAssertEqual(MailboxProtocolMapping.classifyIMAPAuthenticationFailure(other, tokenAge: 1), other)
    }

    func testImapAndSmtpDisabledAreDistinctPermanentErrors() {
        let imap = MailError.mailboxProtocolDisabled(.imap, "x")
        let smtp = MailError.mailboxProtocolDisabled(.smtp, "x")
        XCTAssertNotEqual(imap, smtp)
        XCTAssertEqual(ResilienceClassifier.classify(imap), ResilienceClassifier.classify(smtp))
    }

    // MARK: - Refresh-token rotation persistence

    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let email = "me@contoso.com"
    private let grantedScopes = "\(MicrosoftOAuth.imapScope) \(MicrosoftOAuth.smtpScope) openid profile email"

    private func rotationHarness(
        _ responses: [HTTPResponse]
    ) throws -> (GmailAuthCoordinator, GmailAuthStore, FakeTransport) {
        let configuration = OAuthProviderConfiguration.microsoft(clientID: "client-id")
        let store = GmailAuthStore(secrets: InMemorySecretStore(), configuration: configuration)
        try store.saveToken(OAuthToken(
            accessToken: "stale", refreshToken: "rt-1", expiresAt: now.addingTimeInterval(-10),
            scope: grantedScopes, tokenType: "Bearer"
        ), for: email)
        let transport = FakeTransport(response: HTTPResponse(statusCode: 400, body: Data("{}".utf8)))
        transport.responses = responses
        let coordinator = GmailAuthCoordinator(
            client: configuration, store: store,
            tokenService: OAuthTokenService(transport: transport), now: { self.now }
        )
        return (coordinator, store, transport)
    }

    private func response(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(json.utf8))
    }

    func testRotatedRefreshTokenReplacesTheStoredOneAndIsUsedNext() async throws {
        let scope = grantedScopes
        let (coordinator, store, transport) = try rotationHarness([
            response(#"{"access_token":"at1","refresh_token":"rt-2","expires_in":60,"scope":"\#(scope)"}"#),
            response(#"{"access_token":"at2","refresh_token":"rt-3","expires_in":3600,"scope":"\#(scope)"}"#)
        ])

        let first = try await coordinator.validAccessToken(for: email)
        XCTAssertEqual(first, "at1")
        XCTAssertEqual(try store.loadToken(for: email)?.refreshToken, "rt-2", "the rotated token replaces the old one")

        // The 60 s lifetime is inside the expiry skew, so the next call refreshes again, with rt-2.
        let second = try await coordinator.validAccessToken(for: email)
        XCTAssertEqual(second, "at2")
        XCTAssertEqual(try store.loadToken(for: email)?.refreshToken, "rt-3")
        XCTAssertEqual(transport.requests.map { $0.fields["refresh_token"] }, ["rt-1", "rt-2"], "an old refresh token is never reused")
    }

    func testFailedRefreshKeepsTheStoredTokenUntouched() async throws {
        let (coordinator, store, _) = try rotationHarness([
            response(#"{"error":"invalid_grant","error_description":"AADSTS70008: expired"}"#, status: 400)
        ])
        do {
            _ = try await coordinator.validAccessToken(for: email)
            XCTFail("expected re-authorization")
        } catch {
            XCTAssertEqual(error as? GmailAuthError, .reauthorizationRequired)
        }
        XCTAssertEqual(try store.loadToken(for: email)?.refreshToken, "rt-1")
    }

    func testMicrosoftTokensLiveInTheirOwnKeychainNamespace() async throws {
        let secrets = InMemorySecretStore()
        let microsoft = GmailAuthStore(secrets: secrets, configuration: .microsoft(clientID: "client-id"))
        let google = GmailAuthStore(secrets: secrets)
        try microsoft.saveToken(OAuthToken(
            accessToken: "a", refreshToken: "r", expiresAt: now, scope: grantedScopes, tokenType: "Bearer"
        ), for: email)
        XCTAssertNil(try google.loadToken(for: email))
        XCTAssertNotNil(try microsoft.loadToken(for: email))
    }
}
