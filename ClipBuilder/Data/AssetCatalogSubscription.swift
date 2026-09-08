import Foundation

/// Owns the lifetime of a catalog observation without retaining the store.
nonisolated final class AssetCatalogSubscription {
    private let task: Task<Void, Never>

    @MainActor
    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        let changes = NotificationCenter.default.notifications(named: AssetCatalogChanges.notification)
            .map { _ in () }
        task = Task { @MainActor in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                onChange()
            }
        }
    }

    deinit { task.cancel() }
}
