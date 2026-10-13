import Foundation

/// Tracks Google token revocations that are still in flight (item 104).
///
/// Revoking a refresh token at Google removes the app's whole grant for that
/// user, so a revoke Google processes *after* the user has signed in again
/// would also kill the replacement grant. The coordinator runs every revoke
/// through this tracker and waits (bounded) for pending ones before it starts
/// a new browser authorization.
@MainActor
final class GoogleRevocationTracker {
    private var pending: [UUID: Task<Void, Never>] = [:]

    var hasPending: Bool { !pending.isEmpty }

    /// Runs `revoke`, tracked until it finishes (successfully or not).
    func run(_ revoke: @escaping @MainActor () async -> Void) async {
        let id = UUID()
        let task = Task { @MainActor in await revoke() }
        pending[id] = task
        await task.value
        pending[id] = nil
    }

    /// Waits until every revoke pending right now has finished, or `timeout`
    /// elapses. Returns `false` on timeout.
    func waitForPending(timeout: TimeInterval) async -> Bool {
        let tasks = Array(pending.values)
        guard !tasks.isEmpty else { return true }
        let gate = FirstResult()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task {
                for task in tasks { await task.value }
                gate.resume(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                gate.resume(false)
            }
        }
    }
}

/// Resumes a continuation exactly once, with whichever result arrives first.
private final class FirstResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
