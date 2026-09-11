import Foundation

/// Only ordinary Library refresh is deferred. Direct document edits still
/// advance revision and invalidate the session through the existing stale gate.
@MainActor
final class BuilderLibraryHydration {
    private var sessions: Set<String> = []
    private var pending: (@MainActor () -> Void)?

    func begin(_ id: String) { sessions.insert(id) }
    func refresh(_ apply: @escaping @MainActor () -> Void) {
        if sessions.isEmpty { apply() } else { pending = apply }
    }
    func end(_ id: String) {
        sessions.remove(id)
        guard sessions.isEmpty else { return }
        let apply = pending
        pending = nil
        apply?()
    }
}
