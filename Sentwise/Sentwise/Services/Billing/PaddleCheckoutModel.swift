import Foundation

/// Drives one Paddle overlay-checkout session (backlog item 56c). Pure, UI- and
/// WebKit-agnostic routing logic so it is unit-testable against a mocked bridge:
/// it resolves the price id for the chosen tier, builds the
/// `Paddle.Checkout.open(...)` argument, and folds incoming `PaddleBridgeEvent`s
/// into an observable `Phase`. The SwiftUI sheet owns the WKWebView and forwards
/// bridge events into `handle(_:)`; on `.completed` the sheet refreshes the
/// account so the webhook-written subscription is reflected.
@MainActor
final class PaddleCheckoutModel: ObservableObject {

    /// Lifecycle of a single checkout attempt.
    enum Phase: Equatable {
        /// The web view is loading and Paddle.js is initializing.
        case initializing
        /// The overlay is open and awaiting the user.
        case presenting
        /// The transaction completed successfully.
        case completed
        /// The user dismissed the overlay without completing.
        case closed
        /// Loading, initialization, or checkout failed.
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .completed, .closed, .failed: return true
            case .initializing, .presenting: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .initializing

    let config: PaddleConfig
    let plan: PaddlePlan
    let clerkUserID: String?
    let email: String?

    init(config: PaddleConfig = .active, plan: PaddlePlan, clerkUserID: String?, email: String?) {
        self.config = config
        self.plan = plan
        self.clerkUserID = clerkUserID
        self.email = email
    }

    /// The Paddle price id for the chosen tier.
    var priceID: String { config.priceID(for: plan) }

    /// Whether the model has enough to open a checkout. A missing/blank Clerk user
    /// id means the webhook could not attribute the purchase, so we refuse rather
    /// than open an unattributable checkout.
    var canOpenCheckout: Bool { resolvedClerkUserID != nil }

    /// The bare, non-empty Clerk user id, or nil when unusable.
    var resolvedClerkUserID: String? {
        let trimmed = clerkUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Builds the `Paddle.Checkout.open(...)` argument for this session, or nil
    /// when the checkout cannot be attributed (no Clerk user id).
    func makeCheckoutRequest() -> PaddleCheckoutRequest? {
        guard let clerkUserID = resolvedClerkUserID else { return nil }
        return PaddleCheckoutRequest(priceID: priceID, clerkUserID: clerkUserID, email: email)
    }

    /// Marks the model failed because the checkout could not be prepared (e.g. no
    /// signed-in Clerk account). Idempotent once terminal.
    func failToPrepare(_ message: String = "Sign in to Sentwise AI before subscribing.") {
        transition(to: .failed(message))
    }

    /// Folds a bridge event into the phase. `.completed` wins over a subsequent
    /// `.closed` (Paddle emits `checkout.closed` after `checkout.completed`), and
    /// no event overrides a terminal failure except a completion.
    func handle(_ event: PaddleBridgeEvent) {
        switch event {
        case .ready:
            // Only advance from initializing; never resurrect a terminal phase.
            if phase == .initializing { transition(to: .presenting) }
        case .completed:
            transition(to: .completed, force: true)
        case .closed:
            // A close after completion is Paddle's own teardown — ignore it.
            guard phase != .completed else { return }
            transition(to: .closed)
        case .failed(let message):
            guard phase != .completed else { return }
            transition(to: .failed(message))
        case .ignored:
            break
        }
    }

    // MARK: - Private

    private func transition(to newPhase: Phase, force: Bool = false) {
        if !force, phase.isTerminal { return }
        phase = newPhase
    }
}
