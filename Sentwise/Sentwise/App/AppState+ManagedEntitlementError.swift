import Foundation

extension AppState {
    func recordManagedEntitlementBlockedSnapshot(now: Date = Date()) {
        if let snapshot = managedEntitlementBlockedSnapshot(from: managedAccountStatus, now: now) {
            cacheSubscriptionSnapshot(snapshot)
            return
        }
        guard let snapshot = effectiveSubscriptionSnapshot else { return }
        cacheSubscriptionSnapshot(snapshot.blockedByManagedEntitlementError(capturedAt: now))
    }

    private func managedEntitlementBlockedSnapshot(
        from status: ManagedAccountStatus?,
        now: Date
    ) -> SubscriptionSnapshot? {
        guard let status else { return nil }
        if let subscription = status.subscription {
            return SubscriptionSnapshot(
                plan: subscription.plan,
                status: subscription.status.blockedByManagedEntitlementError(plan: subscription.plan),
                renewsAt: subscription.renewsAt ?? (subscription.plan == .trial ? status.trial?.endsAt : nil),
                manageBillingURL: subscription.manageBillingURL,
                capturedAt: now
            )
        }
        if let trial = status.trial {
            return SubscriptionSnapshot(plan: .trial, status: .lapsed, renewsAt: trial.endsAt, capturedAt: now, source: .trial)
        }
        guard status.quota != nil else { return nil }
        return SubscriptionSnapshot(plan: .unknown, status: .unknown, capturedAt: now, source: .legacyQuota)
    }
}

private extension SubscriptionSnapshot {
    func blockedByManagedEntitlementError(capturedAt now: Date) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            plan: plan,
            status: status.blockedByManagedEntitlementError(plan: plan),
            renewsAt: renewsAt,
            manageBillingURL: manageBillingURL,
            capturedAt: now,
            source: source
        )
    }
}

private extension ManagedSubscription.Status {
    func blockedByManagedEntitlementError(plan: ManagedSubscription.Plan) -> Self {
        if self == .canceled || self == .lapsed {
            return self
        }
        if plan == .trial || plan == .noPlan {
            return .lapsed
        }
        return .pastDue
    }
}
