import Foundation

/// The Legal & Support links surfaced in Settings → About (backlog item 72).
///
/// The hosted policy and support pages are versioned in the `sentwise-landing-page`
/// repo and served from `sentwise.ai`; the app only links out to them, it makes no
/// legal or retention claims of its own. Centralising the definitions here keeps the
/// exact destinations and accessibility identifiers testable and the About pane
/// declarative.
enum LegalSupportLinks {

    /// One outbound link: its accessibility identifier, visible title, SF Symbol,
    /// destination URL, and spoken accessibility label.
    struct Item: Identifiable, Equatable {
        /// Stable accessibility identifier (also the SwiftUI `id`).
        let id: String
        let title: String
        let systemImage: String
        let url: URL
        let accessibilityLabel: String
    }

    /// The canonical marketing/legal host. All links hang off this base.
    static let baseURLString = "https://sentwise.ai"

    static let terms = Item(
        id: "legalLinkTerms",
        title: "Terms of Service",
        systemImage: "doc.text",
        url: URL(string: "\(baseURLString)/terms")!,
        accessibilityLabel: "Open the Sentwise Terms of Service"
    )

    static let privacy = Item(
        id: "legalLinkPrivacy",
        title: "Privacy Policy",
        systemImage: "hand.raised",
        url: URL(string: "\(baseURLString)/privacy")!,
        accessibilityLabel: "Open the Sentwise Privacy Policy"
    )

    static let security = Item(
        id: "legalLinkSecurity",
        title: "Security",
        systemImage: "lock.shield",
        url: URL(string: "\(baseURLString)/security")!,
        accessibilityLabel: "Open the Sentwise Security page"
    )

    static let support = Item(
        id: "legalLinkSupport",
        title: "Support",
        systemImage: "lifepreserver",
        url: URL(string: "\(baseURLString)/support")!,
        accessibilityLabel: "Open Sentwise Support"
    )

    /// Rendered order in the About pane.
    static let all: [Item] = [terms, privacy, security, support]
}
