import Foundation
import XCTest
@testable import Sentwise

/// Scripted resolver: answers per domain from a table and records every query,
/// so no test touches the network.
private actor ScriptedMXResolver: MXRecordResolving {
    private let table: [String: [String]]
    private(set) var queried: [String] = []

    init(_ table: [String: [String]]) { self.table = table }

    func records(for domain: String) async throws -> [String] {
        queried.append(domain)
        return table[domain] ?? []
    }
}

final class MicrosoftProviderDetectionTests: XCTestCase {
    func testConsumerDomainsAreMicrosoft() {
        let domains = [
            "outlook.com", "hotmail.com", "live.com", "msn.com", "hotmail.co.uk", "outlook.de",
            "live.fr", "hotmail.fr", "outlook.fr", "live.nl", "outlook.com.au", "hotmail.it",
            "outlook.jp", "live.com.mx", "windowslive.com", "OUTLOOK.COM"
        ]
        for domain in domains {
            XCTAssertEqual(EmailProviderKind.forEmail("me@\(domain)"), .microsoft, domain)
        }
    }

    func testLookalikeAndUnknownDomainsAreNotMicrosoft() {
        for domain in ["outlook.com.evil.example", "notoutlook.com", "hotmail.zz", "example.com", "outlook.co"] {
            XCTAssertNil(EmailProviderKind.forEmail("me@\(domain)"), domain)
        }
    }

    func testExistingProvidersAreUnchanged() {
        XCTAssertEqual(EmailProviderKind.forEmail("me@gmail.com"), .gmail)
        XCTAssertEqual(EmailProviderKind.forEmail("me@icloud.com"), .icloud)
        XCTAssertEqual(EmailProviderKind.forEmail("me@yahoo.com"), .yahoo)
        XCTAssertEqual(EmailProviderKind.forEmail("me@aol.com"), .aol)
        XCTAssertEqual(EmailProviderKind.forEmail("me@att.net"), .att)
        XCTAssertEqual(EmailProviderKind.gmail.imapHost, "imap.gmail.com")
    }

    func testMicrosoftIMAPHostAndHostClassification() {
        XCTAssertEqual(EmailProviderKind.microsoft.imapHost, "outlook.office365.com")
        XCTAssertEqual(EmailProviderKind.forHost("outlook.office365.com"), .microsoft)
        XCTAssertEqual(EmailProviderKind.forHost("imap-mail.outlook.com"), .microsoft)
        XCTAssertNil(EmailProviderKind.forHost("outlook.com.evil.example"))
        XCTAssertTrue(EmailProviderKind.allHosts.contains("outlook.office365.com"))
        XCTAssertEqual(EmailProviderKind.forEmail("me@outlook.com")?.imapHost, "outlook.office365.com")
    }

    func testManualPasswordsForMicrosoftHostsAreNotGroupedCodeNormalized() {
        // Microsoft app passwords are not grouped codes: internal spaces survive.
        XCTAssertEqual(
            MailCredentialPasswordNormalization.normalized(
                " ab cd ", email: "me@outlook.com", host: "outlook.office365.com"
            ),
            "ab cd"
        )
    }

    func testMicrosoft365MXPatternMatches() {
        XCTAssertTrue(Microsoft365MXDetector.containsMicrosoft365MailExchange([
            "contoso-com.mail.protection.outlook.com."
        ]))
        XCTAssertFalse(Microsoft365MXDetector.containsMicrosoft365MailExchange([
            "mail.protection.outlook.com.evil.example", "mx1.example.net"
        ]))
    }

    func testMicrosoft365DomainIsDetectedByMX() async {
        let resolver = ScriptedMXResolver(["contoso.com": ["contoso-com.mail.protection.outlook.com."]])
        let detector = makeDetector(microsoft: resolver)
        let kind = await detector.detect(email: "pat@contoso.com")
        XCTAssertEqual(kind, .microsoft)
    }

    func testGoogleWorkspaceDomainStaysGoogle() async {
        let google = ScriptedMXResolver(["acme.io": ["aspmx.l.google.com."]])
        let microsoft = ScriptedMXResolver([:])
        let detector = EmailProviderDetector(
            google: GoogleWorkspaceMXDetector(resolver: google),
            microsoft365: Microsoft365MXDetector(resolver: microsoft)
        )
        let kind = await detector.detect(email: "pat@acme.io")
        let microsoftQueries = await microsoft.queried
        XCTAssertEqual(kind, .gmail)
        XCTAssertTrue(microsoftQueries.isEmpty, "Google hit must not query Microsoft")
    }

    func testUnknownDomainKeepsTheAppPasswordPath() async {
        let resolver = ScriptedMXResolver(["example.org": ["mx1.example.org."]])
        let detector = makeDetector(microsoft: resolver)
        let kind = await detector.detect(email: "pat@example.org")
        XCTAssertNil(kind)
        XCTAssertNil(EmailProviderKind.forEmail("pat@example.org")?.imapHost)
    }

    func testKnownProvidersNeverQueryDNS() async {
        let google = ScriptedMXResolver([:])
        let microsoft = ScriptedMXResolver([:])
        let detector = EmailProviderDetector(
            google: GoogleWorkspaceMXDetector(resolver: google),
            microsoft365: Microsoft365MXDetector(resolver: microsoft)
        )
        let outlook = await detector.detect(email: "me@outlook.com")
        let gmail = await detector.detect(email: "me@gmail.com")
        let googleQueries = await google.queried
        let microsoftQueries = await microsoft.queried
        XCTAssertEqual(outlook, .microsoft)
        XCTAssertEqual(gmail, .gmail)
        XCTAssertTrue(googleQueries.isEmpty && microsoftQueries.isEmpty)
    }

    func testMicrosoft365ResultsAreCachedAndFailuresDoNotMatch() async {
        let resolver = ScriptedMXResolver(["contoso.com": ["contoso-com.mail.protection.outlook.com"]])
        let detector = Microsoft365MXDetector(resolver: resolver)
        let first = await detector.isMicrosoft365Hosted(domain: "Contoso.com")
        let second = await detector.isMicrosoft365Hosted(domain: "contoso.com")
        let queries = await resolver.queried
        XCTAssertTrue(first && second)
        XCTAssertEqual(queries, ["contoso.com"])
    }

    func testMicrosoftGuidanceSatisfiesProviderContract() {
        let guidance = CredentialGuidance.forEmail("me@outlook.com")
        XCTAssertEqual(guidance.providerName, "Microsoft")
        XCTAssertTrue(guidance.passwordWontWorkNote.contains("won't work"))
    }

    private func makeDetector(microsoft: ScriptedMXResolver) -> EmailProviderDetector {
        EmailProviderDetector(
            google: GoogleWorkspaceMXDetector(resolver: ScriptedMXResolver([:])),
            microsoft365: Microsoft365MXDetector(resolver: microsoft)
        )
    }
}
