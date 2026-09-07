import SwiftUI
import WebKit
import os

/// The Paddle overlay-checkout sheet (backlog item 56c). When the request carries
/// a tier it goes straight to that checkout; otherwise it shows a small plan
/// picker first. The actual checkout is Paddle's own overlay, rendered by
/// Paddle.js inside a `WKWebView` (`PaddleCheckoutWebView`); this view owns the
/// surrounding chrome, the loading/error states, and the completion handoff back
/// to `AppState`.
struct PaddleCheckoutSheet: View {
    @EnvironmentObject var appState: AppState
    let request: BillingCheckoutRequest

    @State private var pickedPlan: PaddlePlan?

    private var activePlan: PaddlePlan? { request.plan ?? pickedPlan }

    var body: some View {
        VStack(spacing: 0) {
            if let plan = activePlan {
                PaddleCheckoutRunner(model: appState.makeCheckoutModel(for: plan))
            } else {
                planPicker
            }
        }
        .frame(width: 480, height: 620)
        .accessibilityIdentifier("paddleCheckoutSheet")
    }

    // MARK: - Plan picker

    private var planPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose your plan")
                    .font(.title2).bold()
                Spacer()
                Button {
                    appState.billingCheckout = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paddleCheckoutClose")
                .accessibilityLabel("Close")
            }

            Text("Pick a plan to continue to secure checkout.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(PaddlePlan.allCases) { plan in
                Button {
                    pickedPlan = plan
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.displayName)
                            .font(.headline)
                        Text(plan.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.25))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paddlePlanOption_\(plan.rawValue)")
                .accessibilityLabel("Choose the \(plan.displayName) plan")
            }

            Spacer()
        }
        .padding(24)
    }
}

