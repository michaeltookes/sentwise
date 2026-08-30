import XCTest
@testable import Sentwise

/// Tests for the Google Workspace / Gmail policy-failure classifier and its
/// guidance copy (item 75). The classifier turns the ambiguous IMAP server text
/// into a specific failure class so onboarding/Settings can explain "your admin
/// disabled this" instead of a generic error, so the per-class matrix and the copy
/// are worth pinning down.
final class WorkspaceAuthFailureTests: XCTestCase {

    private let googleHost = "imap.gmail.com"
    private let nonGoogleHost = "imap.example.org"

    // Real-world server texts (see item 75 spec).
    private let invalidCredentials = "[AUTHENTICATIONFAILED] Invalid credentials (Failure)"
    private let imapDisabledText =
        "[ALERT] Please log in via your web browser. IMAP access is disabled for your domain."
    private let unavailableImapText = "[UNAVAILABLE] IMAP service is unavailable for this account."
    private let webLoginText =
        "[ALERT] Web login required: https://support.google.com/mail/accounts/answer/78754"

    // MARK: - App-password rejection (ambiguous "Invalid credentials")

    func testInvalidCredentialsOnCustomDomainGoogleHostIsWorkspaceAppPasswordRejection() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: invalidCredentials,
                emailDomain: "marcus@acme.com".domainPart,
                imapHost: googleHost
            ),
            .appPasswordRejectedWorkspace
        )
    }

    func testInvalidCredentialsOnConsumerDomainFallsBackToNone() {
        for domain in ["gmail.com", "googlemail.com"] {
            XCTAssertEqual(
                WorkspaceAuthFailure.classify(
                    serverText: invalidCredentials,
                    emailDomain: domain,
                    imapHost: googleHost
                ),
                .none,
                "consumer \(domain) keeps the existing typo/2-Step guidance"
            )
        }
    }

    func testInvalidCredentialsOnNonGoogleHostIsNone() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: invalidCredentials,
                emailDomain: "acme.com",
                imapHost: nonGoogleHost
            ),
            .none
        )
    }

    // MARK: - IMAP disabled

    func testImapDisabledClassifiesOnAnyGoogleHostRegardlessOfDomain() {
        for domain in ["acme.com", "gmail.com"] {
            XCTAssertEqual(
                WorkspaceAuthFailure.classify(
                    serverText: imapDisabledText,
                    emailDomain: domain,
                    imapHost: googleHost
                ),
                .imapDisabled
            )
        }
    }

    func testUnavailableImapTextClassifiesAsImapDisabled() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: unavailableImapText,
                emailDomain: "acme.com",
                imapHost: googleHost
            ),
            .imapDisabled
        )
    }

    func testImapDisabledOnNonGoogleHostIsNone() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: imapDisabledText,
                emailDomain: "acme.com",
                imapHost: nonGoogleHost
            ),
            .none
        )
    }

    // MARK: - Web login required

    func testWebLoginRequiredClassifiesFromTextOrSupportURL() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: webLoginText,
                emailDomain: "acme.com",
                imapHost: googleHost
            ),
            .webLoginRequired
        )
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: "Access blocked. Web login required.",
                emailDomain: "gmail.com",
                imapHost: googleHost
            ),
            .webLoginRequired
        )
    }

    func testWebLoginRequiredOnNonGoogleHostIsNone() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: webLoginText,
                emailDomain: "acme.com",
                imapHost: nonGoogleHost
            ),
            .none
        )
    }

    // MARK: - Case-insensitivity and unrelated text

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: "IMAP ACCESS IS DISABLED for your domain",
                emailDomain: "acme.com",
                imapHost: "IMAP.GMAIL.COM"
            ),
            .imapDisabled
        )
    }

    func testUnrelatedTextOnGoogleHostIsNone() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(
                serverText: "Temporary system error, please try again later.",
                emailDomain: "acme.com",
                imapHost: googleHost
            ),
            .none
        )
    }

    func testMissingDomainStillClassifiesUnambiguousModes() {
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(serverText: imapDisabledText, emailDomain: nil, imapHost: googleHost),
            .imapDisabled
        )
        // A nil domain is not a consumer domain, so the ambiguous case is treated
        // as a Workspace rejection (the safe, more-explanatory branch).
        XCTAssertEqual(
            WorkspaceAuthFailure.classify(serverText: invalidCredentials, emailDomain: nil, imapHost: googleHost),
            .appPasswordRejectedWorkspace
        )
    }

    // MARK: - Activity class names (PII-free)

    func testActivityClassNamesAreStable() {
        XCTAssertEqual(WorkspaceAuthFailure.appPasswordRejectedWorkspace.activityClassName,
                       "appPasswordRejectedWorkspace")
        XCTAssertEqual(WorkspaceAuthFailure.imapDisabled.activityClassName, "imapDisabled")
        XCTAssertEqual(WorkspaceAuthFailure.webLoginRequired.activityClassName, "webLoginRequired")
        XCTAssertEqual(WorkspaceAuthFailure.none.activityClassName, "none")
    }

    // MARK: - Guidance selection

    func testNoneProducesNoGuidance() {
        XCTAssertNil(WorkspaceAuthGuidance.make(for: .none, isCustomDomain: true))
        XCTAssertNil(WorkspaceAuthGuidance.make(for: .none, isCustomDomain: false))
    }

    func testAppPasswordRejectionGuidanceOffersAdminAskAndSupportLink() throws {
        let guidance = try XCTUnwrap(
            WorkspaceAuthGuidance.make(for: .appPasswordRejectedWorkspace, isCustomDomain: true)
        )
        XCTAssertTrue(guidance.headline.lowercased().contains("rejected"))
        XCTAssertTrue(guidance.explanation.lowercased().contains("not a problem with sentwise"))
        XCTAssertTrue(guidance.showsAskAdmin)
        XCTAssertFalse(guidance.options.isEmpty)
        XCTAssertTrue(guidance.options.contains { $0.lowercased().contains("personal") },
                      "must offer a personal-account fallback")
        XCTAssertNotNil(guidance.supportURL)
    }

    func testImapDisabledAdminVsPersonalFraming() throws {
        let admin = try XCTUnwrap(WorkspaceAuthGuidance.make(for: .imapDisabled, isCustomDomain: true))
        XCTAssertTrue(admin.showsAskAdmin)
        XCTAssertTrue(admin.explanation.lowercased().contains("admin"))

        let personal = try XCTUnwrap(WorkspaceAuthGuidance.make(for: .imapDisabled, isCustomDomain: false))
        XCTAssertFalse(personal.showsAskAdmin, "a personal account has no admin to ask")
        XCTAssertTrue(personal.options.contains { $0.lowercased().contains("enable imap") },
                      "personal guidance walks the user through enabling IMAP themselves")
    }

    func testWebLoginGuidanceOnlyOffersAdminAskForCustomDomain() throws {
        let admin = try XCTUnwrap(WorkspaceAuthGuidance.make(for: .webLoginRequired, isCustomDomain: true))
        XCTAssertTrue(admin.showsAskAdmin)

        let personal = try XCTUnwrap(WorkspaceAuthGuidance.make(for: .webLoginRequired, isCustomDomain: false))
        XCTAssertFalse(personal.showsAskAdmin)
        XCTAssertTrue(personal.options.contains { $0.contains("accounts.google.com") })
    }

    // MARK: - Ask-admin copy

    func testAskAdminMessageNamesBothLeversAndTheSupportArticle() {
        let message = WorkspaceAuthGuidance.askAdminMessage
        XCTAssertTrue(message.contains("app passwords"))
        XCTAssertTrue(message.contains("IMAP"))
        XCTAssertTrue(message.contains("https://support.google.com/accounts/answer/185833"))
    }
}

private extension String {
    /// The domain half of an email address, for terse test call sites.
    var domainPart: String? {
        guard let at = lastIndex(of: "@") else { return nil }
        return String(self[index(after: at)...])
    }
}
