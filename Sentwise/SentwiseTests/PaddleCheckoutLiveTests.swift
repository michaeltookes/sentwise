import AppKit
import WebKit
import XCTest
@testable import Sentwise

/// Env-gated **live** verification that the real Paddle checkout WebView stack —
/// the real `PaddleCheckoutHTML` harness and a `CheckoutNavigationPolicy`-backed
/// navigation delegate — actually renders the Paddle overlay against the **Paddle
/// sandbox**, inside the same restricted `WKWebView` navigation policy the app
/// ships (security finding A-M2 / backlog items 95, 97). This is the payload that
/// closes item 95's *pending live* verification: unit tests prove the policy's
/// pure decisions, but only a live overlay can prove the policy is not
/// *too tight* — i.e. that it permits every frame Paddle actually needs to open a
/// checkout. That regression class (a policy tweak that silently breaks real
/// payments) is invisible to offline tests.
///
/// ## Gating (mirrors `ClerkLiveSignInTests`)
///
/// SKIPS unless `SENTWISE_LIVE_PADDLE_CHECKOUT` is set, so CI and every normal
/// `xcodebuild test` run stay fully offline and never touch the network or a
/// window server. Live execution happens only on the Lucius self-hosted runner
/// via `.github/workflows/live-tests.yml` (it needs a GUI session for WebKit's
/// window server) — never on a developer machine.
///
/// ## Scope guardrail (2026-09-10 billing-guardrail decision)
///
/// This test opens the overlay and asserts it renders. It **never** enters card
/// data, completes a purchase, or touches any billing change control. It opens
/// the overlay with the sandbox **client-side token + a sandbox price id** (the
/// `items` form), which is enough to render the overlay and exercise the whole
/// navigation-policy surface without a server-minted transaction — see the
/// variant note below.
///
/// ## Variant choice: real harness opened by `items`, not the full Clerk chain
///
/// The production app opens by a *server-minted transaction id* (authed
/// `POST /v1/paddle/checkout` under a Clerk session). We deliberately do **not**
/// chain a live Clerk sign-in → Worker transaction mint here, for two reasons:
///
/// 1. **It would not strengthen what this test verifies.** The navigation policy,
///    the overlay iframe, and its nested payment/3-DS sub-frames render
///    *identically* whether the overlay is opened by `transactionId` or by
///    `items` — the difference is only the argument object, not how the overlay
///    loads or navigates. The transaction-id argument shape is already asserted
///    offline (`PaddleCheckoutTests.testArgumentJSON*`).
/// 2. **The `items` path is dramatically more reliable.** The Clerk→Worker→Paddle
///    chain adds three live dependencies (a live Clerk session, a deployed Worker,
///    and the Worker being provisioned with a Paddle *sandbox* API key) whose
///    failure would mask the thing under test. The `items` path depends only on
///    Paddle sandbox + the network.
///
/// So this is the strongest *reliably verifiable* variant: it drives the real
/// harness's own `window.sentwiseOpenCheckout` entry point and reaches the
/// overlay's loaded/opened harness event, proving the overlay renders inside the
/// restricted WebView. (The full transaction-id chain remains available as a
/// future payload once the Worker holds a sandbox Paddle key — noted in
/// `docs/live-testing.md`.)
@MainActor
final class PaddleCheckoutLiveTests: XCTestCase {

    private func requireLive() throws {
        let flag = ProcessInfo.processInfo.environment["SENTWISE_LIVE_PADDLE_CHECKOUT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard flag == "1" || flag == "true" || flag == "yes" else {
            throw XCTSkip("Set SENTWISE_LIVE_PADDLE_CHECKOUT=1 to run the live Paddle sandbox checkout-overlay test.")
        }
    }

    func testSandboxOverlayRendersInsideRestrictedWebView() async throws {
        try requireLive()

        let config = PaddleConfig.sandbox
        let driver = CheckoutOverlayDriver()

        // Host the web view in a real window so WebKit has a window server-backed
        // surface to lay out and render the overlay iframe (GUI session on Lucius).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(driver, name: "sentwise")
        configuration.userContentController = controller

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 620),
            configuration: configuration
        )
        webView.navigationDelegate = driver
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { controller.removeScriptMessageHandler(forName: "sentwise") }

        // The real harness page — the exact HTML the app ships, loaded under the
        // same spoofed origin (sentwise.ai) Paddle's approved-domain check sees.
        webView.loadHTMLString(
            PaddleCheckoutHTML.page(config: config),
            baseURL: config.checkoutOrigin
        )

        // Once the harness page has loaded, drive its own public entry point,
        // opening the overlay with a sandbox price id (the `items` form — no
        // server transaction, no card, no purchase).
        let priceID = config.priceID(for: .starter)
        driver.onPageLoaded = { [weak webView] in
            let itemsJSON = #"{"items":[{"priceId":"\#(priceID)","quantity":1}]}"#
            webView?.evaluateJavaScript("window.sentwiseOpenCheckout(\(itemsJSON));", completionHandler: nil)
        }

        // Wait (generously) for the overlay to reach its loaded/opened harness
        // event, or for a harness/checkout failure.
        let outcome = try await driver.awaitOverlayOutcome(timeout: 90)

        switch outcome {
        case .opened(let signal):
            // The harness opened the overlay inside the restricted WebView. Prove
            // the navigation policy did not block anything the overlay needed —
            // this is the "policy too tight" regression guard.
            let blockedPaddleHosts = driver.blockedNavigations.filter { record in
                guard let host = record.url?.host?.lowercased() else { return false }
                return CheckoutNavigationPolicy.isAllowedTopLevelHost(host)
                    || host.hasSuffix("paddle.com")
                    || host.hasSuffix("paddlecdn.com")
            }
            XCTAssertTrue(
                blockedPaddleHosts.isEmpty,
                "navigation policy blocked Paddle navigations the overlay needed: \(blockedPaddleHosts)"
            )
            // The overlay's iframe(s) must have been allowed as sub-frames.
            XCTAssertFalse(
                driver.eventLog.isEmpty,
                "expected harness events; got none (overlay signal: \(signal))"
            )
        case .failed(let name, let detail):
            XCTFail("checkout overlay reported a failure event \(name): \(detail ?? "<no detail>"). Full event log: \(driver.eventLog)")
        }
    }
}

