import Foundation

/// Pure, testable presentation logic for the Account & subscription pane
/// (backlog item 73). Maps a `ManagedAccountStatus` (its `trial` + `subscription`
/// blocks) into the plan line, an optional detail/explanation line, and whether
/// the account is in a problem state (past-due / canceled / lapsed) that should
/// surface the "use your own key" fallback. No SwiftUI, no `Date()` capture —
/// `now` is injected so the day math is deterministic under test.
struct SubscriptionPaneModel: Equatable {
    /// The value shown next to "Plan" (e.g. "Trial — 5 days left", "Individual",
    /// "Trial ended").
    var planText: String
    /// A secondary line under the plan: "Renews <date>" when active, or the
    /// explanatory copy for a problem state. `nil` when there is nothing to add.
    var secondaryText: String?
    /// Whether managed drafting is paused (past-due / canceled / lapsed). Drives
    /// the red styling and the own-key fallback link.
    var isProblemState: Bool

    /// Whether to show the "use your own AI key" fallback link. Identical to
    /// `isProblemState` today; named separately so the view reads clearly.
    var showsOwnKeyFallback: Bool { isProblemState }

    static func make(
        from status: ManagedAccountStatus?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> SubscriptionPaneModel {
        let trialDays = trialDaysRemaining(endsAt: status?.trial?.endsAt, now: now)
        let effective = effectivePlanStatus(from: status, trialDays: trialDays)

        switch effective.status {
        case .active:
            return SubscriptionPaneModel(
                planText: effective.plan.displayName,
                secondaryText: renewalLine(status?.subscription?.renewsAt, calendar: calendar, locale: locale),
                isProblemState: false
            )
        case .trialing:
            return activeTrialModel(days: trialDays)
        case .pastDue:
            return SubscriptionPaneModel(
                planText: effective.plan.displayName,
                secondaryText: "Your last payment didn't go through, so managed drafting is paused. "
                    + "Drafting with your own AI key still works while you fix billing.",
                isProblemState: true
            )
        case .canceled:
            return SubscriptionPaneModel(
                planText: "Canceled",
                secondaryText: "Your subscription is canceled, so managed drafting is paused. "
                    + "Drafting with your own AI key still works.",
                isProblemState: true
            )
        case .lapsed:
            // A lapsed *trial* reads "Trial ended"; a lapsed paid plan (post-56c)
            // must not — name the plan so a former subscriber isn't told their
            // "trial" ended.
            if effective.plan == .trial || effective.plan == .unknown {
                return trialModel(days: 0)
            }
            return SubscriptionPaneModel(
                planText: "\(effective.plan.displayName) — lapsed",
                secondaryText: "Your \(effective.plan.displayName) plan has lapsed, so managed drafting is paused "
                    + "until you renew. Drafting with your own AI key still works.",
                isProblemState: true
            )
        case .unknown:
            // Signed in but the server sent a status this build doesn't know.
            // Fall back to the trial view when a trial is present, else a neutral
            // "Active" so the pane never shows a raw/empty value.
            if trialDays != nil || status?.trial != nil {
                return trialModel(days: trialDays)
            }
            return SubscriptionPaneModel(planText: "Active", secondaryText: nil, isProblemState: false)
        }
    }

    /// Whole days remaining until `endsAt`, rounded up so any time left reads as
    /// at least "1 day left"; clamped at 0 once the instant has passed. `nil` when
    /// no trial end is known.
    static func trialDaysRemaining(
        endsAt: Date?,
        now: Date = Date()
    ) -> Int? {
        guard let endsAt else { return nil }
        let seconds = endsAt.timeIntervalSince(now)
        if seconds <= 0 { return 0 }
        return Int((seconds / 86_400).rounded(.up))
    }

    // MARK: - Helpers

    /// Resolves an effective (plan, status) pair. Prefers the server-sent
    /// subscription; when it is absent (older Worker), derives one from the trial
    /// block so pre-56c installs still render.
    private static func effectivePlanStatus(
        from status: ManagedAccountStatus?,
        trialDays: Int?
    ) -> (plan: ManagedSubscription.Plan, status: ManagedSubscription.Status) {
        if let subscription = status?.subscription {
            return (subscription.plan, subscription.status)
        }
        if let trial = status?.trial {
            let active = trial.active ?? ((trialDays ?? 0) > 0)
            return (.trial, active ? .trialing : .lapsed)
        }
        return (.unknown, .unknown)
    }

    private static func trialModel(days: Int?) -> SubscriptionPaneModel {
        guard let days, days > 0 else {
            return SubscriptionPaneModel(
                planText: "Trial ended",
                secondaryText: "Your free trial has ended, so managed drafting is paused until you choose a plan. "
                    + "Drafting with your own AI key still works.",
                isProblemState: true
            )
        }
        let unit = days == 1 ? "day" : "days"
        return SubscriptionPaneModel(
            planText: "Trial — \(days) \(unit) left",
            secondaryText: nil,
            isProblemState: false
        )
    }

    private static func activeTrialModel(days: Int?) -> SubscriptionPaneModel {
        guard let days else {
            return SubscriptionPaneModel(planText: "Trial", secondaryText: nil, isProblemState: false)
        }
        return trialModel(days: days)
    }

    private static func renewalLine(
        _ renewsAt: Date?,
        calendar: Calendar,
        locale: Locale
    ) -> String? {
        guard let renewsAt else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return "Renews \(formatter.string(from: renewsAt))"
    }
}

extension ManagedSubscription.Plan {
    /// The user-facing plan name for the Subscription pane.
    var displayName: String {
        switch self {
        case .trial: return "Trial"
        case .individual: return "Individual"
        case .team: return "Team"
        case .noPlan: return "No plan"
        case .unknown: return "Sentwise AI"
        }
    }
}
