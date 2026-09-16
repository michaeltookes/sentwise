import SentwiseMail
import Foundation

extension AppState {
    static func isMessage(
        _ message: MailMessage,
        afterBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff?,
        onOrAfterBaselineStart startDate: Date?
    ) -> Bool {
        guard let baselineUID else {
            return isMessage(message, onOrAfterBaselineStart: startDate)
        }
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else {
            return isMessage(message, onOrAfterBaselineStart: startDate)
        }
        return isMessage(message, afterBaselineUID: baselineUID)
    }

    static func isBaselineUIDComparable(
        messages: [MailMessage],
        baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard let baselineUIDValidity = baselineUID.uidValidity else { return true }
        return !messages.contains {
            guard let messageUIDValidity = $0.uidValidity else { return false }
            return messageUIDValidity != baselineUIDValidity
        }
    }

    static func isMessage(
        _ message: MailMessage,
        afterBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else { return true }
        return message.id > baselineUID.uid
    }

    static func isMessage(
        _ message: MailMessage,
        atOrBeforeBaselineUID baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard isMessageUIDComparable(message, baselineUID: baselineUID) else { return false }
        return message.id <= baselineUID.uid
    }

    static func isMessageUIDComparable(
        _ message: MailMessage,
        baselineUID: ProcessedMessages.BaselineUIDCutoff
    ) -> Bool {
        guard let baselineUIDValidity = baselineUID.uidValidity,
              let messageUIDValidity = message.uidValidity else {
            return true
        }
        return messageUIDValidity == baselineUIDValidity
    }

    static func isMessage(_ message: MailMessage, onOrAfterBaselineStart startDate: Date?) -> Bool {
        guard let startDate else { return true }
        if let date = parsedMessageDate(message.date) {
            return date >= startDate
        }
        return true
    }

    static func isMessage(_ message: MailMessage, onOrAfterInitialBaselineStart startDate: Date) -> Bool {
        guard let date = parsedMessageDate(message.date) else { return false }
        return date >= startDate
    }

    static func isMessage(_ message: MailMessage, beforeBaselineStart startDate: Date) -> Bool {
        guard let date = parsedMessageDate(message.date) else { return false }
        return date < startDate
    }

    static func parsedMessageDate(_ value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for candidate in rfc5322DateCandidates(value) {
            for format in [
                "EEE, d MMM yyyy HH:mm:ss Z",
                "d MMM yyyy HH:mm:ss Z",
                "EEE, d MMM yyyy HH:mm Z",
                "d MMM yyyy HH:mm Z"
            ] {
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) {
                    return date
                }
            }
        }
        return nil
    }

    static func rfc5322DateCandidates(_ value: String) -> [String] {
        let withoutComments = strippedRFC5322Comments(from: value)
        guard withoutComments != value else { return [value] }
        return [value, withoutComments]
    }

    static func strippedRFC5322Comments(from value: String) -> String {
        var output = ""
        var commentDepth = 0
        var isEscapingCommentCharacter = false

        for character in value {
            if commentDepth > 0 {
                if isEscapingCommentCharacter {
                    isEscapingCommentCharacter = false
                } else if character == "\\" {
                    isEscapingCommentCharacter = true
                } else if character == "(" {
                    commentDepth += 1
                } else if character == ")" {
                    commentDepth -= 1
                }
                continue
            }

            if character == "(" {
                commentDepth = 1
            } else {
                output.append(character)
            }
        }

        return output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
