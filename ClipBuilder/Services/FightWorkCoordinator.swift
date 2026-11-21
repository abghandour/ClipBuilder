import Foundation

/// One owner per profile database and video. An owner never claims recursively:
/// the scorer includes its own end-of-pass marking in its existing claim.
actor FightWorkCoordinator {
    static let shared = FightWorkCoordinator()

    nonisolated struct Key: Hashable, Sendable {
        let database: ObjectIdentifier
        let videoID: Int64

        init(database: Database, videoID: Int64) {
            self.database = ObjectIdentifier(database)
            self.videoID = videoID
        }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var owners: Set<Key> = []
    private var waiters: [Key: [Waiter]] = [:]

    func withClaim<T: Sendable>(key: Key, operation: @Sendable () async throws -> T) async throws -> T {
        try await claim(key)
        defer { release(key) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func claim(_ key: Key) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if owners.insert(key).inserted { return }
            try await withCheckedThrowingContinuation { continuation in
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(key, id: id) }
        }
    }

    private func cancel(_ key: Key, id: UUID) {
        guard var queue = waiters[key], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[key] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: Key) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.continuation.resume()
        } else {
            owners.remove(key)
        }
    }

    // Internal visibility lets tests synchronize on an enqueued claim, without sleeps.
    func waitingCount(for key: Key) -> Int { waiters[key]?.count ?? 0 }
}