/// Drives one checkout attempt (item 56c): owns the `PaddleCheckoutModel`, mints
/// the server-side transaction, hosts the web view, and reacts to phase changes
/// (complete → reconcile the account + show a success confirmation; close →
/// dismiss; failed → error panel). Split out so the model is created exactly once
/// via `@StateObject`.
private struct PaddleCheckoutRunner: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var model: PaddleCheckoutModel
    /// Post-purchase reconciliation state, so the success panel shows a spinner
    /// while `/v1/me` catches up, then confirms the tier.
    @State private var isReconciling = false

    init(model: PaddleCheckoutModel) {
        _model = StateObject(wrappedValue: model)
    }

    private var plan: PaddlePlan { model.plan }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task {
            // Mint the server-side transaction (authed POST /v1/paddle/checkout),
            // then the web view opens the overlay by transaction id.
            await model.prepare()
        }
        .onChange(of: model.phase) { _, newPhase in
            switch newPhase {
            case .completed:
                // Keep the sheet open and reconcile so the pane flips to the paid
                // tier and we can show a success confirmation before dismissal.
                isReconciling = true
                Task {
                    await appState.reconcileSubscriptionAfterCheckout()
                    isReconciling = false
                }
            case .closed:
                appState.billingCheckout = nil
            case .initializing, .preparing, .presenting, .failed:
                break
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(plan.displayName) plan")
                    .font(.headline)
                Text("Secure checkout by Paddle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appState.billingCheckout = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("paddleCheckoutClose")
            .accessibilityLabel("Close checkout")
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .failed(let message):
            errorPanel(message)
        case .completed:
            confirmationPanel
        case .initializing, .preparing, .presenting, .closed:
            ZStack {
                PaddleCheckoutWebView(model: model)
                    .accessibilityIdentifier("paddleCheckoutWebView")
                if model.phase.isPreOpen {
                    ProgressView("Preparing secure checkout…")
                        .padding()
                        .accessibilityIdentifier("paddleCheckoutLoading")
                }
            }
        }
    }

    /// Post-purchase success confirmation (item 56c). Shows a spinner while
    /// `/v1/me` catches up, then confirms the tier. Billing-only copy.
    private var confirmationPanel: some View {
        VStack(spacing: 14) {
            if isReconciling {
                ProgressView()
                    .controlSize(.large)
                Text("Completing your purchase…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("paddleCheckoutReconciling")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("You're on \(confirmedTierName) — you're all set.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paddleCheckoutSuccess")
                Button("Done") {
                    appState.billingCheckout = nil
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("paddleCheckoutSuccessDone")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// The tier to name in the success copy: the live subscription plan once the
    /// account has flipped to a paid tier, else the tier that was purchased.
    private var confirmedTierName: String {
        if appState.isOnActivePaidPlan,
           let livePlan = appState.managedAccountStatus?.subscription?.plan {
            return livePlan.displayName
        }
        return plan.displayName
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("paddleCheckoutError")
            Button("Close") {
                appState.billingCheckout = nil
            }
            .accessibilityIdentifier("paddleCheckoutErrorClose")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private let checkoutLogger = Logger(subsystem: "com.tookes.Sentwise", category: "PaddleCheckout")

/// Hosts the Paddle.js overlay checkout in a `WKWebView` (backlog item 56c).
/// Loads the bundled harness page, tells the model when the page has finished
/// loading, opens the overlay once the model publishes the server-minted
/// transaction argument, and forwards Paddle's events back into the model over
/// the `sentwise` message handler.
private struct PaddleCheckoutWebView: NSViewRepresentable {
    @ObservedObject var model: PaddleCheckoutModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "sentwise")
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        // Diagnostic (56c): allow Safari Web Inspector to attach to the checkout
        // webview in debug builds so Paddle.js errors can be read directly.
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        webView.loadHTMLString(
            PaddleCheckoutHTML.page(config: model.config),
            baseURL: model.config.checkoutOrigin
        )
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // The model publishes the `{ transactionId }` argument once the server has
        // minted the transaction AND the page has loaded. Open the overlay exactly
        // once when it appears.
        guard let json = model.openArgumentJSON, !context.coordinator.didOpen else { return }
        context.coordinator.didOpen = true
        nsView.evaluateJavaScript("window.sentwiseOpenCheckout(\(json));", completionHandler: nil)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "sentwise")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let model: PaddleCheckoutModel
        /// Guards `sentwiseOpenCheckout` to a single evaluation.
        var didOpen = false

        init(model: PaddleCheckoutModel) {
            self.model = model
        }

        // MARK: JS → Swift bridge

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let dict = message.body as? [String: Any],
                  let name = dict["name"] as? String else { return }
            let detail = dict["detail"] as? String
            // Diagnostic (56c): surface Paddle's raw event + full error payload,
            // which the generic UI message otherwise swallows. `.public` so it is
            // readable in Console/`log stream`; errors at .error, the rest at .debug.
            if name == "paddle.errorPayload" {
                checkoutLogger.error("Paddle checkout payload: \(detail ?? "<no detail>", privacy: .public)")
            } else if name == "checkout.error" || name == "paddle.failed" {
                checkoutLogger.error("Paddle checkout error: \(detail ?? "<no detail>", privacy: .public)")
            } else {
                checkoutLogger.debug("Paddle checkout event: \(name, privacy: .public)")
            }
            let event = PaddleBridgeEvent.make(name: name, detail: detail)
            MainActor.assumeIsolated { model.handle(event) }
        }

        // MARK: Navigation → tell the model the page is ready

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The harness page is loaded; `window.sentwiseOpenCheckout` now exists.
            // The model opens the overlay (via `openArgumentJSON` → `updateNSView`)
            // once the server-minted transaction is also in hand.
            MainActor.assumeIsolated {
                model.pageDidLoad()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            reportLoadFailure(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            reportLoadFailure(error)
        }

        private func reportLoadFailure(_ error: Error) {
            MainActor.assumeIsolated {
                model.handle(.failed("Couldn't load checkout. Check your connection and try again."))
            }
        }
    }
}
