import Foundation

/// App-wide limits. Acquire only at leaf work, never around a render/task group.
actor MediaWorkScheduler {
    nonisolated enum Resource: Sendable, Hashable { case decoding, encoding, vision }
    nonisolated enum Priority: Sendable, Equatable { case interactive, background }
    nonisolated enum Budget {
        static let encoding = FFmpeg.jobLimit
        static let decoding = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        static let vision = 1
    }

    static let shared = MediaWorkScheduler()

    /// Scope-owned permit; release happens even on an error or cancellation.
    nonisolated final class Permit: Sendable {
        private let scheduler: MediaWorkScheduler
        private let resource: Resource
        init(scheduler: MediaWorkScheduler, resource: Resource) {
            self.scheduler = scheduler
            self.resource = resource
        }
        deinit {
            let scheduler = scheduler
            let resource = resource
            Task { await scheduler.release(resource) }
        }
    }

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let queuedAt: ContinuousClock.Instant?
        let continuation: CheckedContinuation<Permit, Error>
    }
    private var active: [Resource: Int] = [:]
    private var queues: [Resource: [Waiter]] = [:]

    func acquire(_ resource: Resource, priority: Priority = .background) async throws -> Permit {
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

    private func limit(_ resource: Resource) -> Int {
        switch resource {
        case .decoding: Budget.decoding
        case .encoding: Budget.encoding
        case .vision: Budget.vision
        }
    }

    private func cancel(_ id: UUID, resource: Resource) {
        // Already granted or cancelled: its continuation has been resumed.
        guard let index = queues[resource]?.firstIndex(where: { $0.id == id }),
              let waiter = queues[resource]?.remove(at: index) else { return }
        reportWait(waiter, resource: resource)
        waiter.continuation.resume(throwing: CancellationError())
        admitQueued(resource)
    }

    private func release(_ resource: Resource) {
        active[resource, default: 0] -= 1
        admitQueued(resource)
    }

    private func admitQueued(_ resource: Resource) {
        while let queue = queues[resource], !queue.isEmpty {
            let index = queue.firstIndex { $0.priority == .interactive } ?? 0
            let priority = queue[index].priority
            let capacity = limit(resource)
            // Long tracking passes and analyzer batches must leave one decode
            // slot available for interactive thumbnails, even at the minimum budget.
            let admissionLimit = resource == .decoding && priority == .background && capacity >= 2
                ? capacity - 1 : capacity
            guard active[resource, default: 0] < admissionLimit else { return }
            guard let waiter = queues[resource]?.remove(at: index) else { return }
            active[resource, default: 0] += 1
            reportWait(waiter, resource: resource)
            waiter.continuation.resume(returning: Permit(scheduler: self, resource: resource))
        }
    }

    private func reportWait(_ waiter: Waiter, resource: Resource) {
        guard let queuedAt = waiter.queuedAt else { return }
        let elapsed = queuedAt.duration(to: ContinuousClock.now)
        guard elapsed > .milliseconds(250) else { return }
        PerfSignpost.event("MediaPermitWait", metadata: "\(resource) \(waiter.priority) \(elapsed)")
    }

    /// Propagates interactive priority to ffmpeg fallback leaves without
    /// acquiring a second permit around the operation itself.
    @TaskLocal nonisolated static var priority: Priority = .background
}
