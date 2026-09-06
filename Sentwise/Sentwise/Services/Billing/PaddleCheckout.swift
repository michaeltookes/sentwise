import Foundation

/// The argument object handed to `Paddle.Checkout.open(...)` (backlog item 56c).
/// Encodes to exactly the JSON the Paddle.js overlay expects:
///
/// ```json
/// { "items": [{"priceId": "...", "quantity": 1}],
///   "customData": {"clerkUserId": "..."},
///   "customer": {"email": "..."} }
/// ```
///
/// `customData.clerkUserId` is how the `sentwise-service` webhook maps the Paddle
/// customer back to the Clerk account, so it is required to open a checkout; the
/// customer email is a best-effort prefill and is omitted when unknown.
struct PaddleCheckoutRequest: Equatable, Sendable {
    let priceID: String
    let quantity: Int
    /// The signed-in Clerk user id (bare id, e.g. `user_123`), threaded into
    /// `customData.clerkUserId`. Required — the webhook needs it to attribute the
    /// purchase to the right account.
    let clerkUserID: String
    /// Prefill email; omitted from the payload when nil/empty.
    let email: String?

    init(priceID: String, clerkUserID: String, email: String? = nil, quantity: Int = 1) {
        self.priceID = priceID
        self.clerkUserID = clerkUserID
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = (trimmed?.isEmpty == false) ? trimmed : nil
        self.quantity = quantity
    }

    /// The `Paddle.Checkout.open(...)` argument object as JSON. Keys are sorted so
    /// tests can assert the serialized shape deterministically.
    func makeArgumentJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(request: self))
    }

    func makeArgumentJSONString() throws -> String {
        String(decoding: try makeArgumentJSON(), as: UTF8.self)
    }

    private struct Payload: Encodable {
        let items: [Item]
        let customData: CustomData
        let customer: Customer?

        init(request: PaddleCheckoutRequest) {
            items = [Item(priceId: request.priceID, quantity: request.quantity)]
            customData = CustomData(clerkUserId: request.clerkUserID)
            customer = request.email.map(Customer.init(email:))
        }

        struct Item: Encodable {
            let priceId: String
            let quantity: Int
        }

        struct CustomData: Encodable {
            let clerkUserId: String
        }

        struct Customer: Encodable {
            let email: String
        }
    }
}

/// An event surfaced from the Paddle.js overlay back to Swift over the WKWebView
/// message bridge (backlog item 56c). The HTML harness forwards Paddle's own
/// `eventCallback` events by `name`, plus two harness-level signals
/// (`paddle.ready` when init + open succeeds, `paddle.failed` when the script or
/// initialization fails to load).
enum PaddleBridgeEvent: Equatable, Sendable {
    /// Paddle initialized and the checkout overlay opened.
    case ready
    /// The transaction completed successfully (`checkout.completed`).
    case completed
    /// The overlay was dismissed by the user without completing (`checkout.closed`).
    case closed
    /// A checkout or harness error, carrying a user-safe message.
    case failed(String)
    /// An event we don't act on (e.g. `checkout.warning`, `checkout.loaded`).
    case ignored(String)

    /// Maps a raw JS event name (+ optional detail) to a bridge event.
    static func make(name: String, detail: String? = nil) -> PaddleBridgeEvent {
        switch name {
        case "paddle.ready", "checkout.loaded":
            return .ready
        case "checkout.completed":
            return .completed
        case "checkout.closed":
            return .closed
        case "paddle.failed", "checkout.error":
            return .failed(detail?.isEmpty == false
                ? detail!
                : "Checkout couldn't be completed. Please try again.")
        default:
            return .ignored(name)
        }
    }
}
