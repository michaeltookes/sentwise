import Foundation

/// The decision `CheckoutNavigationPolicy` produces for one navigation inside the
/// Paddle checkout `WKWebView`.
enum CheckoutNavigationDecision: Equatable {
    /// Let the navigation proceed inside the checkout sheet.
    case allowInSheet
    /// Cancel the in-sheet navigation and hand the URL to the default browser.
    case openExternally(URL)
    /// Cancel the navigation and do nothing (missing URL or a non-web scheme).
    case block
}

/// Decides what a navigation inside the Paddle checkout `WKWebView` may do
/// (backlog item 95 / security finding A-M2). The sheet loads a local harness
/// page whose base URL is spoofed to `https://sentwise.ai` and then renders
/// Paddle's overlay checkout inside nested iframes. Without a navigation policy,
/// page script could point the *sheet's own top-level document* at any URL,
/// turning a trusted, chrome-less payment surface into a phishing canvas.
///
/// Split out as a pure function so the logic is unit-testable without a live
/// `WKWebView`. The rule:
///
/// * **Sub-frame navigations are allowed unconditionally.** Overlay checkout, the
///   payment-provider frames, and 3-D Secure step-up all load inside nested
///   iframes whose hosts we cannot enumerate (card issuers, ACS servers), so
///   restricting them would break real payments. Only the top-level document is
///   a phishing risk.
/// * **Top-level navigations** may stay in the sheet only for the harness origin
///   (`sentwise.ai`, plus the `about:` bootstrap load `loadHTMLString` drives)
///   and the Paddle payment hosts. Any other `http(s)` top-level navigation is
///   cancelled and opened in the default browser; anything non-web is blocked.
enum CheckoutNavigationPolicy {
    /// Host suffixes whose pages may load as the sheet's *top-level* document.
    /// `sentwise.ai` is the harness origin; the Paddle hosts cover the CDN and the
    /// sandbox/live checkout domains as a safety margin should a flow ever redirect
    /// the top frame (overlay checkout is iframe-based, so nested payment/3-DS
    /// frames are already permitted as sub-frames).
    static let allowedTopLevelHostSuffixes: [String] = [
        "sentwise.ai",
        "paddle.com",
        "paddlecdn.com"
    ]

    /// The decision for a navigation to `url` in a frame that is (or is not) the
    /// main frame.
    static func decision(
        for url: URL?,
        isMainFrameNavigation: Bool
    ) -> CheckoutNavigationDecision {
        // Sub-frame navigations (the overlay iframe, payment-provider frames, and
        // 3-D Secure step-up) are allowed generally — see the type doc.
        guard isMainFrameNavigation else { return .allowInSheet }

        guard let url else { return .block }
        let scheme = url.scheme?.lowercased()

        // WebKit drives the initial `loadHTMLString` bootstrap through `about:`
        // URLs; allow those so the harness page can load.
        if scheme == "about" { return .allowInSheet }

        // Only web navigations can stay in-sheet or open externally; block the
        // rest (file:, data:, custom app schemes) rather than following them.
        guard scheme == "https" || scheme == "http" else { return .block }

        // Keep the sheet's top-level document on the harness origin or a Paddle
        // payment host, over https only.
        if scheme == "https", let host = url.host?.lowercased(), isAllowedTopLevelHost(host) {
            return .allowInSheet
        }

        return .openExternally(url)
    }

    /// Whether `host` matches one of the allow-listed top-level host suffixes,
    /// either exactly or as a sub-domain.
    static func isAllowedTopLevelHost(_ host: String) -> Bool {
        allowedTopLevelHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }
}
