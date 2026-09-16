import SentwiseMail
import XCTest
@testable import Sentwise

final class ProcessedMessagesTests: XCTestCase {

    private func message(id: UInt32, messageID: String? = nil, uidValidity: UInt32? = nil) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: MailAddress(email: "a@x.com"),
            subject: "Hi",
            date: "",
            messageID: messageID
        )
    }

    func testKeyPrefersMessageID() {
        let key = ProcessedMessages.key(
            for: message(id: 5, messageID: "<abc@x.com>", uidValidity: 99),
            account: "me@gmail.com",
            mailbox: .inbox
        )
        XCTAssertEqual(key, "mid:acct=me@gmail.com|mailbox=inbox|messageID=<abc@x.com>")
    }

    func testKeyFallsBackToScopedUIDValidityAndUID() {
        let key = ProcessedMessages.key(
            for: message(id: 5, uidValidity: 99),
            account: " Me@Gmail.com ",
            mailbox: .inbox
        )
        XCTAssertEqual(key, "uid:acct=me@gmail.com|mailbox=inbox|validity=99|uid=5")
    }

    func testInsertAndContains() {
        var store = ProcessedMessages()
        let msg = message(id: 5, messageID: "<abc@x.com>")
        XCTAssertFalse(store.contains(msg, account: "me@gmail.com", mailbox: .inbox))
        store.insert(msg, account: "me@gmail.com", mailbox: .inbox)
        XCTAssertTrue(store.contains(msg, account: "me@gmail.com", mailbox: .inbox))
    }

    func testSameMessageIDIsScopedToAccountAndMailbox() {
        var store = ProcessedMessages()
        store.insert(message(id: 5, messageID: "<abc@x.com>", uidValidity: 1), account: "one@gmail.com", mailbox: .inbox)
        XCTAssertTrue(store.contains(
            message(id: 99, messageID: "<abc@x.com>", uidValidity: 2),
            account: "one@gmail.com",
            mailbox: .inbox
        ))
        XCTAssertFalse(store.contains(
            message(id: 99, messageID: "<abc@x.com>", uidValidity: 2),
            account: "two@gmail.com",
            mailbox: .inbox
        ))
        XCTAssertFalse(store.contains(
            message(id: 99, messageID: "<abc@x.com>", uidValidity: 2),
            account: "one@gmail.com",
            mailbox: .named("Archive")
        ))
    }

    func testFallbackUIDKeysAreScopedToAccountAndMailbox() {
        var store = ProcessedMessages()
        let msg = message(id: 5, uidValidity: 99)
        store.insert(msg, account: "one@gmail.com", mailbox: .inbox)

        XCTAssertTrue(store.contains(msg, account: "one@gmail.com", mailbox: .inbox))
        XCTAssertFalse(store.contains(msg, account: "two@gmail.com", mailbox: .inbox))
        XCTAssertFalse(store.contains(msg, account: "one@gmail.com", mailbox: .named("Archive")))
    }

    func testMessageIDAlsoRecognizesScopedFallbackUIDKey() {
        var store = ProcessedMessages()
        let fallbackOnly = message(id: 5, uidValidity: 99)
        store.insert(fallbackOnly, account: "one@gmail.com", mailbox: .inbox)

        let withMessageID = message(id: 5, messageID: "<abc@x.com>", uidValidity: 99)
        XCTAssertTrue(store.contains(withMessageID, account: "one@gmail.com", mailbox: .inbox))
        XCTAssertFalse(store.contains(withMessageID, account: "two@gmail.com", mailbox: .inbox))
        XCTAssertFalse(store.contains(withMessageID, account: "one@gmail.com", mailbox: .named("Archive")))
    }

    func testInsertIsIdempotent() {
        var store = ProcessedMessages()
        let msg = message(id: 5, messageID: "<abc@x.com>")
        store.insert(msg, account: "me@gmail.com", mailbox: .inbox)
        store.insert(msg, account: "me@gmail.com", mailbox: .inbox)
        XCTAssertEqual(store.keys.count, 1)
    }

    func testBaselineIsScopedToAccountAndMailbox() {
        var store = ProcessedMessages()
        store.insertBaseline(account: " Me@Gmail.com ", mailbox: .inbox)

        XCTAssertTrue(store.hasBaseline(account: "me@gmail.com", mailbox: .inbox))
        XCTAssertFalse(store.hasBaseline(account: "other@gmail.com", mailbox: .inbox))
        XCTAssertFalse(store.hasBaseline(account: "me@gmail.com", mailbox: .named("Archive")))
    }

    func testBaselineStartIsScopedAndRetainedWhenBaselineIsInserted() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var store = ProcessedMessages()
        store.setBaselineStart(account: " Me@Gmail.com ", mailbox: .inbox, date: date)

        XCTAssertTrue(store.hasBaselineStart(account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(store.baselineStartDate(account: "me@gmail.com", mailbox: .inbox), date)
        XCTAssertFalse(store.hasBaselineStart(account: "other@gmail.com", mailbox: .inbox))
        XCTAssertFalse(store.hasBaselineStart(account: "me@gmail.com", mailbox: .named("Archive")))

        store.insertBaseline(account: "me@gmail.com", mailbox: .inbox)

        XCTAssertTrue(store.hasBaselineStart(account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(store.baselineStartDate(account: "me@gmail.com", mailbox: .inbox), date)
    }

    func testBaselineUIDIsScoped() {
        var store = ProcessedMessages()
        store.setBaselineUID(account: " Me@Gmail.com ", mailbox: .inbox, uid: 42, uidValidity: 99)

        XCTAssertEqual(store.baselineUID(account: "me@gmail.com", mailbox: .inbox)?.uid, 42)
        XCTAssertEqual(store.baselineUID(account: "me@gmail.com", mailbox: .inbox)?.uidValidity, 99)
        XCTAssertNil(store.baselineUID(account: "other@gmail.com", mailbox: .inbox))
        XCTAssertNil(store.baselineUID(account: "me@gmail.com", mailbox: .named("Archive")))
    }

    func testRemoveAccountMatchesOnlyLeadingScope() {
        var store = ProcessedMessages()
        let retained = message(id: 1, messageID: "<acct=removed@gmail.com|spoof@x.com>", uidValidity: 10)
        let removed = message(id: 2, messageID: "<normal@x.com>", uidValidity: 11)
        let retainedDate = Date(timeIntervalSince1970: 1_700_000_000)

        store.insert(retained, account: "other@gmail.com", mailbox: .inbox)
        store.insert(removed, account: "removed@gmail.com", mailbox: .inbox)
        store.insertBaseline(account: "other@gmail.com", mailbox: .inbox)
        store.setBaselineStart(account: "other@gmail.com", mailbox: .inbox, date: retainedDate)
        store.setBaselineUID(account: "other@gmail.com", mailbox: .inbox, uid: 42, uidValidity: 99)
        store.insertBaseline(account: "removed@gmail.com", mailbox: .inbox)

        store.removeAccount("removed@gmail.com")

        XCTAssertTrue(store.contains(retained, account: "other@gmail.com", mailbox: .inbox))
        XCTAssertFalse(store.contains(removed, account: "removed@gmail.com", mailbox: .inbox))
        XCTAssertTrue(store.hasBaseline(account: "other@gmail.com", mailbox: .inbox))
        XCTAssertEqual(store.baselineStartDate(account: "other@gmail.com", mailbox: .inbox), retainedDate)
        XCTAssertEqual(store.baselineUID(account: "other@gmail.com", mailbox: .inbox)?.uid, 42)
        XCTAssertFalse(store.hasBaseline(account: "removed@gmail.com", mailbox: .inbox))
    }

    func testBaselineIsNotEvictedWithMessageKeys() {
        var store = ProcessedMessages()
        store.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        for index in 0..<(ProcessedMessages.limit + 10) {
            store.insert(message(id: UInt32(index), messageID: "<\(index)@x.com>"), account: "me@gmail.com", mailbox: .inbox)
        }

        XCTAssertEqual(store.keys.count, ProcessedMessages.limit)
        XCTAssertTrue(store.hasBaseline(account: "me@gmail.com", mailbox: .inbox))
    }

    func testEvictsOldestPastLimit() {
        var store = ProcessedMessages()
        for index in 0..<(ProcessedMessages.limit + 10) {
            store.insert(message(id: UInt32(index), messageID: "<\(index)@x.com>"), account: "me@gmail.com", mailbox: .inbox)
        }
        XCTAssertEqual(store.keys.count, ProcessedMessages.limit)
        // The 10 oldest were evicted; the newest remain.
        XCTAssertFalse(store.contains(message(id: 0, messageID: "<0@x.com>"), account: "me@gmail.com", mailbox: .inbox))
        XCTAssertTrue(store.contains(
            message(id: 5, messageID: "<\(ProcessedMessages.limit + 5)@x.com>"),
            account: "me@gmail.com",
            mailbox: .inbox
        ))
    }

    func testCodableRoundTrip() throws {
        var store = ProcessedMessages()
        store.insertBaseline(account: "me@gmail.com", mailbox: .inbox)
        let baselineStart = Date(timeIntervalSince1970: 1_700_000_000)
        store.setBaselineStart(account: "other@gmail.com", mailbox: .inbox, date: baselineStart)
        store.setBaselineUID(account: "me@gmail.com", mailbox: .inbox, uid: 99, uidValidity: 42)
        store.insert(message(id: 1, messageID: "<1@x.com>"), account: "me@gmail.com", mailbox: .inbox)
        store.insert(message(id: 2, messageID: "<2@x.com>"), account: "me@gmail.com", mailbox: .inbox)

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ProcessedMessages.self, from: data)

        XCTAssertEqual(decoded, store)
        XCTAssertTrue(decoded.hasBaseline(account: "me@gmail.com", mailbox: .inbox))
        XCTAssertEqual(decoded.baselineStartDate(account: "other@gmail.com", mailbox: .inbox), baselineStart)
        XCTAssertEqual(decoded.baselineUID(account: "me@gmail.com", mailbox: .inbox)?.uid, 99)
        XCTAssertEqual(decoded.baselineUID(account: "me@gmail.com", mailbox: .inbox)?.uidValidity, 42)
        XCTAssertTrue(decoded.contains(message(id: 2, messageID: "<2@x.com>"), account: "me@gmail.com", mailbox: .inbox))
    }

    func testDecodesLegacyBareBaselineUIDs() throws {
        let data = Data(#"{"baselineUIDs":{"baseline:acct=me@gmail.com|mailbox=inbox":99}}"#.utf8)

        let decoded = try JSONDecoder().decode(ProcessedMessages.self, from: data)

        XCTAssertEqual(decoded.baselineUID(account: "me@gmail.com", mailbox: .inbox)?.uid, 99)
        XCTAssertNil(decoded.baselineUID(account: "me@gmail.com", mailbox: .inbox)?.uidValidity)
    }

    func testDecodesMissingKeysAsEmpty() throws {
        let decoded = try JSONDecoder().decode(ProcessedMessages.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.keys.isEmpty)
        XCTAssertTrue(decoded.baselines.isEmpty)
        XCTAssertTrue(decoded.baselineStarts.isEmpty)
        XCTAssertTrue(decoded.baselineUIDs.isEmpty)
    }
}
