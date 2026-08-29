import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests the single source of truth mapping errors to a `FailureClass` (item 27).
/// The invariant under test: `sendInterruptedAfterSubmission` is *never* retryable.
final class ResilienceClassifierTests: XCTestCase {

    // MARK: - Mail

    func testPreDataConnectionFailureIsTransient() {
        XCTAssertEqual(ResilienceClassifier.classify(MailError.connectionFailed("reset")), .transient)
    }

    func testAmbiguousSendIsNeverRetryable() {
        let error = MailError.sendInterruptedAfterSubmission("dropped after DATA")
        XCTAssertEqual(ResilienceClassifier.classify(error), .ambiguousSend)
        XCTAssertFalse(ResilienceClassifier.isRetryable(error))
        XCTAssertEqual(ResilienceClassifier.retryDecision(for: error), .stop)
    }

    func testMailAuthFailureIsAuthentication() {
        XCTAssertEqual(ResilienceClassifier.classify(MailError.authenticationFailed("bad pw")), .authentication)
    }

    func testMailCommandFailureIsPermanent() {
        XCTAssertEqual(ResilienceClassifier.classify(MailError.commandFailed("no such user")), .permanent)
        XCTAssertEqual(ResilienceClassifier.classify(MailError.incompleteCredentials), .permanent)
        XCTAssertEqual(ResilienceClassifier.classify(MailError.resultTooLarge), .permanent)
    }

    func testSMTPTemporaryCommandFailuresAreTransient() {
        for code in [421, 450, 451, 452, 454] {
            XCTAssertEqual(
                ResilienceClassifier.classify(MailError.smtpCommandFailed(code: code, message: "")),
                .transient,
                "SMTP \(code) should be transient"
            )
        }
    }

    func testSMTPPermanentCommandFailuresStayPermanent() {
        XCTAssertEqual(
            ResilienceClassifier.classify(MailError.smtpCommandFailed(code: 550, message: "No such user")),
            .permanent
        )
    }

    // MARK: - LLM

    func testLLMTransportIsTransient() {
        XCTAssertEqual(ResilienceClassifier.classify(LLMError.transport("offline")), .transient)
    }

    func testLLMRetryableHTTPStatuses() {
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(
                ResilienceClassifier.classify(LLMError.http(status: status, message: "")),
                .transient,
                "HTTP \(status) should be transient"
            )
        }
    }

    func testLLMAuthHTTPStatuses() {
        for status in [401, 403] {
            XCTAssertEqual(
                ResilienceClassifier.classify(LLMError.http(status: status, message: "")),
                .authentication,
                "HTTP \(status) should be authentication"
            )
        }
    }

    func testLLMPermanentHTTPStatuses() {
        for status in [400, 404, 422] {
            XCTAssertEqual(
                ResilienceClassifier.classify(LLMError.http(status: status, message: "")),
                .permanent,
                "HTTP \(status) should be permanent"
            )
        }
    }

    func testLLMMissingKeyIsAuthentication() {
        XCTAssertEqual(ResilienceClassifier.classify(LLMError.missingAPIKey), .authentication)
    }

    func testManagedTrialExpiryIsAuthentication() {
        let error = LLMError.managedTrialExpired("Your Sentwise AI trial has ended.")
        XCTAssertEqual(ResilienceClassifier.classify(error), .authentication)
        XCTAssertFalse(ResilienceClassifier.isRetryable(error))
        XCTAssertEqual(ResilienceClassifier.retryDecision(for: error), .stop)
    }

    func testManagedRateLimitCarriesRetryAfterIntoRetryDecision() {
        let error = LLMError.managedRateLimited(retryAfter: 30)
        XCTAssertEqual(ResilienceClassifier.classify(error), .transient)
        XCTAssertTrue(ResilienceClassifier.isRetryable(error))
        XCTAssertEqual(ResilienceClassifier.retryDecision(for: error), .retryAfter(30_000_000_000))
    }

    func testManagedRateLimitWithoutRetryAfterUsesGenericRetry() {
        XCTAssertEqual(
            ResilienceClassifier.retryDecision(for: LLMError.managedRateLimited(retryAfter: nil)),
            .retry
        )
        XCTAssertEqual(
            ResilienceClassifier.retryDecision(for: LLMError.managedRateLimited(retryAfter: 0)),
            .retry
        )
    }

    func testKeychainFailuresAreAuthentication() {
        let error = KeychainError.unexpectedStatus(-1)
        XCTAssertEqual(ResilienceClassifier.classify(error), .authentication)
        XCTAssertFalse(ResilienceClassifier.isRetryable(error))
        XCTAssertEqual(ResilienceClassifier.retryDecision(for: error), .stop)
    }

    func testLLMInvalidResponseAndBaseURLArePermanent() {
        XCTAssertEqual(ResilienceClassifier.classify(LLMError.invalidResponse("garbage")), .permanent)
        XCTAssertEqual(ResilienceClassifier.classify(LLMError.invalidBaseURL("ftp://x")), .permanent)
    }

    // MARK: - Low-level network errors

    func testTransientURLErrors() {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost] {
            XCTAssertEqual(ResilienceClassifier.classify(URLError(code)), .transient, "\(code) should be transient")
        }
    }

    func testNonTransientURLErrorIsPermanent() {
        XCTAssertEqual(ResilienceClassifier.classify(URLError(.badURL)), .permanent)
    }

    func testTransientPOSIXErrors() {
        XCTAssertEqual(ResilienceClassifier.classify(POSIXError(.ECONNRESET)), .transient)
        XCTAssertEqual(ResilienceClassifier.classify(POSIXError(.ETIMEDOUT)), .transient)
    }

    func testUnknownErrorIsPermanent() {
        struct Mystery: Error {}
        XCTAssertEqual(ResilienceClassifier.classify(Mystery()), .permanent)
    }
}
