import SentwiseMail
import Foundation

/// How a failed operation should be treated by the resilience layer (item 27).
enum FailureClass: Equatable {
    /// A transient network/server hiccup: safe to retry with backoff.
    case transient
    /// An SMTP send that failed *after* the message was submitted. The outcome is
    /// unknown, so it must never be auto-retried; surface it for a manual call.
    case ambiguousSend
    /// A credential/authorization failure (bad app password, invalid API key,
    /// 401/403). Never retried; surfaced with a fix-your-credentials message.
    case authentication
    /// A definitive, non-retryable failure (bad request, rejected recipient, …).
    case permanent
}

/// Central mapping from the app's error types to a `FailureClass`. Keeping the
/// policy in one place means every retry/queue decision classifies identically —
/// and, crucially, that `sendInterruptedAfterSubmission` is *always* treated as
/// non-retryable so a retry can never cause a duplicate send.
enum ResilienceClassifier {

    static func classify(_ error: Error) -> FailureClass {
        switch error {
        case let mailError as MailError:
            return classifyMail(mailError)
        case let llmError as LLMError:
            return classifyLLM(llmError)
        case is KeychainError:
            return .authentication
        case let urlError as URLError:
            return isTransientURLError(urlError) ? .transient : .permanent
        case let posixError as POSIXError:
            return isTransientPOSIXError(posixError) ? .transient : .permanent
        default:
            // Unknown errors are treated conservatively as permanent — we never
            // retry something we can't reason about, avoiding blind duplicate work.
            return .permanent
        }
    }

    /// Whether an error is transient — the only class the retry loop retries.
    static func isRetryable(_ error: Error) -> Bool {
        classify(error) == .transient
    }

    static func retryDecision(for error: Error) -> RetryDecision {
        isRetryable(error) ? .retry : .stop
    }

    // MARK: - Mail

    private static func classifyMail(_ error: MailError) -> FailureClass {
        switch error {
        case .connectionFailed:
            // Pre-DATA connection/TLS failure (SMTP) or any IMAP connect failure.
            return .transient
        case .sendInterruptedAfterSubmission:
            return .ambiguousSend
        case .authenticationFailed:
            return .authentication
        case .smtpCommandFailed(let code, _):
            return (400...499).contains(code) ? .transient : .permanent
        case .incompleteCredentials, .commandFailed, .resultTooLarge:
            return .permanent
        }
    }

    // MARK: - LLM

    private static func classifyLLM(_ error: LLMError) -> FailureClass {
        switch error {
        case .transport:
            return .transient
        case .http(let status, _):
            return classifyHTTPStatus(status)
        case .missingAPIKey, .managedNotSignedIn, .managedTrialExpired:
            return .authentication
        case .managedRateLimited:
            // Rate limiting clears on its own — retry after backoff (item 56b).
            return .transient
        case .invalidResponse, .invalidBaseURL, .managedQuotaExceeded, .managedRequestTooLarge:
            // Quota-exhausted (until the window resets) and too-large requests
            // won't succeed on retry (item 56b).
            return .permanent
        }
    }

    /// HTTP status classification shared by LLM providers: 408/429 and 5xx are
    /// transient; 401/403 are auth; other 4xx are permanent.
    private static func classifyHTTPStatus(_ status: Int) -> FailureClass {
        switch status {
        case 401, 403:
            return .authentication
        case 408, 429:
            return .transient
        case 500...599:
            return .transient
        default:
            return .permanent
        }
    }

    // MARK: - Low-level network errors

    private static func isTransientURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func isTransientPOSIXError(_ error: POSIXError) -> Bool {
        switch error.code {
        case .ECONNRESET, .ECONNREFUSED, .ETIMEDOUT, .ENETDOWN, .ENETUNREACH,
             .EHOSTDOWN, .EHOSTUNREACH, .EPIPE, .EAGAIN:
            return true
        default:
            return false
        }
    }
}
