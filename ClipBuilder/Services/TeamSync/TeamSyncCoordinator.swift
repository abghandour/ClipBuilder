import Foundation

/// All scheduling sources share one admission gate, including initial uploads.
/// Reentrancy at network awaits cannot admit a second cycle.
actor TeamSyncCoordinator {
    private var cycle: Task<Void, Error>?

    @discardableResult
    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws -> Bool {
        guard cycle == nil else { return false }
        try Task.checkCancellation()
        let task = Task { try await operation() }
        cycle = task
        defer { cycle = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return true
    }

    func cancelAndWait() async {
        guard let cycle else { return }
        cycle.cancel()
        _ = try? await cycle.value
    }
}
