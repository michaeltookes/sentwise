import XCTest
@testable import Sentwise

/// Unit tests for the bounded exponential-backoff retry driver (item 27). Time
/// and randomness are injected so backoff is exercised without real waits.
final class RetryRunnerTests: XCTestCase {

    private struct TransientError: Error {}
    private struct PermanentError: Error {}

    private func runner(
        maxAttempts: Int,
        base: UInt64 = 1_000,
        max: UInt64 = 100_000,
        jitter: Double = 0.5,
        randomUnitInterval: @escaping @Sendable () -> Double = { 0.5 },
        recordedSleeps: (@Sendable (UInt64) -> Void)? = nil
    ) -> RetryRunner {
        RetryRunner(
            policy: RetryPolicy(
                maxAttempts: maxAttempts,
                baseDelayNanoseconds: base,
                maxDelayNanoseconds: max,
                jitterFraction: jitter
            ),
            sleep: { nanos in recordedSleeps?(nanos) },
            randomUnitInterval: randomUnitInterval
        )
    }

    // MARK: - Attempt counting

    func testSucceedsOnFirstTryWithoutRetrying() async throws {
        var attempts = 0
        let value = try await runner(maxAttempts: 4).run(
            classify: { _ in .retry },
            operation: {
                attempts += 1
                return 42
            }
        )
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 1)
    }

    func testRetriesTransientThenSucceeds() async throws {
        var attempts = 0
        let value = try await runner(maxAttempts: 4).run(
            classify: { _ in .retry },
            operation: { () throws -> String in
                attempts += 1
                if attempts < 3 { throw TransientError() }
                return "ok"
            }
        )
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(attempts, 3)
    }

    func testExhaustsAfterMaxAttemptsAndRethrows() async {
        var attempts = 0
        do {
            _ = try await runner(maxAttempts: 3).run(
                classify: { _ in .retry },
                operation: { () throws -> Int in
                    attempts += 1
                    throw TransientError()
                }
            )
            XCTFail("expected the final error to rethrow")
        } catch {
            XCTAssertTrue(error is TransientError)
        }
        XCTAssertEqual(attempts, 3, "should try exactly maxAttempts times")
    }

    func testStopDecisionShortCircuitsWithoutRetrying() async {
        var attempts = 0
        do {
            _ = try await runner(maxAttempts: 5).run(
                classify: { _ in .stop },
                operation: { () throws -> Int in
                    attempts += 1
                    throw PermanentError()
                }
            )
            XCTFail("expected an immediate rethrow")
        } catch {
            XCTAssertTrue(error is PermanentError)
        }
        XCTAssertEqual(attempts, 1, "a .stop error must not be retried")
    }

    func testCancellationErrorIsNeverRetried() async {
        var attempts = 0
        do {
            _ = try await runner(maxAttempts: 5).run(
                classify: { _ in .retry },
                operation: { () throws -> Int in
                    attempts += 1
                    throw CancellationError()
                }
            )
            XCTFail("expected CancellationError to rethrow")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - Backoff schedule

    func testBackoffDoublesAndCapsAtMax() {
        let runner = runner(maxAttempts: 10, base: 1_000, max: 5_000, jitter: 0)
        // With zero jitter the delay is exactly the capped exponential value.
        XCTAssertEqual(runner.backoffNanoseconds(forRetryIndex: 0), 1_000)
        XCTAssertEqual(runner.backoffNanoseconds(forRetryIndex: 1), 2_000)
        XCTAssertEqual(runner.backoffNanoseconds(forRetryIndex: 2), 4_000)
        XCTAssertEqual(runner.backoffNanoseconds(forRetryIndex: 3), 5_000, "capped at max")
        XCTAssertEqual(runner.backoffNanoseconds(forRetryIndex: 9), 5_000, "still capped")
    }

    func testJitterSpreadsAroundTheComputedDelay() {
        // jitterFraction 0.5 => +/- 25% of the computed delay at the extremes.
        let low = runner(maxAttempts: 2, base: 1_000, max: 100_000, jitter: 0.5,
                         randomUnitInterval: { 0.0 }).backoffNanoseconds(forRetryIndex: 0)
        let high = runner(maxAttempts: 2, base: 1_000, max: 100_000, jitter: 0.5,
                          randomUnitInterval: { 1.0 }).backoffNanoseconds(forRetryIndex: 0)
        XCTAssertEqual(low, 750)
        XCTAssertEqual(high, 1_250)
    }

    func testSleepsBetweenRetriesWithBackoff() async {
        let sleeps = SleepRecorder()
        let runner = runner(maxAttempts: 3, base: 1_000, max: 100_000, jitter: 0,
                            recordedSleeps: { sleeps.record($0) })
        _ = try? await runner.run(
            classify: { _ in .retry },
            operation: { () throws -> Int in throw TransientError() }
        )
        // Two sleeps between three attempts: 1000, then 2000.
        XCTAssertEqual(sleeps.values, [1_000, 2_000])
    }

    func testSleepsWithExplicitRetryDelayWhenProvided() async {
        let sleeps = SleepRecorder()
        let runner = runner(maxAttempts: 2, base: 1_000, max: 100_000, jitter: 0,
                            recordedSleeps: { sleeps.record($0) })
        _ = try? await runner.run(
            classify: { _ in .retryAfter(30_000) },
            operation: { () throws -> Int in throw TransientError() }
        )
        XCTAssertEqual(sleeps.values, [30_000])
    }

    /// Thread-safe collector for the injected sleep closure.
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt64] = []
        func record(_ value: UInt64) {
            lock.lock(); storage.append(value); lock.unlock()
        }
        var values: [UInt64] {
            lock.lock(); defer { lock.unlock() }; return storage
        }
    }
}
