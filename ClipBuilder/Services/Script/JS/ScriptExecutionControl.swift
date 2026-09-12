import Foundation
import Synchronization

/// The callback, watchdog and bridge share only this synchronized host state.
nonisolated final class ScriptExecutionControl: Sendable {
    private struct State: Sendable {
        var started = ContinuousClock.now
        var pausedAt: ContinuousClock.Instant?
        var paused: Duration = .zero
        var reason: String?
        var active: ScriptCallLatch?
    }
    private let state = Mutex(State())
    let seconds: Double

    init(seconds: Double = 10) {
        self.seconds = seconds.isFinite ? min(60, max(0.05, seconds)) : 10
    }

    var reason: String? {
        state.withLock { value in
            let end = value.pausedAt ?? .now
            // Reserve a short interruption slice inside the configured allowance.
            if value.reason == nil,
               value.started.duration(to: end) - value.paused >= .seconds(max(0.01, seconds - 0.03)) {
                value.reason = "timeout"
            }
            return value.reason
        }
    }

    func cancel(_ reason: String = "cancelled") {
        let active = state.withLock { value in
            value.reason = value.reason ?? reason
            return value.active
        }
        active?.cancel()
    }

    func register(_ latch: ScriptCallLatch) {
        let cancelled = state.withLock { value in
            value.active = latch
            return value.reason != nil
        }
        if cancelled { latch.cancel() }
    }

    func clear(_ latch: ScriptCallLatch) {
        state.withLock { if $0.active === latch { $0.active = nil } }
    }

    func pause() { state.withLock { if $0.pausedAt == nil { $0.pausedAt = .now } } }
    func resume() {
        state.withLock {
            if let start = $0.pausedAt { $0.paused += start.duration(to: .now); $0.pausedAt = nil }
        }
    }
}

/// Cancellation never signals: the owned callback must drain before completion.
/// Registration rechecks cancellation, closing the cancel-before-register race.
nonisolated final class ScriptCallLatch: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var task: Task<Void, Never>?
        var result: Data?
        var signals = 0
    }
    private let state = Mutex(State())
    private let semaphore = DispatchSemaphore(value: 0)

    func register(_ task: Task<Void, Never>) {
        let cancel = state.withLock { value in
            if value.result != nil { return true }
            value.task = task
            return value.cancelled
        }
        if cancel { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { value in value.cancelled = true; return value.task }
        task?.cancel()
    }

    @discardableResult
    func complete(_ data: Data) -> Bool {
        let won = state.withLock { value in
            guard value.result == nil else { return false }
            value.result = data
            value.task = nil
            value.signals += 1
            return true
        }
        if won { semaphore.signal() }
        return won
    }

    func wait() -> Data {
        semaphore.wait()
        return state.withLock { $0.result ?? Data() }
    }

    var signalCount: Int { state.withLock { $0.signals } }
}
