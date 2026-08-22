import XCTest
@testable import Sentwise

/// Env-gated live end-to-end email-code sign-in against the **real Clerk dev
/// instance** (`peaceful-eel-9660.clerk.accounts.dev`) via the Frontend API,
/// exercising the real `ClerkClient`. SKIPS unless `SENTWISE_LIVE_CLERK_TEST` is
/// set, so CI and normal `xcodebuild test` runs stay fully offline.
///
/// ## Clerk's test-email mechanism (verified against the docs)
///
/// Docs: https://clerk.com/docs/testing/test-emails-and-phones
/// - Any address using the **`+clerk_test`** subaddress is a test address
///   (e.g. `jane+clerk_test@example.com`). **No email is sent.**
/// - The **fixed verification code `424242`** always verifies a test email.
/// - It needs **no real inbox** and **no Clerk secret key** — the Frontend API
///   authenticates with the public (publishable) instance, exactly as the app's
///   native flow does. So the test is deterministic and hard-codes no secret.
///
/// The dev instance must have email-code sign-in on and Password/Organizations
/// off (already configured — see docs/managed-inference.md "Live verification").
/// A brand-new test email goes through Clerk's sign-up flow (which `ClerkClient`
/// handles transparently); a re-run signs in. Both end `status=complete`.
///
/// Google and OpenRouter are intentionally NOT tested live — their browser
/// round-trips are not automatable from a headless test. See the note at the end.
final class ClerkLiveSignInTests: XCTestCase {

    /// A deterministic Clerk test email. `+clerk_test` triggers test mode; the
    /// stable local part means repeated runs reuse the same test user. The domain
    /// is irrelevant (no mail is sent), so we use our own to avoid a stranger's.
    private static let testEmail = "sentwise-live+clerk_test@sentwise.ai"
    /// Clerk's universal test verification code.
    private static let testCode = "424242"

    private func requireLive() throws {
        let flag = ProcessInfo.processInfo.environment["SENTWISE_LIVE_CLERK_TEST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard flag == "1" || flag == "true" || flag == "yes" else {
            throw XCTSkip("Set SENTWISE_LIVE_CLERK_TEST=1 to run the live Clerk email-code sign-in test.")
        }
    }

    func testLiveEmailCodeSignInCompletesSession() async throws {
        try requireLive()

        // Real ClerkClient against the default dev instance — no secret key.
        let clerk = ClerkClient()

        // Create the sign-in (transparently falls back to sign-up for a new test
        // email) and trigger the (suppressed) code email.
        let handle = try await clerk.sendEmailCode(email: Self.testEmail, clientToken: "")

        // Attempt with the universal test code and assert a completed session.
        let verified = try await clerk.verifyEmailCode(
            signInId: handle.signInId,
            code: Self.testCode,
            clientToken: handle.clientToken,
            flow: handle.flow
        )
        XCTAssertFalse(verified.sessionId.isEmpty, "expected a created session id")

        // Prove the session can mint a token — the credential the proxy verifies.
        let minted = try await clerk.mintSessionToken(
            sessionId: verified.sessionId,
            clientToken: verified.clientToken
        )
        XCTAssertFalse(minted.jwt.isEmpty, "expected a minted session JWT")
    }
}
