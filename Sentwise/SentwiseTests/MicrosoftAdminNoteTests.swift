import SentwiseMail
import XCTest
@testable import Sentwise

/// The admin note a user sends to their IT administrator (TC-M6-10).
final class MicrosoftAdminNoteTests: XCTestCase {

    private let clientID = "11111111-2222-3333-4444-555555555555"
    private let tenant = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let address = "me@contoso.com"

    func testConsentNoteNamesTheAppClientPermissionsAndTenantScopedURL() {
        let note = MicrosoftAdminNote.text(
            reason: .consentRequired(tenantID: tenant), clientID: clientID, address: address
        )
        XCTAssertTrue(note.contains("Application: Sentwise"))
        XCTAssertTrue(note.contains("Application (client) ID: \(clientID)"))
        for permission in ["IMAP.AccessAsUser.All", "SMTP.Send", "offline_access"] {
            XCTAssertTrue(note.contains(permission), permission)
        }
        XCTAssertTrue(note.contains(address))
        XCTAssertTrue(note.contains("https://login.microsoftonline.com/\(tenant)/adminconsent?client_id=\(clientID)"))
    }

    func testConsentURLFallsBackToTheAddressDomainAndNeverUsesCommon() {
        XCTAssertEqual(
            MicrosoftAdminNote.adminConsentURL(clientID: clientID, tenantID: nil, address: address)?.absoluteString,
            "https://login.microsoftonline.com/contoso.com/adminconsent?client_id=\(clientID)"
        )
        XCTAssertEqual(
            MicrosoftAdminNote.adminConsentURL(clientID: clientID, tenantID: "common", address: address)?.absoluteString,
            "https://login.microsoftonline.com/contoso.com/adminconsent?client_id=\(clientID)"
        )
        XCTAssertNil(MicrosoftAdminNote.adminConsentURL(clientID: clientID, tenantID: nil, address: "no-at-sign"))
    }

    func testUnsafeTenantOrAddressCannotAlterTheURL() {
        let url = MicrosoftAdminNote.adminConsentURL(
            clientID: "a&b=c", tenantID: "evil.com/x?y=", address: "me@ok.com"
        )
        XCTAssertEqual(url?.absoluteString, "https://login.microsoftonline.com/ok.com/adminconsent?client_id=a%26b%3Dc")
        XCTAssertNil(MicrosoftAdminNote.adminConsentURL(clientID: clientID, tenantID: nil, address: "me@bad.com/../x"))
    }

    func testConsentNoteWithoutAUsableTenantStillExplainsWhatToDo() {
        let note = MicrosoftAdminNote.text(reason: .consentRequired(tenantID: nil), clientID: clientID, address: "nobody")
        XCTAssertFalse(note.contains("adminconsent?"))
        XCTAssertTrue(note.contains("Grant admin consent for application ID \(clientID)"))
    }

    func testProtocolNotesCarryTheMatchingPowerShellLine() {
        let imap = MicrosoftAdminNote.text(reason: .protocolDisabled(.imap), clientID: clientID, address: address)
        XCTAssertTrue(imap.contains("Set-CASMailbox -Identity \(address) -ImapEnabled $true"))
        let smtp = MicrosoftAdminNote.text(reason: .protocolDisabled(.smtp), clientID: clientID, address: address)
        XCTAssertTrue(smtp.contains("Set-CASMailbox -Identity \(address) -SmtpClientAuthenticationDisabled $false"))
        XCTAssertFalse(imap.contains("SmtpClientAuthenticationDisabled"))
    }

    func testNoteIsPlainTextWithoutSecrets() {
        let note = MicrosoftAdminNote.text(reason: .consentRequired(tenantID: tenant), clientID: clientID, address: address)
        XCTAssertFalse(note.lowercased().contains("token"))
        XCTAssertFalse(note.lowercased().contains("secret"))
        XCTAssertFalse(note.contains("<"))
    }
}
