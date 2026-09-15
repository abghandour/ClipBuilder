import Foundation

/// App-wide limits. Acquire only at leaf work, never around a render/task group.
actor MediaWorkScheduler {
    nonisolated enum Resource: Sendable, Hashable { case decoding, encoding, vision, probing }
    nonisolated enum Priority: Sendable, Equatable { case interactive, background }
    nonisolated enum Budget {
        static let encoding = FFmpeg.jobLimit
        static let decoding = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        static let vision = 1
        static let probing = 2
    }

    static let shared = MediaWorkScheduler()

    /// Scope-owned permit; release happens even on an error or cancellation.
    nonisolated final class Permit: Sendable {
        private let scheduler: MediaWorkScheduler
        private let resource: Resource
        private let priority: Priority
        init(scheduler: MediaWorkScheduler, resource: Resource, priority: Priority) {
            self.scheduler = scheduler
            self.resource = resource
            self.priority = priority
        }
        deinit {
            let scheduler = scheduler
            let resource = resource
            let priority = priority
            Task { await scheduler.release(resource, priority: priority) }
        }
    }

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let queuedAt: ContinuousClock.Instant?
        let interval: PerfSignpost.Interval?
        let continuation: CheckedContinuation<Permit, Error>
    }
    private var active: [Resource: Int] = [:]
    private var backgroundActive: [Resource: Int] = [:]
    private var queues: [Resource: [Waiter]] = [:]
    private var interactiveStreak: [Resource: Int] = [:]
    private let limits: [Resource: Int]
    private let maxInteractiveBurst: Int

    init(decoding: Int = Budget.decoding, encoding: Int = Budget.encoding,
         vision: Int = Budget.vision, probing: Int = Budget.probing,
         maxInteractiveBurst: Int = 4) {
        limits = [.decoding: max(1, decoding), .encoding: max(1, encoding),
                  .vision: max(1, vision), .probing: max(1, probing)]
        self.maxInteractiveBurst = max(1, maxInteractiveBurst)
    }

    func acquire(_ resource: Resource, priority: Priority = MediaWorkScheduler.priority) async throws -> Permit {
        let id = UUID()
        let permit: Permit = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                queues[resource, default: []].append(
                    Waiter(id: id, priority: priority,
                           queuedAt: PerfSignpost.isEnabled ? ContinuousClock.now : nil,
                           interval: PerfSignpost.begin("MediaQueueWait", metadata: "\(resource) \(priority)"),
                           continuation: continuation))
                admitQueued(resource)
            }
        } onCancel: {
            Task { await self.cancel(id, resource: resource) }
        }
        // If cancellation races with admission, dropping the granted permit
        // releases it; cancel() must not resume that continuation a second time.
        try Task.checkCancellation()
        return permit
    }

    /// A small diagnostic snapshot also permits deterministic contention tests.
    func snapshot(_ resource: Resource) -> (active: Int, waiting: Int) {
        (active[resource, default: 0], queues[resource, default: []].count)
    }

    private func cancel(_ id: UUID, resource: Resource) {
        // Already granted or cancelled: its continuation has been resumed.
        guard let index = queues[resource]?.firstIndex(where: { $0.id == id }),
              let waiter = queues[resource]?.remove(at: index) else { return }
        reportWait(waiter, resource: resource)
        waiter.continuation.resume(throwing: CancellationError())
        admitQueued(resource)
    }

    private func release(_ resource: Resource, priority: Priority) {
        active[resource, default: 0] -= 1
        if priority == .background { backgroundActive[resource, default: 0] -= 1 }
        admitQueued(resource)
    }

    private func admitQueued(_ resource: Resource) {
        while let queue = queues[resource], !queue.isEmpty {
            let capacity = limits[resource, default: 1]
            guard active[resource, default: 0] < capacity else { return }
            // Long tracking passes and analyzer batches must leave one decode
            // slot available for interactive thumbnails, even at the minimum budget.
            let backgroundLimit = resource == .decoding && capacity >= 2
                ? capacity - 1 : capacity
            let background = backgroundActive[resource, default: 0] < backgroundLimit
                ? queue.firstIndex { $0.priority == .background } : nil
            let interactive = queue.firstIndex { $0.priority == .interactive }
            // Bound priority overtaking so a continuous stream of requested
            // previews cannot starve exports or analysis. Only eligible work
            // competes; the reserved decode slot can still admit interactive work.
            let next = interactiveStreak[resource, default: 0] >= maxInteractiveBurst
                ? (background ?? interactive) : (interactive ?? background)
            guard let index = next else { return }
            guard let waiter = queues[resource]?.remove(at: index) else { return }
            active[resource, default: 0] += 1
            if waiter.priority == .background {
                backgroundActive[resource, default: 0] += 1
                interactiveStreak[resource] = 0
            } else if queue.contains(where: { $0.priority == .background }) {
                interactiveStreak[resource, default: 0] += 1
            } else {
                interactiveStreak[resource] = 0
            }
            reportWait(waiter, resource: resource)
            waiter.continuation.resume(returning: Permit(scheduler: self, resource: resource, priority: waiter.priority))
        }
    }

    private func reportWait(_ waiter: Waiter, resource: Resource) {
        PerfSignpost.end(waiter.interval)
        guard let queuedAt = waiter.queuedAt else { return }
        let elapsed = queuedAt.duration(to: ContinuousClock.now)
        guard elapsed > .milliseconds(250) else { return }
        PerfSignpost.event("MediaPermitWait", metadata: "\(resource) \(waiter.priority) \(elapsed)")
    }

    /// Propagates interactive priority to ffmpeg fallback leaves without
    /// acquiring a second permit around the operation itself.
    @TaskLocal nonisolated static var priority: Priority = .background

    /// Inherited by child work; tests can isolate admission without changing
    /// process-wide scheduler state or the application's data directory.
    @TaskLocal nonisolated static var current: MediaWorkScheduler = shared
}
