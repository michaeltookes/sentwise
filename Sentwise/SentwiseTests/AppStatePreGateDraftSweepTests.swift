import SentwiseMail
import XCTest
@testable import Sentwise

private func utcDate(year: Int, month: Int, day: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = year
    components.month = month
    components.day = day
    return components.date ?? .distantPast
}

/// Tests for the one-time pre-gate reply-worthiness sweep (item 80): drafts
/// enqueued before the transactional/no-reply gate shipped are re-evaluated once
/// at launch and the now-skippable ones move to the skip log, while anything the
/// user has invested in is left untouched.
@MainActor
final class AppStatePreGateDraftSweepTests: XCTestCase {

    private let account = "me@gmail.com"
    private let originalReplyWorthinessGateDate = utcDate(year: 2026, month: 8, day: 2)
    private let dayBeforeOriginalReplyWorthinessGateDate = utcDate(year: 2026, month: 8, day: 1)
    private let preTransactionalGateDate = utcDate(year: 2026, month: 8, day: 20)

    /// Builds a reply draft with the given source sender. Defaults produce a plain,
    /// unedited reply draft eligible for the sweep; overrides model the exclusions.
    private func draft(
        id: UInt32,
        fromEmail: String,
        replyToEmail: String? = nil,
        originalBody: String? = nil,
        generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        regeneratedAt: Date? = nil,
        needsInfo: DraftNeedsInfo? = nil,
        offlineQueuedDispatch: OfflineQueuedDraftDispatch? = nil,
        authoredRecipients: [MailAddress]? = nil,
        replyWorthinessOverride: Bool? = false,
        sourceAccountEmail: String? = nil,
        sourceMailHost: String? = nil,
        sourceMailPort: Int? = nil
    ) -> Draft {
        var draft = Draft(
            id: id,
            sourceUIDValidity: 7,
            sourceAccountEmail: sourceAccountEmail ?? account,
            sourceMailHost: sourceMailHost,
            sourceMailPort: sourceMailPort,
            sourceMailbox: Mailbox.inbox.imapName,
            sourceSubject: "Subject \(id)",
            sourceFrom: MailAddress(email: fromEmail),
            sourceReplyTo: replyToEmail.map { MailAddress(email: $0) },
            sourceMessageID: "<\(id)@x.com>",
            replySubject: "Re: Subject \(id)",
            body: "Proposed reply \(id).",
            originalBody: originalBody,
            model: "claude-sonnet-4-6",
            generatedAt: generatedAt,
            regeneratedAt: regeneratedAt,
            needsInfo: needsInfo,
            offlineQueuedDispatch: offlineQueuedDispatch,
            authoredRecipients: authoredRecipients,
            replyWorthinessOverride: replyWorthinessOverride == true
        )
        draft.replyWorthinessOverride = replyWorthinessOverride
        return draft
    }

    private func makeAppState(
        seededDrafts: [Draft],
        hasRunPreGateDraftSweep: Bool = false,
        processedMessages: ProcessedMessages = ProcessedMessages()
    ) -> (AppState, AppStateMemoryPersistence) {
        let secrets = InMemorySecretStore()
        let persistence = AppStateMemoryPersistence(
            settings: Settings(
                schemaVersion: Settings.currentSchemaVersion,
                pollIntervalSeconds: 300,
                mailEmail: account,
                hasRunPreGateDraftSweep: hasRunPreGateDraftSweep
            ),
            processedMessages: processedMessages,
            pendingDrafts: seededDrafts
        )
        let appState = AppState(persistence: persistence, secrets: secrets)
        return (appState, persistence)
    }

    private func sourceMessage(for draft: Draft) -> MailMessage {
        MailMessage(
            id: draft.id,
            uidValidity: draft.sourceUIDValidity,
            from: draft.sourceFrom,
            replyTo: draft.sourceReplyTo,
            subject: draft.sourceSubject,
            date: "",
            messageID: draft.sourceMessageID
        )
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
        XCTAssertEqual(appState.activityEvents.filter { $0.kind == .skipped }.count, 2)
    }

