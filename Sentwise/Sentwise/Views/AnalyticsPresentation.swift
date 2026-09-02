import Foundation

/// Pure, testable presentation for the Analytics tab's quota & usage section
/// (item 84). Maps a `ManagedQuota` (from item 56b metering, via `managedQuota`)
/// into the numbers/text the read-only section shows. Returns `nil` when the
/// quota is unknown so the view can render its short "signed out / no usage yet"
/// caption instead. No SwiftUI, no `Date()` capture — `calendar`/`locale` are
/// injected so the reset description is deterministic under test.
///
/// This intentionally shows **numbers/text only** — the allowance progress bar
/// lives in the Subscription pane (item 73's `ManagedUsageView`) and must not be
/// duplicated here.
struct AnalyticsQuotaPresentation: Equatable {
    /// Drafts consumed in the current weekly window.
    var draftsUsed: Int
    /// The weekly allotment.
    var limit: Int
    /// Drafts remaining in the current window.
    var remaining: Int
    /// A subdued "under the hood" tokens caption (the UI unit is drafts).
    var tokensCaption: String
    /// "resets <weekday>, <time>" text, or `nil` when the reset instant is unknown
    /// (the Worker omitted `resetsAt`).
    var resetText: String?
    /// The extra-usage row — present only when `extraPurchased > 0`.
    ///
    /// **56c seam:** this reflects the *current window's* `extraPurchased` only.
    /// A billing-period "times bought extra this month" count needs a
    /// billing-period concept the account doesn't have until checkout ships (56c);
    /// do not synthesize a monthly number here.
    var extraPurchasedRow: String?

    static func make(
        from quota: ManagedQuota?,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> AnalyticsQuotaPresentation? {
        guard let quota else { return nil }

        let tokens = "\(formatted(quota.tokensUsed, locale: locale)) of "
            + "\(formatted(quota.tokenLimit, locale: locale)) tokens used"

        let reset: String?
        if quota.hasKnownReset {
            reset = "resets " + ManagedQuota.resetDescription(quota.resetsAt, calendar: calendar, locale: locale)
        } else {
            reset = nil
        }

        let extraRow = quota.extraPurchased > 0
            ? "Extra usage purchased this window: \(quota.extraPurchased)"
            : nil

        return AnalyticsQuotaPresentation(
            draftsUsed: quota.used,
            limit: quota.limit,
            remaining: quota.remaining,
            tokensCaption: tokens,
            resetText: reset,
            extraPurchasedRow: extraRow
        )
    }

    /// The primary "N of M drafts used · K remaining" summary line.
    var draftsSummary: String {
        "\(draftsUsed) of \(limit) drafts used · \(remaining) remaining"
    }

    private static func formatted(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
