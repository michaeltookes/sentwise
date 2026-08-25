import NIOCore
import NIOEmbedded
import XCTest
@testable import SentwiseMail

/// Regression coverage for backlog item 77: the watcher's IMAP fetch (and every
/// sibling connect path) leaked an unfulfilled `EventLoopFuture` from a losing
/// Happy Eyeballs candidate, tripping NIO's debug-only `EventLoopFuture.deinit`
/// assertion and crashing Debug builds.
///
/// These tests run under `swift test`, which builds in **Debug** — so NIO's leak
/// assertions are live. A promise left unfulfilled when the tracker or its
/// promises deinit would trap here; a green run therefore proves no promise is
/// leaked. The double-completion assertions prove the atomic-claim gate never
/// lets a promise be completed twice (which would also trap).
final class ChannelPromiseTrackerTests: XCTestCase {

    private enum TestError: Error, Equatable { case cancelled, boom }

    // MARK: - failRemaining completes every un-consumed promise exactly once

    /// Mirrors the fetch path: several candidates are registered (Happy Eyeballs),
    /// only the winner is completed by its handler; the losers are never settled
    /// by a handler and would leak. `failRemaining` (the provider's `defer`) must
    /// fail every un-consumed promise so none is deallocated unfulfilled.
    func testFailRemainingCompletesEveryUnconsumedPromise() throws {
        let tracker = ChannelPromiseTracker<Int>()
        let channels = (0..<4).map { _ in EmbeddedChannel() }
        let completes = channels.map { tracker.register($0) }
        let futures = try channels.map { try XCTUnwrap(tracker.future(for: $0)) }

        // Only the "winning" candidate's handler settles.
        completes[1](.success(42))
        let winner = try futures[1].wait()
        XCTAssertEqual(winner, 42)

        // The provider's defer: fail everything still un-consumed.
        tracker.failRemaining(TestError.cancelled)

        // The winner keeps its value; every loser is failed exactly once.
        XCTAssertEqual(try futures[1].wait(), 42)
        for index in [0, 2, 3] {
            XCTAssertThrowsError(try futures[index].wait()) { error in
                XCTAssertEqual(error as? TestError, .cancelled)
            }
        }

        for channel in channels { _ = try channel.finish() }
    }

    // MARK: - No double-completion, either ordering

    /// Handler claims first, then `failRemaining` runs: the promise keeps the
    /// handler's value and `failRemaining` must not complete it again (a second
    /// completion would trap in NIO).
    func testHandlerClaimThenFailRemainingDoesNotDoubleComplete() throws {
        let tracker = ChannelPromiseTracker<Int>()
        let channel = EmbeddedChannel()
        let complete = tracker.register(channel)
        let future = try XCTUnwrap(tracker.future(for: channel))

        complete(.success(7))
        tracker.failRemaining(TestError.cancelled) // must be a no-op for this promise

        XCTAssertEqual(try future.wait(), 7)
        _ = try channel.finish()
    }

    /// `failRemaining` claims first, then the handler's (late) completion runs:
    /// the promise keeps the failure and the late `complete(_:)` call is a
    /// harmless no-op (it must not trap by completing an already-failed promise).
    func testFailRemainingThenLateHandlerCompletionIsNoOp() throws {
        let tracker = ChannelPromiseTracker<Int>()
        let channel = EmbeddedChannel()
        let complete = tracker.register(channel)
        let future = try XCTUnwrap(tracker.future(for: channel))

        tracker.failRemaining(TestError.cancelled)
        complete(.success(99)) // loser's handler fires late — must be ignored

        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertEqual(error as? TestError, .cancelled)
        }
        _ = try channel.finish()
    }

    /// Calling the completion closure twice settles the promise only once — the
    /// second call is ignored rather than trapping on double-completion.
    func testCompletionClosureIsIdempotent() throws {
        let tracker = ChannelPromiseTracker<Int>()
        let channel = EmbeddedChannel()
        let complete = tracker.register(channel)
        let future = try XCTUnwrap(tracker.future(for: channel))

        complete(.success(1))
        complete(.success(2)) // ignored: the promise is already claimed
        complete(.failure(TestError.boom)) // also ignored

        XCTAssertEqual(try future.wait(), 1)
        tracker.failRemaining(TestError.cancelled)
        _ = try channel.finish()
    }

    // MARK: - future(for:) semantics

    /// `future(for:)` peeks: it returns the winner's future even after the
    /// handler already settled it (an early completion must not "consume" the
    /// entry and hide the result from the caller).
    func testFutureIsRetrievableAfterEarlyCompletion() throws {
        let tracker = ChannelPromiseTracker<Int>()
        let channel = EmbeddedChannel()
        let complete = tracker.register(channel)

        complete(.success(5)) // settles before the caller asks for the future
        let future = try XCTUnwrap(tracker.future(for: channel))
        XCTAssertEqual(try future.wait(), 5)

        tracker.failRemaining(TestError.cancelled)
        _ = try channel.finish()
    }

    /// A channel that was never registered (its initializer threw before
    /// `register(_:)`) has no tracked future.
    func testFutureForUnregisteredChannelIsNil() throws {
        let tracker = ChannelPromiseTracker<Int>()
        let channel = EmbeddedChannel()
        XCTAssertNil(tracker.future(for: channel))
        _ = try channel.finish()
    }

    /// The connection-failed path: `connect` throws, so no winner is consumed
    /// and every candidate promise is orphaned. `failRemaining` in the `defer`
    /// must settle them all so none leaks.
    func testFailRemainingDrainsAllWhenNoWinnerConsumed() throws {
        let tracker = ChannelPromiseTracker<Int>()
        let channels = (0..<3).map { _ in EmbeddedChannel() }
        _ = channels.map { tracker.register($0) }
        let futures = try channels.map { try XCTUnwrap(tracker.future(for: $0)) }

        tracker.failRemaining(TestError.cancelled)

        for future in futures {
            XCTAssertThrowsError(try future.wait()) { error in
                XCTAssertEqual(error as? TestError, .cancelled)
            }
        }
        for channel in channels { _ = try channel.finish() }
    }
}
