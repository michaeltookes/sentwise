import AppKit
import Foundation

/// Drives the inbox poll on a repeating timer while the Mac is awake.
///
/// This is the *scheduling* half of the watcher — the poll *policy* (fetch,
/// filter, draft, enqueue) lives on `AppState` and is injected as `onTick`, so
/// the policy can be unit-tested without a real timer. The watcher pauses the
/// timer when the Mac sleeps and resumes (with an immediate poll) on wake, so it
/// never claims 24/7 coverage but recovers cleanly. Ticks are single-flighted:
/// a new tick is skipped while the previous one is still running.
@MainActor
final class InboxWatcher {

    private let interval: () -> TimeInterval
    private let onTick: () async -> Void

    private var timer: Timer?
    private var isRunning = false
    private var isAsleep = false
    private var isTicking = false
    private var needsImmediateTickAfterCurrent = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    var isActive: Bool { isRunning }
    private(set) var rescheduleCount = 0

    /// - Parameters:
    ///   - interval: Poll interval in seconds, read at each (re)schedule so a
    ///     settings change takes effect on the next `reschedule()`.
    ///   - onTick: The poll to run each tick and once immediately on `start()`.
    init(interval: @escaping () -> TimeInterval, onTick: @escaping () async -> Void) {
        self.interval = interval
        self.onTick = onTick
    }

    /// Begins watching: registers for sleep/wake, schedules the repeating timer,
    /// and runs an immediate poll. Idempotent while already running.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isAsleep = false
        registerSleepWake()
        schedule()
        tick(queueIfRunning: true)
    }

    /// Pauses watching and tears down the timer and sleep/wake observers.
    func stop() {
        isRunning = false
        isAsleep = false
        needsImmediateTickAfterCurrent = false
        invalidate()
        unregisterSleepWake()
    }

    /// Reschedules the timer to reflect a changed interval. No-op unless
    /// actively running and awake.
    func reschedule() {
        guard isRunning, !isAsleep else { return }
        rescheduleCount += 1
        schedule()
    }

    /// Triggers an immediate catch-up poll (e.g. on network reconnect) if the
    /// watcher is actively running and awake. Single-flighted like every tick.
    func pollNow() {
        guard isRunning, !isAsleep else { return }
        tick(queueIfRunning: true)
    }

    // MARK: - Scheduling

    private func schedule() {
        invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval(), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Keep firing while menus/tracking loops run.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs `onTick`, single-flighting so overlapping ticks can't stack up.
    private func tick(queueIfRunning: Bool = false) {
        guard !isTicking else {
            if queueIfRunning {
                needsImmediateTickAfterCurrent = true
            }
            return
        }
        isTicking = true
        Task { @MainActor in
            await onTick()
            isTicking = false
            if needsImmediateTickAfterCurrent, isRunning, !isAsleep {
                needsImmediateTickAfterCurrent = false
                tick()
            } else {
                needsImmediateTickAfterCurrent = false
            }
        }
    }

    // MARK: - Sleep / Wake

    private func registerSleepWake() {
        guard sleepObserver == nil, wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    private func unregisterSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
    }

    /// Stops polling while asleep; the pending timer would otherwise coalesce
    /// into a burst on wake.
    private func handleSleep() {
        guard isRunning else { return }
        isAsleep = true
        invalidate()
    }

    /// Resumes polling on wake with an immediate catch-up poll.
    private func handleWake() {
        guard isRunning, isAsleep else { return }
        isAsleep = false
        schedule()
        tick(queueIfRunning: true)
    }
}