    func testSweepRecordsActivityWithDraftSourceServerMetadata() throws {
        let inactiveAccount = "other@example.com"
        let noReply = draft(
            id: 1,
            fromEmail: "no-reply@example.com",
            sourceAccountEmail: inactiveAccount,
            sourceMailHost: "imap.other.example",
            sourceMailPort: 995
        )
        let (appState, persistence) = makeAppState(seededDrafts: [noReply])
        appState.mailHost = "imap.active.example"
        appState.mailPort = 143

        appState.runPreGateDraftSweepIfNeeded()

        let event = try XCTUnwrap(appState.activityEvents.first)
        XCTAssertEqual(event.account, inactiveAccount)
        XCTAssertEqual(event.sourceMailHost, "imap.other.example")
        XCTAssertEqual(event.sourceMailPort, 995)
        XCTAssertEqual(persistence.activityEvents.first?.sourceMailHost, "imap.other.example")
        XCTAssertEqual(persistence.activityEvents.first?.sourceMailPort, 995)

        appState.mailEmail = inactiveAccount
        appState.mailHost = "IMAP.OTHER.EXAMPLE"
        appState.mailPort = 995
        appState.isAccountConnected = true
        XCTAssertTrue(appState.canOpenActivityEvent(event))
    }

    func testSweptSkipEntrySurvivesRelaunch() throws {
        let noReply = draft(id: 1, fromEmail: "no-reply@example.com")
        var processed = ProcessedMessages()
        processed.insert(sourceMessage(for: noReply), account: account, mailbox: .inbox)
        let (appState, persistence) = makeAppState(seededDrafts: [noReply], processedMessages: processed)

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(persistence.skippedMessages.map(\.message.id), [1])
        XCTAssertEqual(persistence.skippedMessages.first?.preservesRecoveryWhenProcessed, true)

        let relaunched = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore()
        )

