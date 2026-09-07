import Foundation

/// Drives one Paddle overlay-checkout session (backlog item 56c). Pure, UI- and
/// WebKit-agnostic routing logic so it is unit-testable against a mocked worker
/// and bridge.
///
/// The flow is now **async and server-minted**: when the sheet appears the model
/// calls the injected `createTransaction` closure, which hits the authenticated
/// `POST /v1/paddle/checkout` endpoint and returns a Paddle transaction id. The
/// Worker binds the signed-in account to that transaction with a signed
/// `custom_data` the Paddle webhook trusts, so the app opens the overlay with the
/// transaction id alone — never with raw `items` / `customData` / `customer`,
/// whose unsigned binding the webhook refuses to attribute (the bug this fixes).
///
/// Because the transaction fetch and the harness page load race, the model tracks
/// both signals and publishes `openArgumentJSON` only once **both** the
/// transaction is minted and the page has finished loading; the SwiftUI sheet
/// opens the overlay when that becomes non-nil. Incoming `PaddleBridgeEvent`s are
/// folded into an observable `Phase`; on `.completed` the sheet reconciles the
/// account so the webhook-written subscription is reflected.
@MainActor
final class PaddleCheckoutModel: ObservableObject {

    /// Lifecycle of a single checkout attempt.
    enum Phase: Equatable {
        /// The sheet is up; the harness page is loading and no work has started.
        case initializing
        /// The server-side transaction is being minted (`POST /v1/paddle/checkout`).
        case preparing
        /// The overlay is open and awaiting the user.
        case presenting
        /// The transaction completed successfully.
        case completed
        /// The user dismissed the overlay without completing.
        case closed
        /// Preparing, loading, initialization, or checkout failed.
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .completed, .closed, .failed: return true
            case .initializing, .preparing, .presenting: return false
            }
        }

        /// Whether the overlay has not yet been opened (still preparing/loading).
        var isPreOpen: Bool {
            switch self {
            case .initializing, .preparing: return true
            case .presenting, .completed, .closed, .failed: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .initializing

    /// The `Paddle.Checkout.open(...)` argument JSON (`{ "transactionId": … }`),
    /// published once the transaction is minted **and** the harness page has
    /// loaded. The web view opens the overlay when this becomes non-nil.
    @Published private(set) var openArgumentJSON: String?

    let config: PaddleConfig
    let plan: PaddlePlan

    /// Mints a server-side transaction id for a price id (item 56c). Injected so
    /// the model is testable without a live Worker. `nil` means checkout cannot be
    /// prepared (no managed provider wired in), so the model fails to prepare.
    private let createTransaction: (@Sendable (String) async throws -> PaddleCheckoutTransaction)?

    private var pageLoaded = false
    private var mintedTransactionID: String?
    private var didStartPreparing = false

    init(
        config: PaddleConfig = .active,
        plan: PaddlePlan,
        createTransaction: (@Sendable (String) async throws -> PaddleCheckoutTransaction)? = nil
    ) {
        self.config = config
        self.plan = plan
        self.createTransaction = createTransaction
    }

    /// The Paddle price id for the chosen tier — sent to the Worker to mint the
    /// transaction (the Worker maps it back to a plan and rejects unknown ids).
    var priceID: String { config.priceID(for: plan) }

    /// Whether the model can attempt a checkout. False only when no transaction
    /// source was injected (no managed provider), in which case `prepare()` fails.
    var canOpenCheckout: Bool { createTransaction != nil }

    /// Mints the server-side transaction (item 56c). Call once when the sheet
    /// appears; idempotent. On success stores the transaction id and opens as soon
    /// as the page is also ready; on failure transitions to `.failed` with a
    /// friendly, billing-only message derived from the endpoint error.
    func prepare() async {
        guard !didStartPreparing else { return }
        didStartPreparing = true
        guard let createTransaction else {
            failToPrepare()
            return
        }
        transition(to: .preparing)
        do {
            let transaction = try await createTransaction(priceID)
            let id = transaction.transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                failToPrepare()
                return
            }
            mintedTransactionID = id
            openWhenReady()
        } catch {
            transition(to: .failed(Self.friendlyMessage(for: error)))
        }
    }

    /// The harness page finished loading — `window.sentwiseOpenCheckout` now
    /// exists, so the overlay can be opened as soon as the transaction is minted.
    func pageDidLoad() {
        pageLoaded = true
        openWhenReady()
    }

    /// Publishes the overlay-open argument once both the transaction is minted and
    /// the page is loaded. No-ops once opened or terminal.
    private func openWhenReady() {
        guard phase.isPreOpen, openArgumentJSON == nil,
              pageLoaded, let id = mintedTransactionID else { return }
        guard let json = try? PaddleCheckoutRequest(transactionID: id).makeArgumentJSONString() else {
            failToPrepare()
            return
        }
        openArgumentJSON = json
    }

    /// Marks the model failed because the checkout could not be prepared or
    /// opened. Idempotent once terminal. Billing-only copy — no privacy claims.
    func failToPrepare(_ message: String = "We couldn't start checkout. Please try again.") {
        transition(to: .failed(message))
    }

    /// Folds a bridge event into the phase. `.ready` (the overlay actually opened)
    /// advances a pre-open phase to `.presenting`. `.completed` wins over a
    /// subsequent `.closed` (Paddle emits `checkout.closed` after
    /// `checkout.completed`), and no event overrides a terminal failure except a
    /// completion.
    func handle(_ event: PaddleBridgeEvent) {
        switch event {
        case .ready:
            // Only advance while still pre-open; never resurrect a terminal phase.
            if phase.isPreOpen { transition(to: .presenting) }
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

    /// Maps an endpoint error into a friendly, billing-only failure message. The
    /// Worker's own messages are already user-safe, so they are surfaced directly;
    /// only auth/transport shapes get local copy.
    static func friendlyMessage(for error: Error) -> String {
        switch error {
        case LLMError.managedNotSignedIn:
            return "Sign in to Sentwise AI before subscribing."
        case LLMError.managedCheckoutFailed(let message):
            return message
        case LLMError.http(_, let message):
            return message
        case LLMError.transport:
            return "We couldn't reach checkout. Check your connection and try again."
        default:
            return "We couldn't start checkout. Please try again."
        }
    }

    // MARK: - Private

    private func transition(to newPhase: Phase, force: Bool = false) {
        if !force, phase.isTerminal { return }
        phase = newPhase
    }
}
