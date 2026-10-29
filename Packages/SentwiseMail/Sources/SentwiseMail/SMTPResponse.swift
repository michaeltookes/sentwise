import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// A single SMTP reply: the 3-digit status code plus the joined text of all its
/// (possibly multi-line) response lines.
struct SMTPResponse: Equatable {
    let code: Int
    /// The text of the final line of the reply.
    let text: String
    /// The text of every line of the reply, in order (EHLO capability lines).
    let lines: [String]

    init(code: Int, text: String, lines: [String]? = nil) {
        self.code = code
        self.text = text
        self.lines = lines ?? [text]
    }

    /// Whether an EHLO reply advertises `keyword` (case-insensitive, first token).
    func advertises(_ keyword: String) -> Bool {
        lines.contains { line in
            line.split(separator: " ").first.map { $0.caseInsensitiveCompare(keyword) == .orderedSame } ?? false
        }
    }
}

/// Connection-level classification of an SMTP AUTH rejection from Exchange
/// Online / Outlook.com: `5.7.139` / "SmtpClientAuthentication is disabled" means
/// SMTP AUTH is switched off, which is not a credential failure (item 31, T31-6).
enum SMTPAuthDisabledDetector {
    static func isDisabled(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("5.7.139") || lowered.contains("smtpclientauthentication is disabled")
    }
}

/// Frames the SMTP reply stream into `SMTPResponse` values. SMTP replies are
/// CRLF-terminated lines beginning with a 3-digit code; a hyphen after the code
/// (`250-`) marks a continuation, a space (`250 `) the final line of the reply.
final class SMTPResponseDecoder: ByteToMessageDecoder {
    typealias InboundOut = SMTPResponse

    /// Set by the SMTP handler while a `STARTTLS` reply is pending. Any bytes
    /// buffered beyond that single reply were sent before the TLS handshake, so
    /// they cannot be trusted (RFC 3207 section 4.2): the decode fails instead.
    var rejectTrailingData = false

    private var pendingCode: Int?
    private var pendingLines: [String] = []

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            return .needMoreData
        }
        let lineLength = newlineIndex - buffer.readerIndex + 1
        guard var line = buffer.readString(length: lineLength) else { return .needMoreData }
        // "\r\n" is a single Character in Swift, so strip by unicode scalars, not Characters.
        line = line.trimmingCharacters(in: .newlines)

        guard line.count >= 3, let code = Int(line.prefix(3)) else {
            throw MailError.commandFailed("Malformed SMTP reply: \(line)")
        }
        // A space (or bare 3-char line) ends the reply; a hyphen continues it.
        let isFinal = line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] != "-"
        pendingCode = code
        let text = line.count > 4 ? String(line.dropFirst(4)) : ""
        pendingLines.append(text)

        if isFinal {
            if rejectTrailingData, buffer.readableBytes > 0 {
                throw MailError.starttlsFailed("The server sent data after the STARTTLS reply, before TLS.")
            }
            context.fireChannelRead(wrapInboundOut(SMTPResponse(code: code, text: text, lines: pendingLines)))
            pendingCode = nil
            pendingLines = []
        }
        return .continue
    }

    func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}
