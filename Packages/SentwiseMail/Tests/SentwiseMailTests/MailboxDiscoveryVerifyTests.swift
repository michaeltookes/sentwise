import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import SentwiseMail

/// Account-verification discovery over a scripted IMAP server (item 31, T31-8,
/// Codex round 2): the LIST runs once after login, its names reach the
/// credentials, and every Mailbox resolution prefers them over host defaults.
final class MailboxDiscoveryVerifyTests: XCTestCase {

    private struct Session {
        let channel: EmbeddedChannel
        let box: DiscoveryBox
        let future: EventLoopFuture<Void>
    }

    private func makeChannel() throws -> Session {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let box = DiscoveryBox()
        let handler = IMAPVerifyHandler(
            email: "me@example.com",
            authentication: .password("pw"),
            discovery: box,
            complete: { promise.completeWith($0) }
        )
        try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), handler])
        return Session(channel: channel, box: box, future: promise.futureResult)
    }

    @discardableResult
    private func feed(_ channel: EmbeddedChannel, _ text: String) throws -> String {
        try channel.writeInbound(ByteBuffer(string: text))
        var out = ""
        while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
            out += String(buffer: buffer)
        }
        return out
    }

    func testLocalizedSentFolderIsDiscoveredAndUsedForAppendAndFetch() throws {
        let session = try makeChannel()
        let (channel, box, future) = (session.channel, session.box, session.future)
        try feed(channel, "* OK ready\r\n")
        let list = try feed(channel, "A1 OK LOGIN completed\r\n")
        XCTAssertTrue(list.contains("A3 LIST \"\" \"*\""), "got: \(list)")
        try feed(channel, """
        * LIST (\\HasNoChildren) "/" "INBOX"\r
        * LIST (\\HasNoChildren \\Sent) "/" "Elementos enviados"\r
        * LIST (\\HasNoChildren \\Drafts) "/" "Borradores"\r
        A3 OK LIST completed\r

        """)
        XCTAssertNoThrow(try future.wait())
        let entries = try XCTUnwrap(box.entries)
        let naming = MailboxNaming.forHost("outlook.office365.com").discovering(from: entries)
        XCTAssertEqual(naming.sent, "Elementos enviados")
        XCTAssertEqual(naming.drafts, "Borradores")

        let credentials = MailAccountCredentials(
            email: "me@example.com", appPassword: "pw", host: "outlook.office365.com",
            discoveredNaming: naming
        )
        XCTAssertEqual(Mailbox.sent.imapName(using: credentials.mailboxNaming), "Elementos enviados")
        XCTAssertEqual(Mailbox.drafts.imapName(using: credentials.mailboxNaming), "Borradores")
        // Untouched roles keep the host default.
        XCTAssertEqual(Mailbox.trash.imapName(using: credentials.mailboxNaming), MailboxNaming.microsoft.trash)
        _ = try? channel.finish()
    }

    func testNoSpecialUseFallsBackToHostDefaults() throws {
        let session = try makeChannel()
        let (channel, box, future) = (session.channel, session.box, session.future)
        try feed(channel, "* OK ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\nA3 OK done\r\n")
        XCTAssertNoThrow(try future.wait())
        let naming = MailboxNaming.microsoft.discovering(from: try XCTUnwrap(box.entries))
        XCTAssertEqual(naming, .microsoft)
        let plain = MailAccountCredentials(email: "a@b.c", appPassword: "pw", host: "outlook.office365.com")
        XCTAssertEqual(plain.mailboxNaming, .microsoft, "no discovery keeps the static defaults")
        _ = try? channel.finish()
    }

    func testListFailureDoesNotBlockVerification() throws {
        let session = try makeChannel()
        let (channel, box, future) = (session.channel, session.box, session.future)
        try feed(channel, "* OK ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        try feed(channel, "A3 NO LIST not permitted\r\n")
        XCTAssertNoThrow(try future.wait())
        XCTAssertNil(box.entries)
        _ = try? channel.finish()
    }

    func testConnectionDroppingDuringListStillVerifies() throws {
        let session = try makeChannel()
        let (channel, box, future) = (session.channel, session.box, session.future)
        try feed(channel, "* OK ready\r\n")
        try feed(channel, "A1 OK LOGIN completed\r\n")
        channel.pipeline.fireChannelInactive()
        XCTAssertNoThrow(try future.wait())
        XCTAssertNil(box.entries)
        _ = try? channel.finish()
    }

    func testAuthFailureStillFailsWithDiscoveryRequested() throws {
        let session = try makeChannel()
        let (channel, future) = (session.channel, session.future)
        try feed(channel, "* OK ready\r\n")
        try feed(channel, "A1 NO [AUTHENTICATIONFAILED] bad\r\n")
        XCTAssertThrowsError(try future.wait())
        _ = try? channel.finish()
    }

    func testCredentialsCarryDiscoveredNamingIntoEquality() {
        let base = MailAccountCredentials(email: "a@b.c", appPassword: "pw")
        var discovered = base
        discovered.discoveredNaming = .microsoft
        XCTAssertNil(base.discoveredNaming)
        XCTAssertNotEqual(base, discovered)
    }
}
