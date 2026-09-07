import Foundation

/// The argument object handed to `Paddle.Checkout.open(...)` (backlog item 56c).
/// Encodes to exactly the JSON the Paddle.js overlay expects for a server-minted
/// transaction:
///
/// ```json
/// { "transactionId": "txn_..." }
/// ```
///
/// The transaction is minted server-side by the authenticated
/// `POST /v1/paddle/checkout` endpoint, which binds the signed-in Clerk account
/// to it via a **signed** `custom_data` the Paddle webhook trusts. That is why
/// the app opens by transaction id alone and no longer passes raw
/// `items` / `customData` / `customer` client-side: an unsigned `customData`
/// binding is refused by the webhook for first-time Paddle customers, so a
/// client-side checkout could never attribute the purchase.
struct PaddleCheckoutRequest: Equatable, Sendable {
    /// The server-minted Paddle transaction id (e.g. `txn_...`).
    let transactionID: String

    /// The `Paddle.Checkout.open(...)` argument object as JSON. Keys are sorted so
    /// tests can assert the serialized shape deterministically.
    func makeArgumentJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(transactionId: transactionID))
    }

    func makeArgumentJSONString() throws -> String {
        let data = try makeArgumentJSON()
        guard let string = String(bytes: data, encoding: .utf8) else {
            throw LLMError.invalidResponse("Couldn't encode the checkout arguments.")
        }
        return string
    }

    private struct Payload: Encodable {
        let transactionId: String
    }
}

/// An event surfaced from the Paddle.js overlay back to Swift over the WKWebView
/// message bridge (backlog item 56c). The HTML harness forwards Paddle's own
/// `eventCallback` events by `name`, plus two harness-level signals
/// (`paddle.ready` when init + open succeeds, `paddle.failed` when the script or
/// initialization fails to load).
enum PaddleBridgeEvent: Equatable, Sendable {
    /// The checkout overlay actually opened — `paddle.opened` (posted by the
    /// harness right after `Paddle.Checkout.open(...)` succeeds) or Paddle's own
    /// `checkout.loaded`. Drives the transition to `.presenting`. Note: the
    /// harness's `paddle.ready` (fired on `Paddle.Initialize`, before any overlay
    /// is opened) is intentionally *not* mapped here — with the async
    /// transaction fetch it can fire long before the overlay opens.
    case ready
    /// The transaction completed successfully (`checkout.completed`).
    case completed
    /// The overlay was dismissed by the user without completing (`checkout.closed`).
    case closed
    /// A checkout or harness error, carrying a user-safe message.
    case failed(String)
    /// An event we don't act on (e.g. `checkout.warning`, `paddle.ready`,
    /// `paddle.debug`).
    case ignored(String)

    /// Maps a raw JS event name (+ optional detail) to a bridge event.
    static func make(name: String, detail: String? = nil) -> PaddleBridgeEvent {
        switch name {
        case "paddle.opened", "checkout.loaded":
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
