import XCTest
@testable import Sentwise

/// The Microsoft consent block's final wording (item 31, T31-10). Guards the
/// claims the copy must and must not make; the exact strings are owner-approved
/// in docs/design/t31-10-microsoft-consent-copy.md.
final class MicrosoftConsentCopyTests: XCTestCase {
    private var blockStrings: [String] {
        [
            MicrosoftSignInCopy.consentHeading,
            MicrosoftSignInCopy.consentSummary,
            MicrosoftSignInCopy.consentPrivacy,
            MicrosoftSignInCopy.consentRevoke,
            MicrosoftSignInCopy.workAccountNote
        ]
    }

    func testConsentStringsAreFinalWording() {
        XCTAssertEqual(MicrosoftSignInCopy.consentHeading, "Before you continue")
        XCTAssertEqual(
            MicrosoftSignInCopy.consentSummary,
            "Microsoft will ask you to let Sentwise read your mail, save drafts, "
                + "and send messages you approve, and to keep this Mac signed in."
        )
        XCTAssertEqual(
            MicrosoftSignInCopy.consentPrivacy,
            "Mail is read on this Mac. Only the content needed to draft a reply, and up to 12 of your sent "
                + "messages each time you learn your voice, goes to the Sentwise drafting service. "
                + "Your sign-in is kept in this Mac's Keychain and is never sent to Sentwise servers."
        )
        XCTAssertEqual(
            MicrosoftSignInCopy.consentRevoke,
            "You can remove Sentwise's access at any time in your Microsoft account."
        )
        XCTAssertEqual(
            MicrosoftSignInCopy.workAccountNote,
            "For a work or school account, your IT administrator may need to approve Sentwise first."
        )
    }

    func testConsentCopyCarriesNoPlaceholderOrForbiddenClaim() {
        for string in blockStrings {
            let lower = string.lowercased()
            for marker in ["todo", "placeholder", "lorem", "tbd", "xxx"] {
                XCTAssertFalse(lower.contains(marker), "\(marker) in \(string)")
            }
            XCTAssertFalse(string.contains("\u{2014}"), "em-dash in \(string)")
            // Drafting sends content to the drafting service, so the copy must
            // never promise that mail stays on the Mac or is never read.
            XCTAssertFalse(lower.contains("never leaves"), string)
            XCTAssertFalse(lower.contains("never reads"), string)
            XCTAssertFalse(lower.contains("does not read"), string)
            // Nothing beyond the requested scopes (no delete, contacts, calendar, files).
            for claim in ["delete", "contacts", "calendar", "onedrive", "files"] {
                XCTAssertFalse(lower.contains(claim), "\(claim) in \(string)")
            }
        }
    }

    func testAccessibilityTextReadsTheVisibleBlockInOrder() {
        let withNote = MicrosoftSignInCopy.consentAccessibilityText(showsWorkAccountNote: true)
        XCTAssertEqual(
            withNote,
            [
                "Before you continue.",
                MicrosoftSignInCopy.consentSummary,
                MicrosoftSignInCopy.consentPrivacy,
                MicrosoftSignInCopy.workAccountNote,
                MicrosoftSignInCopy.consentRevoke
            ].joined(separator: " ")
        )
        let withoutNote = MicrosoftSignInCopy.consentAccessibilityText(showsWorkAccountNote: false)
        XCTAssertFalse(withoutNote.contains(MicrosoftSignInCopy.workAccountNote))
        XCTAssertTrue(withoutNote.hasSuffix(MicrosoftSignInCopy.consentRevoke))
    }

    func testReauthorizationDetailsKeepTheirPrefixAndDropTheEmDash() {
        for detail in [MicrosoftMailCredential.reauthorizationDetail, GoogleMailCredential.reauthorizationDetail] {
            XCTAssertFalse(detail.contains("\u{2014}"), detail)
        }
        XCTAssertTrue(MicrosoftMailCredential.isMicrosoftSignInFailureDetail(MicrosoftMailCredential.reauthorizationDetail))
    }
}
