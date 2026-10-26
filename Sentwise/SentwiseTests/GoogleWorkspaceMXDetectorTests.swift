import Foundation
import XCTest
@testable import Sentwise

final class GoogleWorkspaceMXDetectorTests: XCTestCase {
    func testGoogleMXPatternsMatch() {
        XCTAssertTrue(GoogleWorkspaceMXDetector.containsGoogleMailExchange([
            "aspmx.l.google.com.",
            "alt1.aspmx.l.googlemail.com"
        ]))
        XCTAssertFalse(GoogleWorkspaceMXDetector.containsGoogleMailExchange([
            "google.com.evil.example"
        ]))
    }

    func testNonGoogleMXFallsThrough() async {
        let resolver = MXResolverStub(result: .success(["mx1.example.net."]))
        let detector = GoogleWorkspaceMXDetector(resolver: resolver)

        let isGoogleHosted = await detector.isGoogleHosted(domain: "example.com")

        XCTAssertFalse(isGoogleHosted)
    }

    func testLookupFailureFallsThrough() async {
        let resolver = MXResolverStub(result: .failure(MXResolverStub.Failure.expected))
        let detector = GoogleWorkspaceMXDetector(resolver: resolver)

        let isGoogleHosted = await detector.isGoogleHosted(domain: "example.com")

        XCTAssertFalse(isGoogleHosted)
    }

    func testLookupTimeoutFallsThrough() async {
        let resolver = MXResolverStub(result: .success(["aspmx.l.google.com"]), delayNanoseconds: 5_000_000_000)
        let detector = GoogleWorkspaceMXDetector(resolver: resolver, timeoutNanoseconds: 1_000_000)
        let clock = ContinuousClock()
        let started = clock.now

        let isGoogleHosted = await detector.isGoogleHosted(domain: "slow.example")

        XCTAssertFalse(isGoogleHosted)
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(500))
    }

    func testCallerCancellationDoesNotCacheNegativeResult() async {
        let resolver = CancellationThenSuccessMXResolver()
        let detector = GoogleWorkspaceMXDetector(resolver: resolver)
        let firstLookup = Task {
            await detector.isGoogleHosted(domain: "workspace.example")
        }
        while await resolver.callCount == 0 {
            await Task.yield()
        }

        firstLookup.cancel()
        let cancelledResult = await firstLookup.value
        let retriedResult = await detector.isGoogleHosted(domain: "workspace.example")
        let callCount = await resolver.callCount

        XCTAssertFalse(cancelledResult)
        XCTAssertTrue(retriedResult)
        XCTAssertEqual(callCount, 2)
    }

    func testSessionCacheAvoidsSecondLookup() async {
        let resolver = MXResolverStub(result: .success(["aspmx.l.google.com."]))
        let detector = GoogleWorkspaceMXDetector(resolver: resolver)

        let first = await detector.isGoogleHosted(domain: "Workspace.Example")
        let second = await detector.isGoogleHosted(domain: "workspace.example")

        let callCount = await resolver.callCount
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testResolverNeverRunsOnMainThread() async {
        let resolver = MXResolverStub(result: .success(["aspmx.l.google.com."]))
        let detector = GoogleWorkspaceMXDetector(resolver: resolver)

        let isGoogleHosted = await detector.isGoogleHosted(domain: "workspace.example")

        let didRunOnMainThread = await resolver.didRunOnMainThread
        XCTAssertTrue(isGoogleHosted)
        XCTAssertFalse(didRunOnMainThread)
    }

    func testGoogleResultPrefillsGmailHostAndGuidanceForCustomDomain() {
        var form = MailAccountFormState()
        form.updateEmailFromUser("marcus@company.example")

        form.applyGoogleWorkspaceSuggestion(for: "company.example")

        XCTAssertEqual(form.host, "imap.gmail.com")
        XCTAssertEqual(form.credentialGuidanceHostFallback, "imap.gmail.com")
    }

    func testDetectedFormDomainKeepsGmailHostOnCommit() {
        var form = MailAccountFormState()
        form.updateEmailFromUser("marcus@company.example")
        form.applyGoogleWorkspaceSuggestion(for: "company.example")

        form.commitEmailEditFromUser()

        XCTAssertEqual(form.host, "imap.gmail.com")
        XCTAssertEqual(form.credentialGuidanceHostFallback, "imap.gmail.com")
    }

    func testIncompleteFormDomainDoesNotUseGmailGuidance() {
        var form = MailAccountFormState()
        form.updateEmailFromUser("marcus@company")

        XCTAssertNil(form.credentialGuidanceHostFallback)
    }

    @MainActor
    func testDetectedAppStateDomainKeepsGmailHostOnCommit() async {
        let resolver = MXResolverStub(result: .success(["aspmx.l.google.com."]))
        let detector = GoogleWorkspaceMXDetector(resolver: resolver)
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore(),
            googleWorkspaceMXDetector: detector
        )
        appState.updateMailEmailFromUser("marcus@company.example")
        await appState.detectGoogleWorkspaceHost(for: appState.mailEmail)

        appState.commitMailEmailEditFromUser()

        XCTAssertEqual(appState.mailHost, "imap.gmail.com")
        XCTAssertEqual(appState.credentialGuidanceHostFallback, "imap.gmail.com")
    }

    @MainActor
    func testIncompleteAppStateDomainDoesNotUseGmailGuidance() {
        let appState = AppState(
            persistence: AppStateMemoryPersistence(),
            secrets: InMemorySecretStore()
        )
        appState.updateMailEmailFromUser("marcus@company")

        XCTAssertNil(appState.credentialGuidanceHostFallback)
    }
}

private actor CancellationThenSuccessMXResolver: MXRecordResolving {
    private(set) var callCount = 0

    func records(for _: String) async throws -> [String] {
        callCount += 1
        if callCount == 1 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return ["aspmx.l.google.com."]
    }
}

private actor MXResolverStub: MXRecordResolving {
    enum Failure: Error {
        case expected
    }

    private let result: Result<[String], Error>
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0
    private(set) var didRunOnMainThread = false

    init(result: Result<[String], Error>, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func records(for _: String) async throws -> [String] {
        callCount += 1
        didRunOnMainThread = Thread.isMainThread
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result.get()
    }
}