        XCTAssertEqual(relaunched.skippedMessages.map(\.message.id), [1])
        XCTAssertEqual(relaunched.skippedMessages.first?.reason, .noReplySender)
    }

    func testSweepRetainsAllRecoveryEntriesBeyondSkipLogLimit() throws {
        let (limitState, _) = makeAppState(seededDrafts: [])
        let count = limitState.skippedMessageLogLimit + 5
        let drafts = (1...count).map { id in
            draft(id: UInt32(id), fromEmail: "no-reply@example.com")
        }
        var processed = ProcessedMessages()
        for draft in drafts {
            processed.insert(sourceMessage(for: draft), account: account, mailbox: .inbox)
        }
        let (appState, persistence) = makeAppState(seededDrafts: drafts, processedMessages: processed)

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertTrue(appState.pendingDrafts.isEmpty)
        XCTAssertEqual(appState.skippedMessages.count, count)
        XCTAssertEqual(persistence.skippedMessages.count, count)
        XCTAssertTrue(persistence.skippedMessages.allSatisfy(\.preservesRecoveryWhenProcessed))

        let relaunched = AppState(
            persistence: persistence,
            secrets: InMemorySecretStore()
        )

        XCTAssertEqual(relaunched.skippedMessages.count, count)
        XCTAssertEqual(Set(relaunched.skippedMessages.map(\.id)).count, count)
    }

    func testSweepPreservesAllowlistedJunkDraft() throws {
        let noReply = draft(id: 1, fromEmail: "no-reply@example.com")
        let (appState, _) = makeAppState(seededDrafts: [noReply])
        appState.senderAllowlist = [SenderRule(rawInput: "no-reply@example.com")!]

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(appState.hasRunPreGateDraftSweep)
    }

    func testSweepPreservesPostGateAndOverrideDrafts() throws {
        let postGate = draft(
            id: 1,
            fromEmail: "no-reply@example.com",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let override = draft(
            id: 2,
            fromEmail: "shipment-tracking@amazon.com",
            replyWorthinessOverride: true
        )
        let legacy = draft(id: 3, fromEmail: "auto-confirm@amazon.com")
        let (appState, _) = makeAppState(seededDrafts: [postGate, override, legacy])

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(Set(appState.pendingDrafts.map(\.id)), [1, 2])
        XCTAssertEqual(appState.skippedMessages.map(\.message.id), [3])
        XCTAssertTrue(appState.hasRunPreGateDraftSweep)
    }

    func testSweepPreservesPostGateRegeneratedDraft() throws {
        let regenerated = draft(
            id: 1,
            fromEmail: "no-reply@example.com",
            regeneratedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let (appState, _) = makeAppState(seededDrafts: [regenerated])

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(appState.hasRunPreGateDraftSweep)
    }

    func testSweepPreservesPotentialLegacyOverrideDrafts() throws {
        let legacyOverride = draft(
            id: 1,
            fromEmail: "no-reply@example.com",
            generatedAt: originalReplyWorthinessGateDate,
            replyWorthinessOverride: nil
        )
        let olderNoReply = draft(
            id: 2,
            fromEmail: "no-reply@example.com",
            generatedAt: dayBeforeOriginalReplyWorthinessGateDate,
            replyWorthinessOverride: nil
        )
        let transactional = draft(
            id: 3,
            fromEmail: "auto-confirm@amazon.com",
            generatedAt: preTransactionalGateDate
        )
        let unmarkedTransactional = draft(
            id: 4,
            fromEmail: "auto-confirm@amazon.com",
            generatedAt: preTransactionalGateDate,
            replyWorthinessOverride: nil
        )
        let unmarkedNewBothAddressNoReply = draft(
            id: 5,
            fromEmail: "notifications@github.com",
            replyToEmail: "reply+abc@reply.github.com",
            generatedAt: preTransactionalGateDate,
            replyWorthinessOverride: nil
        )
        var processed = ProcessedMessages()
        for draft in [
            legacyOverride,
            olderNoReply,
            transactional,
            unmarkedTransactional,
            unmarkedNewBothAddressNoReply
        ] {
            processed.insert(sourceMessage(for: draft), account: account, mailbox: .inbox)
        }
        let (appState, _) = makeAppState(
            seededDrafts: [
                legacyOverride,
                olderNoReply,
                transactional,
                unmarkedTransactional,
                unmarkedNewBothAddressNoReply
            ],
            processedMessages: processed
        )

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(Set(appState.pendingDrafts.map(\.id)), [1])
        XCTAssertEqual(Set(appState.skippedMessages.map(\.message.id)), [2, 3, 4, 5])
        XCTAssertTrue(appState.hasRunPreGateDraftSweep)
    }

    func testSweepPreservesUnmarkedPreUpgradeRegeneratedDraft() throws {
        let regenerated = draft(
            id: 1,
            fromEmail: "auto-confirm@amazon.com",
            generatedAt: preTransactionalGateDate,
            replyWorthinessOverride: nil
        )
        let (appState, _) = makeAppState(seededDrafts: [regenerated])

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(appState.hasRunPreGateDraftSweep)
    }

    func testSweepDoesNotRemoveDraftWhenSkipPersistenceFails() throws {
        let noReply = draft(id: 1, fromEmail: "no-reply@example.com")
        let (appState, persistence) = makeAppState(seededDrafts: [noReply])
        persistence.skippedMessageSaveError = AppStatePersistenceError.writeDenied

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertEqual(persistence.pendingDrafts.map(\.id), [1])
        XCTAssertFalse(appState.hasRunPreGateDraftSweep)
        XCTAssertNotEqual(persistence.savedSettingsHistory.last?.hasRunPreGateDraftSweep, true)
    }

    func testSweepDoesNotCompleteAndRollsBackSkipWhenDraftRemovalFails() throws {
        let noReply = draft(id: 1, fromEmail: "no-reply@example.com")
        let (appState, persistence) = makeAppState(seededDrafts: [noReply])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(persistence.skippedMessages.isEmpty)
        XCTAssertFalse(appState.activityEvents.contains { $0.kind == .skipped })
        XCTAssertTrue(persistence.activityEvents.isEmpty)
        XCTAssertFalse(appState.hasRunPreGateDraftSweep)
        XCTAssertNotEqual(persistence.savedSettingsHistory.last?.hasRunPreGateDraftSweep, true)
    }

    func testSweepDraftRemovalFailureRollsBackNonVisibleAccountSkip() throws {
        let noReply = draft(
            id: 1,
            fromEmail: "no-reply@example.com",
            sourceAccountEmail: "other@example.com"
        )
        let (appState, persistence) = makeAppState(seededDrafts: [noReply])
        persistence.pendingDraftSaveError = AppStatePersistenceError.writeDenied

        appState.runPreGateDraftSweepIfNeeded()

        XCTAssertEqual(appState.pendingDrafts.map(\.id), [1])
        XCTAssertTrue(appState.skippedMessages.isEmpty)
        XCTAssertTrue(persistence.skippedMessages.isEmpty)
        XCTAssertFalse(appState.hasRunPreGateDraftSweep)
        XCTAssertNotEqual(persistence.savedSettingsHistory.last?.hasRunPreGateDraftSweep, true)
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
