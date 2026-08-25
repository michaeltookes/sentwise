import NIOEmbedded
import XCTest
@testable import SentwiseMail

/// Tests the `MailProvider` seam via a fake. The real `IMAPMailProvider` network
/// path is verified live (it needs a real server), so these cover the contract
/// and the incomplete-credentials guard shared by callers.
final class MailProviderTests: XCTestCase {

    func testFakeProviderReceivesCredentials() async throws {
        let provider = FakeMailProvider(result: .success(()))
        let credentials = MailAccountCredentials(email: "me@gmail.com", appPassword: "pw")

        try await provider.verifyConnection(credentials)

        XCTAssertEqual(provider.verifiedCredentials, credentials)
    }

    func testFakeProviderPropagatesFailure() async {
        let provider = FakeMailProvider(result: .failure(.authenticationFailed("bad")))
        do {
            try await provider.verifyConnection(
                MailAccountCredentials(email: "me@gmail.com", appPassword: "pw")
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MailError, .authenticationFailed("bad"))
        }
    }

    func testVerificationAttemptsAreScopedPerChannel() throws {
        let attempts = ChannelPromiseTracker<Void>()
        let firstChannel = EmbeddedChannel()
        let secondChannel = EmbeddedChannel()
        let firstComplete = attempts.register(firstChannel)
        let secondComplete = attempts.register(secondChannel)

        let firstFuture = try XCTUnwrap(attempts.future(for: firstChannel))
        let secondFuture = try XCTUnwrap(attempts.future(for: secondChannel))

        // Each channel's completion settles only that channel's future.
        firstComplete(.failure(MailError.connectionFailed("lost race")))
        secondComplete(.success(()))

        XCTAssertNoThrow(try secondFuture.wait())
        XCTAssertThrowsError(try firstFuture.wait()) { error in
            XCTAssertEqual(error as? MailError, .connectionFailed("lost race"))
        }

        // Both promises are already claimed, so nothing is left to fail.
        attempts.failRemaining(MailError.connectionFailed("superseded"))
        _ = try firstChannel.finish()
        _ = try secondChannel.finish()
    }
}

/// A `MailProvider` fake for tests: records the credentials and returns a canned
/// result.
final class FakeMailProvider: MailProvider, @unchecked Sendable {
    private let result: Result<Void, MailError>
    private(set) var verifiedCredentials: MailAccountCredentials?

    init(result: Result<Void, MailError>) {
        self.result = result
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {
        verifiedCredentials = credentials
        try result.get()
    }

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        []
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        Data()
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}
}
