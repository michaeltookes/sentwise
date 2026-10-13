import Foundation
import NIOCore
import NIOIMAP

/// How a mailbox session authenticates (item 104).
///
/// - `password`: IMAP `LOGIN` / SMTP `AUTH LOGIN` with an app password — the
///   fallback path, and the only path for non-Gmail providers.
/// - `xoauth2`: Google's SASL `XOAUTH2` mechanism with a short-lived OAuth access
///   token (`https://mail.google.com/` scope) — the "Sign in with Google" path.
public enum MailAuthentication: Equatable, Sendable {
    case password(String)
    case xoauth2(accessToken: String)
}

/// Google's SASL `XOAUTH2` initial client response, shared by IMAP and SMTP.
///
/// Format (before base64): `user=<email>^Aauth=Bearer <token>^A^A`, where `^A`
/// is the `0x01` control character. See
/// https://developers.google.com/gmail/imap/xoauth2-protocol
public enum XOAuth2 {
    /// The SASL mechanism name.
    public static let mechanism = "XOAUTH2"

    /// The raw (not yet base64-encoded) initial client response.
    public static func initialResponse(email: String, accessToken: String) -> String {
        "user=\(email)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
    }

    /// The base64-encoded initial client response, as sent on the wire by SMTP
    /// (`AUTH XOAUTH2 <this>`) and IMAP (`AUTHENTICATE XOAUTH2 <this>`).
    public static func encodedInitialResponse(email: String, accessToken: String) -> String {
        Data(initialResponse(email: email, accessToken: accessToken).utf8).base64EncodedString()
    }
}

/// Builds the IMAP authentication command for a session and answers the
/// server's XOAUTH2 error challenge.
enum IMAPAuthentication {
    /// `LOGIN` for an app password; `AUTHENTICATE XOAUTH2 <initial-response>`
    /// (SASL-IR, one round trip) for an OAuth access token.
    static func command(email: String, authentication: MailAuthentication) -> Command {
        switch authentication {
        case .password(let password):
            return .login(username: email, password: password)
        case .xoauth2(let accessToken):
            let raw = XOAuth2.initialResponse(email: email, accessToken: accessToken)
            return .authenticate(
                mechanism: AuthenticationMechanism(XOAuth2.mechanism),
                initialResponse: InitialResponse(ByteBuffer(string: raw))
            )
        }
    }

    /// When an XOAUTH2 token is rejected, Gmail first sends a `+ <base64 JSON>`
    /// challenge describing the error and waits for the client before sending
    /// the tagged `NO`. Replying with an empty response elicits that `NO`, which
    /// the handler then reports as `MailError.authenticationFailed`.
    static func answerChallenge(context: ChannelHandlerContext) {
        let empty = context.channel.allocator.buffer(capacity: 0)
        context.writeAndFlush(
            NIOAny(IMAPClientHandler.Message.part(.continuationResponse(empty))),
            promise: nil
        )
    }
}
