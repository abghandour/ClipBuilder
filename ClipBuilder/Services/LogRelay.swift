import Foundation
import Synchronization

/// Coalesces log lines posted from background work into one main-actor
/// delivery per turn, in order. Long runs used to spawn a task per line,
/// each mutating an observed array (one re-render per line, and no
/// ordering guarantee between the tasks).
nonisolated final class LogRelay: Sendable {
    private struct Pending {
        var lines: [String] = []
        var scheduled = false
    }

    private let pending = Mutex(Pending())
    private let deliver: @MainActor @Sendable ([String]) -> Void

    init(deliver: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.deliver = deliver
    }

    /// Queue a line; the first line of a burst schedules the flush.
    func post(_ line: String) {
        let schedule = pending.withLock { state -> Bool in
            state.lines.append(line)
            if state.scheduled { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor in
            let lines = self.pending.withLock { state -> [String] in
                defer { state = Pending() }
                return state.lines
            }
            if !lines.isEmpty { self.deliver(lines) }
        }
    }

    /// `post` as a `@Sendable` closure, for services' `log:` parameters.
    var sink: @Sendable (String) -> Void {
        { [self] line in self.post(line) }
    }
}
