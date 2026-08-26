import Foundation

/// Builds the `mailto:` URL that "Report a Problem" opens (item 36).
///
/// `mailto:` cannot auto-attach a file, so the flow is: reveal the redacted
/// bundle in Finder, then open a pre-filled email that tells the user to attach
/// that just-revealed file. The body carries the app and macOS versions so a
/// report is actionable even before the attachment is added.
enum FeedbackMailComposer {

    /// The dedicated feedback address baked into the app (owner-confirmed). The
    /// inbox is stood up as a separate launch prerequisite (backlog item 74); the
    /// app ships the address regardless.
    static let feedbackAddress = "feedback@sentwise.ai"

    /// Builds the pre-filled `mailto:` URL. Subject and body are percent-encoded
    /// via `URLComponents`. Returns `nil` only if URL assembly fails.
    static func mailtoURL(
        appVersion: String,
        buildNumber: String,
        osVersion: String,
        bundleFilename: String
    ) -> URL? {
        let subject = "Sentwise problem report (v\(appVersion))"
        let body = """
        Describe the problem:


        What did you expect to happen?


        Steps to reproduce:


        ---
        App version: \(appVersion) (\(buildNumber))
        macOS: \(osVersion)

        Please attach the diagnostics file just revealed in Finder:
        \(bundleFilename)
        (It is redacted — no email content — so it is safe to send.)
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        // URLComponents leaves "+" unescaped in query values, where some mail
        // clients read it as a space; encode it so versions/text survive intact.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
