import XCTest
@testable import Sentwise

/// Decoding of the item-73 `/v1/me` additions (`email`, `trial`, `subscription`)
/// and the pure presentation mapping that drives the Subscription pane.
final class SubscriptionModelTests: XCTestCase {

    private func decodeStatus(_ json: String) throws -> ManagedAccountStatus {
        try JSONDecoder().decode(ManagedAccountStatus.self, from: Data(json.utf8))
    }

    // MARK: - Decoding: optional blocks absent

    func testDecodesWithAllOptionalBlocksAbsent() throws {
        // An older Worker: only userId. trial/quota/subscription/email omitted.
        let status = try decodeStatus(#"{"userId":"user_1"}"#)
        XCTAssertEqual(status.userID, "user_1")
        XCTAssertNil(status.email)
        XCTAssertNil(status.trial)
        XCTAssertNil(status.quota)
        XCTAssertNil(status.subscription)
        XCTAssertEqual(status.stableAccountIdentifier, "clerk-user:user_1")
    }

    func testDecodesWithAllBlocksPresent() throws {
        let status = try decodeStatus(#"""
        {
          "userId": "user_1",
          "email": "marcus@example.com",
          "trial": {"startedAt":"2026-08-01T00:00:00Z","endsAt":"2026-08-15T00:00:00Z","active":true},
          "quota": {"unit":"drafts","used":3,"limit":50,"remaining":47,
                    "resetsAt":"2026-08-18T00:00:00Z","enforcement":"soft"},
          "subscription": {"plan":"pro","status":"active",
                           "renewsAt":"2026-09-01T00:00:00Z",
                           "manageBillingUrl":"https://billing.example/portal"}
        }
        """#)
        XCTAssertEqual(status.email, "marcus@example.com")
        XCTAssertEqual(status.trial?.active, true)
        XCTAssertEqual(status.trial?.endsAt, ManagedQuotaDate.date(from: "2026-08-15T00:00:00Z"))
        XCTAssertEqual(status.quota?.used, 3)
        XCTAssertEqual(status.subscription?.plan, .pro)
        XCTAssertEqual(status.subscription?.status, .active)
        XCTAssertEqual(status.subscription?.manageBillingURL, "https://billing.example/portal")
    }

    // MARK: - Decoding: unknown enum values never fail

    func testUnknownPlanAndStatusFallBackToUnknown() throws {
        let status = try decodeStatus(#"""
        {"userId":"u","subscription":{"plan":"enterprise","status":"grace_period"}}
        """#)
        XCTAssertEqual(status.subscription?.plan, .unknown)
        XCTAssertEqual(status.subscription?.status, .unknown)
    }

    func testKnownSnakeCaseStatusDecodes() throws {
        let status = try decodeStatus(#"{"userId":"u","subscription":{"plan":"trial","status":"past_due"}}"#)
        XCTAssertEqual(status.subscription?.status, .pastDue)
        XCTAssertEqual(status.subscription?.plan, .trial)
    }

    func testNonePlanDecodes() throws {
        let status = try decodeStatus(#"{"userId":"u","subscription":{"plan":"none","status":"canceled"}}"#)
        XCTAssertEqual(status.subscription?.plan, .noPlan)
        XCTAssertEqual(status.subscription?.status, .canceled)
    }

    func testBlankManageBillingURLBecomesNil() throws {
        let status = try decodeStatus(#"{"userId":"u","subscription":{"plan":"trial","status":"trialing","manageBillingUrl":"  "}}"#)
        XCTAssertNil(status.subscription?.manageBillingURL)
    }

    func testEmailAndUserIDAreTrimmedAndEmptiedToNil() throws {
        let status = try decodeStatus(#"{"userId":"  user_2  ","email":"   "}"#)
        XCTAssertEqual(status.userID, "user_2")
        XCTAssertNil(status.email)
    }

    func testMalformedQuotaStillThrows() {
        // Present-but-wrong-type quota must surface as a decode failure (a new
        // enum case is tolerated, a structurally broken quota is not).
        XCTAssertThrowsError(try decodeStatus(#"{"userId":"u","quota":"not-an-object"}"#))
    }

    // MARK: - Trial-days math

    func testTrialDaysRemainingRoundsUp() {
        let now = ManagedQuotaDate.date(from: "2026-08-10T00:00:00Z")!
        let endsAt = ManagedQuotaDate.date(from: "2026-08-15T06:00:00Z")! // 5.25 days
        XCTAssertEqual(SubscriptionPaneModel.trialDaysRemaining(endsAt: endsAt, now: now), 6)
    }

    func testTrialDaysRemainingClampsAtZeroWhenPassed() {
        let now = ManagedQuotaDate.date(from: "2026-08-20T00:00:00Z")!
        let endsAt = ManagedQuotaDate.date(from: "2026-08-15T00:00:00Z")!
        XCTAssertEqual(SubscriptionPaneModel.trialDaysRemaining(endsAt: endsAt, now: now), 0)
    }

    func testTrialDaysRemainingNilWhenNoEnd() {
        XCTAssertNil(SubscriptionPaneModel.trialDaysRemaining(endsAt: nil, now: Date()))
    }

    // MARK: - Presentation mapping

    private func status(
        trial: ManagedTrial? = nil,
        quota: ManagedQuota? = nil,
        subscription: ManagedSubscription? = nil
    ) -> ManagedAccountStatus {
        ManagedAccountStatus(userID: "u", email: "m@example.com", trial: trial, quota: quota, subscription: subscription)
    }

    private func snapshot(
        plan: ManagedSubscription.Plan,
        statusValue: ManagedSubscription.Status,
        renewsAt: Date? = nil,
        capturedAt: Date = Date()
    ) -> SubscriptionSnapshot {
        SubscriptionSnapshot(plan: plan, status: statusValue, renewsAt: renewsAt, capturedAt: capturedAt)
    }

    private func quota() -> ManagedQuota {
        ManagedQuota(
            used: 1,
            limit: 10,
            remaining: 9,
            resetsAt: ManagedQuotaDate.date(from: "2026-08-18T00:00:00Z")!
        )
    }

    func testActivePlanShowsNameAndRenewal() {
        let sub = ManagedSubscription(plan: .pro, status: .active,
                                      renewsAt: ManagedQuotaDate.date(from: "2026-09-12T00:00:00Z"))
        let model = SubscriptionPaneModel.make(from: status(subscription: sub))
        XCTAssertEqual(model.planText, "Pro")
        XCTAssertEqual(model.secondaryText?.hasPrefix("Renews"), true)
        XCTAssertFalse(model.isProblemState)
        XCTAssertFalse(model.showsOwnKeyFallback)
    }

    func testActivePaidTiersEachShowTheirNameAndRenewal() {
        // Item 56c: after a purchase the pane must read cleanly for every
        // purchasable tier (starter/pro/unlimited), naming the tier + renewal.
        let cases: [(ManagedSubscription.Plan, String)] = [
            (.starter, "Starter"),
            (.pro, "Pro"),
            (.unlimited, "Unlimited")
        ]
        for (plan, expectedName) in cases {
            let sub = ManagedSubscription(
                plan: plan,
                status: .active,
                renewsAt: ManagedQuotaDate.date(from: "2026-09-12T00:00:00Z")
            )
            let model = SubscriptionPaneModel.make(from: status(subscription: sub))
            XCTAssertEqual(model.planText, expectedName)
            XCTAssertEqual(model.secondaryText?.hasPrefix("Renews"), true, "expected renewal line for \(expectedName)")
            XCTAssertFalse(model.isProblemState, "\(expectedName) active must not be a problem state")
        }
    }

    func testTrialingShowsDaysLeft() {
        let now = ManagedQuotaDate.date(from: "2026-08-10T00:00:00Z")!
        let trial = ManagedTrial(endsAt: ManagedQuotaDate.date(from: "2026-08-15T00:00:00Z"), active: true)
        let sub = ManagedSubscription(plan: .trial, status: .trialing)
        let model = SubscriptionPaneModel.make(from: status(trial: trial, subscription: sub), now: now)
        XCTAssertEqual(model.planText, "Trial — 5 days left")
        XCTAssertNil(model.secondaryText)
        XCTAssertFalse(model.isProblemState)
    }

    func testTrialingWithOneDaySingularizes() {
        let now = ManagedQuotaDate.date(from: "2026-08-14T01:00:00Z")!
        let trial = ManagedTrial(endsAt: ManagedQuotaDate.date(from: "2026-08-15T00:00:00Z"), active: true)
        let sub = ManagedSubscription(plan: .trial, status: .trialing)
        let model = SubscriptionPaneModel.make(from: status(trial: trial, subscription: sub), now: now)
        XCTAssertEqual(model.planText, "Trial — 1 day left")
    }

    func testTrialingWithoutEndDateStaysActive() {
        let sub = ManagedSubscription(plan: .trial, status: .trialing)
        let model = SubscriptionPaneModel.make(from: status(subscription: sub))
        XCTAssertEqual(model.planText, "Trial")
        XCTAssertNil(model.secondaryText)
        XCTAssertFalse(model.isProblemState)
        XCTAssertFalse(model.showsOwnKeyFallback)
    }

    func testLapsedShowsTrialEndedAndProblemState() {
        let sub = ManagedSubscription(plan: .trial, status: .lapsed)
        let model = SubscriptionPaneModel.make(from: status(subscription: sub))
        XCTAssertEqual(model.planText, "Trial ended")
        XCTAssertTrue(model.isProblemState)
        XCTAssertTrue(model.showsOwnKeyFallback)
        XCTAssertEqual(model.secondaryText?.contains("your own AI key") ?? false, true)
    }

    func testLapsedPaidPlanNamesThePlanNotTheTrial() {
        // Post-56c: a former Pro subscriber whose plan lapsed must not be
        // told their "trial" ended.
        let sub = ManagedSubscription(plan: .pro, status: .lapsed)
        let model = SubscriptionPaneModel.make(from: status(subscription: sub))
        XCTAssertEqual(model.planText, "Pro — lapsed")
        XCTAssertTrue(model.isProblemState)
        XCTAssertFalse(model.planText.contains("Trial"))
        XCTAssertEqual(model.secondaryText?.contains("Pro plan has lapsed") ?? false, true)
    }

    func testPastDueIsProblemStateWithPlanName() {
        let sub = ManagedSubscription(plan: .pro, status: .pastDue)
        let model = SubscriptionPaneModel.make(from: status(subscription: sub))
        XCTAssertEqual(model.planText, "Pro")
        XCTAssertTrue(model.isProblemState)
        XCTAssertEqual(model.secondaryText?.contains("payment") ?? false, true)
    }

    func testSnapshotRendersWhenLiveStatusUnavailable() {
        let renewsAt = ManagedQuotaDate.date(from: "2026-09-12T00:00:00Z")
        let model = SubscriptionPaneModel.make(
            from: nil,
            snapshot: snapshot(plan: .pro, statusValue: .active, renewsAt: renewsAt)
        )

        XCTAssertEqual(model.planText, "Pro")
        XCTAssertEqual(model.secondaryText?.hasPrefix("Renews"), true)
        XCTAssertFalse(model.isProblemState)
    }

    func testExpiredEntitledSnapshotShowsUnconfirmedProblemState() {
        let now = ManagedQuotaDate.date(from: "2026-09-05T00:00:00Z")!
        let model = SubscriptionPaneModel.make(
            from: nil,
            snapshot: snapshot(
                plan: .pro,
                statusValue: .active,
                capturedAt: now.addingTimeInterval(-8 * 86_400)
            ),
            now: now
        )

        XCTAssertEqual(model.planText, "Subscription unavailable")
        XCTAssertTrue(model.isProblemState)
        XCTAssertTrue(model.showsOwnKeyFallback)
        XCTAssertEqual(model.secondaryText?.contains("couldn't confirm") ?? false, true)
    }

    func testSnapshotTrialUsesStoredEndDate() {
        let now = ManagedQuotaDate.date(from: "2026-08-10T00:00:00Z")!
        let endsAt = ManagedQuotaDate.date(from: "2026-08-12T00:00:00Z")
        let model = SubscriptionPaneModel.make(
            from: nil,
            snapshot: snapshot(plan: .trial, statusValue: .trialing, renewsAt: endsAt),
            now: now
        )

        XCTAssertEqual(model.planText, "Trial — 2 days left")
        XCTAssertFalse(model.isProblemState)
    }

    func testSnapshotTrialPastStoredEndShowsTrialEnded() {
        let now = ManagedQuotaDate.date(from: "2026-08-12T01:00:00Z")!
        let endsAt = ManagedQuotaDate.date(from: "2026-08-12T00:00:00Z")
        let model = SubscriptionPaneModel.make(
            from: nil,
            snapshot: snapshot(plan: .trial, statusValue: .trialing, renewsAt: endsAt),
            now: now
        )

        XCTAssertEqual(model.planText, "Trial ended")
        XCTAssertTrue(model.isProblemState)
    }

    func testStaleLiveStatusUsesSnapshotProblemState() {
        let live = ManagedSubscription(plan: .pro, status: .active)
        let model = SubscriptionPaneModel.make(
            from: status(subscription: live),
            snapshot: snapshot(plan: .pro, statusValue: .pastDue),
            statusIsFresh: false
        )

        XCTAssertEqual(model.planText, "Pro")
        XCTAssertTrue(model.isProblemState)
        XCTAssertTrue(model.showsOwnKeyFallback)
        XCTAssertEqual(model.secondaryText?.contains("payment") ?? false, true)
    }

    func testFreshLiveStatusWinsOverSnapshot() {
        let live = ManagedSubscription(plan: .starter, status: .active)
        let model = SubscriptionPaneModel.make(
            from: status(subscription: live),
            snapshot: snapshot(plan: .pro, statusValue: .pastDue),
            statusIsFresh: true
        )

        XCTAssertEqual(model.planText, "Starter")
        XCTAssertFalse(model.isProblemState)
    }

    func testCanceledIsProblemState() {
        let sub = ManagedSubscription(plan: .pro, status: .canceled)
        let model = SubscriptionPaneModel.make(from: status(subscription: sub))
        XCTAssertEqual(model.planText, "Canceled")
        XCTAssertTrue(model.isProblemState)
    }

    // MARK: - Derived-from-trial (older Worker: subscription absent)

    func testDerivesTrialingFromActiveTrialWhenSubscriptionAbsent() {
        let now = ManagedQuotaDate.date(from: "2026-08-10T00:00:00Z")!
        let trial = ManagedTrial(endsAt: ManagedQuotaDate.date(from: "2026-08-13T00:00:00Z"), active: true)
        let model = SubscriptionPaneModel.make(from: status(trial: trial), now: now)
        XCTAssertEqual(model.planText, "Trial — 3 days left")
        XCTAssertFalse(model.isProblemState)
    }

    func testDerivesLapsedFromInactiveTrialWhenSubscriptionAbsent() {
        let trial = ManagedTrial(endsAt: ManagedQuotaDate.date(from: "2026-08-01T00:00:00Z"), active: false)
        let model = SubscriptionPaneModel.make(from: status(trial: trial))
        XCTAssertEqual(model.planText, "Trial ended")
        XCTAssertTrue(model.isProblemState)
    }

    func testInactiveTrialWithLegacyQuotaUsesPaidSnapshotWhenSubscriptionAbsent() {
        let trial = ManagedTrial(endsAt: ManagedQuotaDate.date(from: "2026-08-01T00:00:00Z"), active: false)
        let model = SubscriptionPaneModel.make(
            from: status(trial: trial, quota: quota()),
            snapshot: snapshot(plan: .pro, statusValue: .active)
        )
        XCTAssertEqual(model.planText, "Pro")
        XCTAssertFalse(model.isProblemState)
    }

    func testUnknownSubscriptionWithNoTrialFallsBackToActive() {
        let sub = ManagedSubscription(plan: .unknown, status: .unknown)
        let model = SubscriptionPaneModel.make(from: status(subscription: sub))
        XCTAssertEqual(model.planText, "Active")
        XCTAssertFalse(model.isProblemState)
    }

    func testStaleNilStatusWithoutSnapshotShowsUnavailable() {
        let model = SubscriptionPaneModel.make(from: nil, snapshot: nil, statusIsFresh: false)
        XCTAssertEqual(model.planText, "Subscription unavailable")
        XCTAssertTrue(model.isProblemState)
        XCTAssertTrue(model.showsOwnKeyFallback)
    }

    func testNilStatusIsNeutral() {
        let model = SubscriptionPaneModel.make(from: nil)
        XCTAssertEqual(model.planText, "Active")
        XCTAssertFalse(model.isProblemState)
    }
}
