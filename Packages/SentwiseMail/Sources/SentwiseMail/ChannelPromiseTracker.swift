import Foundation
import NIOCore

/// Tracks the per-channel promises created while opening an outbound connection
/// with `ClientBootstrap.connect(host:port:)`, and guarantees every one of them
/// is completed **exactly once** — never left unfulfilled, never completed twice.
///
/// ## Why this exists (backlog item 77)
/// `connect(host:port:)` uses **Happy Eyeballs**: a hostname such as
/// `imap.gmail.com` resolves to several IPv4/IPv6 addresses, so NIO runs the
/// bootstrap's `channelInitializer` **once per candidate connection**. Each run
/// creates a promise for that candidate's channel. Only the *winning* channel's
/// future is consumed by the caller; the losing candidates are discarded by NIO,
/// and a candidate that never became active never receives `channelInactive`, so
/// its handler never settles its promise. Left alone, that promise is
/// deallocated **unfulfilled** when the tracker deinits — which trips NIO's
/// debug-only `EventLoopFuture.deinit` assertion and crashes Debug builds (it is
/// compiled out of Release, but it is a real resource-management bug).
///
/// ## The single-completion contract
/// A promise handed out by `register(_:)` is completed by whichever caller first
/// **atomically claims it under `lock`**:
/// - the channel's handler, via the completion closure returned from
///   `register(_:)` (success / auth-failure / connection-close paths), or
/// - `failRemaining(_:)`, called from the caller's `defer`, which fails every
///   promise not yet claimed (losing candidates and never-activated channels).
///
/// A claim flips the entry's `claimed` flag from `false` to `true` while holding
/// `lock`; only the transition from `false` may complete the promise. Because
/// the flag is read-and-set atomically under the lock, the handler's closure and
/// `failRemaining` are mutually exclusive per promise:
/// - If the handler claims first, `failRemaining` later sees `claimed == true`
///   and skips it.
/// - If `failRemaining` claims first (it removes the entry entirely), the
///   handler's later `claim` finds no entry and returns `nil`, so the closure
///   no-ops.
///
/// The actual `completeWith`/`fail` call happens **outside** the lock — the lock
/// only guards the claim, so a promise-completion callback can never re-enter the
/// lock and deadlock. Once a claim has transferred exclusive ownership, no other
/// caller can obtain the same promise, so `EventLoopPromise`'s trap-on-double-
/// completion can never fire.
///
/// ## Why `future(for:)` peeks instead of removing
/// The winner's future must remain retrievable even in the (rare) case where its
/// handler settles before the caller asks for it. `future(for:)` therefore reads
/// the future without claiming or removing the entry; the entry stays until its
/// handler claims it (marking it done) or `failRemaining` clears the map. The
/// winner is excluded from `failRemaining` because, by the time the caller's
/// `defer` runs `failRemaining`, the winner's future has already resolved — which
/// only happens after its handler claimed it — so its entry is already
/// `claimed`.
final class ChannelPromiseTracker<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let promise: EventLoopPromise<Value>
        var claimed: Bool
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Creates and tracks a promise for `channel`, returning the completion
    /// closure the channel's handler must call to settle it. The closure claims
    /// the promise atomically before completing it, so it and `failRemaining`
    /// can never both complete the same promise. Calling the closure more than
    /// once is safe: only the first call claims the promise; later calls no-op.
    func register(_ channel: Channel) -> @Sendable (Result<Value, Error>) -> Void {
        let promise = channel.eventLoop.makePromise(of: Value.self)
        let id = ObjectIdentifier(channel)
        lock.lock()
        entries[id] = Entry(promise: promise, claimed: false)
        lock.unlock()
        return { [weak self] result in
            guard let self, let claimed = self.claim(id) else { return }
            claimed.completeWith(result)
        }
    }

    /// The future for `channel`, or `nil` if the channel was never registered
    /// (its initializer threw before `register(_:)`). Peeks without claiming or
    /// removing the entry, so the winning channel's future stays retrievable and
    /// its handler remains the sole completer.
    func future(for channel: Channel) -> EventLoopFuture<Value>? {
        lock.lock()
        defer { lock.unlock() }
        return entries[ObjectIdentifier(channel)]?.promise.futureResult
    }

    /// Fails every promise not yet claimed by a handler — the losing Happy
    /// Eyeballs candidates and any channel whose handler never settled — then
    /// clears the map. Call from a `defer` so no tracked promise is ever
    /// deallocated unfulfilled. Promises already claimed by their handlers are
    /// left untouched (they are, or will be, completed by the handler).
    func failRemaining(_ error: Error) {
        lock.lock()
        let pending = entries.values.filter { !$0.claimed }.map(\.promise)
        entries.removeAll()
        lock.unlock()
        for promise in pending {
            promise.fail(error)
        }
    }

    /// Atomically claims the promise for `id`, returning it only to the first
    /// caller. Subsequent callers — and `failRemaining` — get `nil`. Must not be
    /// called while holding `lock`.
    private func claim(_ id: ObjectIdentifier) -> EventLoopPromise<Value>? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], !entry.claimed else { return nil }
        entries[id]?.claimed = true
        return entry.promise
    }
}
