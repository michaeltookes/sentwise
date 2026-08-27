import SentwiseMail
import XCTest
@testable import Sentwise

/// Tests for the one-time pre-gate reply-worthiness sweep (item 80): drafts
/// enqueued before the transactional/no-reply gate shipped are re-evaluated once
/// at launch and the now-skippable ones move to the skip log, while anything the
/// user has invested in is left untouched.
@MainActor
final class AppStatePreGateDraftSweepTests: XCTestCase {

    private let account = "me@gmail.com"

    /// Builds a reply draft with the given source sender. Defaults produce a plain,
    /// unedited reply draft eligible for the sweep; overrides model the exclusions.
    private func draft(
        id: UInt32,
        fromEmail: String,
        replyToEmail: String? = nil,
        originalBody: String? = nil,
        needsInfo: DraftNeedsInfo? = nil,
        offlineQueuedDispatch: OfflineQueuedDraftDispatch? = nil,
        authoredRecipients: [MailAddress]? = nil
    ) -> Draft {
        Draft(
            id: id,
            sourceUIDValidity: 7,
            sourceAccountEmail: account,
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Subject \(id)",
            sourceFrom: MailAddress(email: fromEmail),
            sourceReplyTo: replyToEmail.map { MailAddress(email: $0) },
            sourceMessageID: "<\(id)@x.com>",
            replySubject: "Re: Subject \(id)",
            body: "Proposed reply \(id).",
            originalBody: originalBody,
            model: "claude-sonnet-4-6",
            generatedAt: Date(),
            needsInfo: needsInfo,
            offlineQueuedDispatch: offlineQueuedDispatch,
            authoredRecipients: authoredRecipients
        )
    }

    private func makeAppState(
        seededDrafts: [Draft],
        hasRunPreGateDraftSweep: Bool = false
    ) -> (AppState, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: account,
                hasRunPreGateDraftSweep: hasRunPreGateDraftSweep
            ),
            pendingDrafts: seededDrafts
        )
        let appState = AppState(persistence: persistence, secrets: secrets)
        return (appState, persistence)
    }

    // MARK: - Sweep behaviour

    func testSweepMovesJunkAndRetainsEverythingElse() throws {
        let amazon = draft(id: 1, fromEmail: "auto-confirm@amazon.com")
        let noReply = draft(id: 2, fromEmail: "no-reply@example.com")
        let human = draft(id: 3, fromEmail: "jane@company.com")
        let authored = draft(
            id: 4,
            fromEmail: "auto-confirm@amazon.com",
            authoredRecipients: [MailAddress(email: "client@corp.com")]
        )
        let edited = draft(id: 5, fromEmail: "shipment-tracking@amazon.com", originalBody: "Original assistant reply.")

        let (appState, persistence) = makeAppState(
            seededDrafts: [amazon, noReply, human, authored, edited]
        )
        XCTAssertEqual(appState.pendingDrafts.count, 5)

        appState.runPreGateDraftSweepIfNeeded()

        // Junk removed from the queue; human/authored/edited retained.
        let remainingIDs = Set(appState.pendingDrafts.map(\.id))
        XCTAssertEqual(remainingIDs, [3, 4, 5])
        XCTAssertFalse(appState.pendingDrafts.contains { $0.id == amazon.id })
        XCTAssertFalse(appState.pendingDrafts.contains { $0.id == noReply.id })

        // Junk recorded on the skip log with the correct reasons.
        XCTAssertEqual(appState.skippedMessages.count, 2)
        let reasonByUID = Dictionary(
            uniqueKeysWithValues: appState.skippedMessages.map { ($0.message.id, $0.reason) }
        )
        XCTAssertEqual(reasonByUID[amazon.id], .automatedNotification)
        XCTAssertEqual(reasonByUID[noReply.id], .noReplySender)

        // The flag is set and persisted so the sweep never runs again.
        XCTAssertTrue(appState.hasRunPreGateDraftSweep)
        let persistedFlag = persistence.savedSettingsHistory.last?.hasRunPreGateDraftSweep
        XCTAssertEqual(persistedFlag, true)
        // The pending queue was persisted for each swept draft.
        XCTAssertEqual(persistence.pendingDrafts.count, 3)
    }

    func testSweepIsIdempotentWithinASession() throws {
        let amazon = draft(id: 1, fromEmail: "auto-confirm@amazon.com")
        let human = draft(id: 2, fromEmail: "jane@company.com")
        let (appState, persistence) = makeAppState(seededDrafts: [amazon, human])

        appState.runPreGateDraftSweepIfNeeded()
        let queueAfterFirst = appState.pendingDrafts.map(\.id)
        let skipCountAfterFirst = appState.skippedMessages.count
        let saveCountAfterFirst = persistence.settingsSaveCount

        // A second call is guarded by the flag: no queue mutation, no extra skips,
        // and no further settings write.
        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), queueAfterFirst)
        XCTAssertEqual(appState.skippedMessages.count, skipCountAfterFirst)
        XCTAssertEqual(persistence.settingsSaveCount, saveCountAfterFirst)
    }

    func testAlreadySweptInstallDoesNotReRun() throws {
        // An install whose settings already record the sweep as run must leave even
        // obvious junk in place — the flag, not the queue contents, gates the run.
        let amazon = draft(id: 1, fromEmail: "auto-confirm@amazon.com")
        let (appState, _) = makeAppState(seededDrafts: [amazon], hasRunPreGateDraftSweep: true)

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
    }

    func testExcludedDraftsFromJunkSendersAreNeverSwept() throws {
        // Every exclusion category, all from junk-looking senders, must survive.
        let authored = draft(
            id: 1,
            fromEmail: "auto-confirm@amazon.com",
            authoredRecipients: [MailAddress(email: "client@corp.com")]
        )
        let edited = draft(id: 2, fromEmail: "no-reply@example.com", originalBody: "Original.")
        let offlineQueued = draft(
            id: 3,
            fromEmail: "budgets@costalerts.amazonaws.com",
            offlineQueuedDispatch: OfflineQueuedDraftDispatch(sendBehavior: .saveAsDraft)
        )
        let needsInfo = draft(
            id: 4,
            fromEmail: "shipment-tracking@amazon.com",
            needsInfo: DraftNeedsInfo(summary: "Need the order number.")
        )

        let (appState, _) = makeAppState(seededDrafts: [authored, edited, offlineQueued, needsInfo])

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(Set(appState.pendingDrafts.map(\.id)), [1, 2, 3, 4])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        // The flag still flips even when nothing is swept, so it runs exactly once.
        XCTAssertTrue(appState.hasRunPreGateDraftSweep)
    }
}
