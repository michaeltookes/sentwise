import Foundation

/// Policy for a bounded exponential-backoff retry loop (item 27).
///
/// `maxAttempts` counts the *total* tries including the first, so `maxAttempts:
/// 1` disables retrying. Delays grow as `baseDelay * 2^(retryIndex)` capped at
/// `maxDelay`, then have equal jitter applied so a fleet of clients doesn't
/// retry in lockstep.
struct RetryPolicy: Equatable {
    /// Total attempts including the first (must be >= 1).
    var maxAttempts: Int
    /// The first backoff delay, in nanoseconds, doubled each subsequent retry.
    var baseDelayNanoseconds: UInt64
    /// The ceiling for any single backoff delay, in nanoseconds.
    var maxDelayNanoseconds: UInt64
    /// The fraction (0...1) of a computed delay spread as +/- jitter around it.
    var jitterFraction: Double

    init(
        maxAttempts: Int,
        baseDelayNanoseconds: UInt64,
        maxDelayNanoseconds: UInt64,
        jitterFraction: Double = 0.5
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maxDelayNanoseconds = max(baseDelayNanoseconds, maxDelayNanoseconds)
        self.jitterFraction = min(max(jitterFraction, 0), 1)
    }

    /// The default resilience policy: four attempts, 1s base, 30s ceiling. Used
    /// for send/save/fetch and LLM draft generation.
    static let `default` = RetryPolicy(
        maxAttempts: 4,
        baseDelayNanoseconds: 1_000_000_000,
        maxDelayNanoseconds: 30_000_000_000
    )
}

/// Whether a thrown error should be retried or is terminal. The caller supplies
/// the classification so the runner stays domain-agnostic.
enum RetryDecision: Equatable {
    /// The error is transient; try again (subject to the attempt budget).
    case retry
    /// The error is transient, but the retry loop should wait for this explicit
    /// delay instead of its generic backoff schedule.
    case retryAfter(UInt64)
    /// The error is terminal; stop and rethrow it now.
    case stop
}

/// A small, self-contained exponential-backoff retry driver (item 27). One
/// runner is shared for every resilient operation rather than sprinkling ad-hoc
/// loops. Time and randomness are injected so tests drive backoff deterministically
/// without real waits (mirrors the item 23 `sendCountdownTickNanoseconds` seam).
struct RetryRunner {
    var policy: RetryPolicy
    /// Sleeps for the given nanoseconds. Throws on cancellation. Overridable so
    /// tests advance backoff instantly.
    var sleep: @Sendable (UInt64) async throws -> Void
    /// Returns a value in 0...1 used to place jitter within a delay's spread.
    /// Overridable so tests get deterministic delays.
    var randomUnitInterval: @Sendable () -> Double

    init(
        policy: RetryPolicy = .default,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        randomUnitInterval: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.policy = policy
        self.sleep = sleep
        self.randomUnitInterval = randomUnitInterval
    }

    /// Runs `operation`, retrying while `classify` returns `.retry` and the
    /// attempt budget allows, sleeping with backoff between tries. Rethrows the
    /// last error once retries are exhausted or `classify` returns `.stop`.
    /// `CancellationError` is never retried.
    func run<T>(
        classify: (Error) -> RetryDecision,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                let isLastAttempt = attempt >= policy.maxAttempts
                let decision = classify(error)
                if isLastAttempt || decision == .stop {
                    throw error
                }
                try Task.checkCancellation()
                try await sleep(delayNanoseconds(for: decision, retryIndex: attempt - 1))
            }
        }
    }

    /// The jittered backoff delay for a given zero-based retry index.
    func backoffNanoseconds(forRetryIndex retryIndex: Int) -> UInt64 {
        let base = Double(policy.baseDelayNanoseconds)
        let uncapped = base * pow(2, Double(retryIndex))
        let capped = min(uncapped, Double(policy.maxDelayNanoseconds))
        let spread = capped * policy.jitterFraction
        // Equal jitter: center the delay and offset by up to +/- spread/2.
        let jittered = capped - spread / 2 + randomUnitInterval() * spread
        return UInt64(max(0, jittered))
    }

    private func delayNanoseconds(for decision: RetryDecision, retryIndex: Int) -> UInt64 {
        switch decision {
        case .retry:
            return backoffNanoseconds(forRetryIndex: retryIndex)
        case .retryAfter(let nanoseconds):
            return nanoseconds
        case .stop:
            return 0
        }
    }
}