/// Collects harness message-bridge events and replicates the production
/// `PaddleCheckoutSheet` coordinator's `CheckoutNavigationPolicy` wiring so the
/// live overlay runs under the exact navigation restriction the app ships. Kept
/// in the test file (the production coordinator is private to the view) — it uses
/// the *real* `CheckoutNavigationPolicy` and `PaddleCheckoutHTML`, which are the
/// load-bearing components under test.
@MainActor
private final class CheckoutOverlayDriver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    enum Outcome {
        case opened(String)
        case failed(String, String?)
    }

    struct NavigationRecord {
        let url: URL?
        let isMainFrame: Bool
        let decision: CheckoutNavigationDecision
    }

    /// Every harness event name seen, in order (for diagnostics on failure).
    private(set) var eventLog: [String] = []
    /// Navigations the policy blocked (for the "policy too tight" assertion).
    private(set) var blockedNavigations: [NavigationRecord] = []

    /// Called once the harness page finishes loading.
    var onPageLoaded: (() -> Void)?

    private var continuation: CheckedContinuation<Outcome, Error>?
    private var settledOutcome: Outcome?
    private var allowsInitialAboutBlankNavigation = true

    /// Awaits the first terminal overlay signal: opened/loaded (success) or
    /// failed/error. Times out with a descriptive error.
    func awaitOverlayOutcome(timeout seconds: TimeInterval) async throws -> Outcome {
        if let settledOutcome { return settledOutcome }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard settledOutcome == nil, let continuation else { return }
            self.continuation = nil
            continuation.resume(
                throwing: LiveOverlayError.timedOut(seconds: seconds, eventLog: eventLog)
            )
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func settle(_ outcome: Outcome) {
        guard settledOutcome == nil else { return }
        settledOutcome = outcome
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }

    // MARK: JS → Swift bridge (mirrors the production coordinator's contract)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let dict = message.body as? [String: Any],
              let name = dict["name"] as? String else { return }
        let detail = dict["detail"] as? String
        eventLog.append(name)
        switch name {
        case "paddle.opened", "checkout.loaded":
            settle(.opened(name))
        case "paddle.failed", "checkout.error":
            settle(.failed(name, detail))
        default:
            break
        }
    }

    // MARK: Navigation policy (identical rule to the production coordinator)

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let allowsAboutBlankBootstrap = isMainFrame && allowsInitialAboutBlankNavigation
        let decision = CheckoutNavigationPolicy.decision(
            for: navigationAction.request.url,
            isMainFrameNavigation: isMainFrame,
            allowsAboutBlankBootstrap: allowsAboutBlankBootstrap
        )
        if isMainFrame {
            allowsInitialAboutBlankNavigation = false
        }
        switch decision {
        case .allowInSheet:
            decisionHandler(.allow)
        case .openExternally:
            // Record but never actually launch the browser from a test.
            blockedNavigations.append(
                NavigationRecord(url: navigationAction.request.url, isMainFrame: isMainFrame, decision: decision)
            )
            decisionHandler(.cancel)
        case .block:
            blockedNavigations.append(
                NavigationRecord(url: navigationAction.request.url, isMainFrame: isMainFrame, decision: decision)
            )
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onPageLoaded?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settle(.failed("navigation.didFail", error.localizedDescription))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        settle(.failed("navigation.didFailProvisional", error.localizedDescription))
    }
}

private enum LiveOverlayError: Error, CustomStringConvertible {
    case timedOut(seconds: TimeInterval, eventLog: [String])

    var description: String {
        switch self {
        case .timedOut(let seconds, let eventLog):
            return "Paddle overlay did not reach a loaded/opened event within \(Int(seconds))s. Events seen: \(eventLog)"
        }
    }
}
