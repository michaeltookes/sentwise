import SwiftUI
import WebKit

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
                PaddleCheckoutRunner(
                    plan: plan,
                    clerkUserID: appState.managedClerkUserID,
                    email: appState.managedAccountDisplayEmail
                )
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

/// Drives one checkout attempt: owns the `PaddleCheckoutModel`, hosts the web
/// view, and reacts to phase changes (complete → refresh account + dismiss;
/// close → dismiss; failed → error panel). Split out so the model is created
/// exactly once via `@StateObject`.
private struct PaddleCheckoutRunner: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var model: PaddleCheckoutModel
    let plan: PaddlePlan

    init(plan: PaddlePlan, clerkUserID: String?, email: String?) {
        self.plan = plan
        _model = StateObject(wrappedValue: PaddleCheckoutModel(
            plan: plan,
            clerkUserID: clerkUserID,
            email: email
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            // Guard against opening an unattributable checkout (no Clerk account).
            if !model.canOpenCheckout { model.failToPrepare() }
        }
        .onChange(of: model.phase) { _, newPhase in
            switch newPhase {
            case .completed:
                Task { await appState.completeBillingCheckout() }
            case .closed:
                appState.billingCheckout = nil
            case .initializing, .presenting, .failed:
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
        case .initializing, .presenting, .completed, .closed:
            ZStack {
                PaddleCheckoutWebView(model: model)
                    .accessibilityIdentifier("paddleCheckoutWebView")
                if model.phase == .initializing {
                    ProgressView("Loading secure checkout…")
                        .padding()
                        .accessibilityIdentifier("paddleCheckoutLoading")
                }
            }
        }
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

/// Hosts the Paddle.js overlay checkout in a `WKWebView` (backlog item 56c).
/// Loads the bundled harness page, opens the checkout once the page finishes
/// loading, and forwards Paddle's events back into the model over the
/// `sentwise` message handler.
private struct PaddleCheckoutWebView: NSViewRepresentable {
    let model: PaddleCheckoutModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "sentwise")
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(
            PaddleCheckoutHTML.page(config: model.config),
            baseURL: model.config.checkoutOrigin
        )
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "sentwise")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let model: PaddleCheckoutModel

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
            let event = PaddleBridgeEvent.make(name: name, detail: detail)
            MainActor.assumeIsolated { model.handle(event) }
        }

        // MARK: Navigation → open the checkout once loaded

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                guard let request = model.makeCheckoutRequest(),
                      let json = try? request.makeArgumentJSONString() else {
                    model.failToPrepare()
                    return
                }
                webView.evaluateJavaScript("window.sentwiseOpenCheckout(\(json));", completionHandler: nil)
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
