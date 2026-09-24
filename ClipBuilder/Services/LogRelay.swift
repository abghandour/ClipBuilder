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
    private let includeProgress: Bool

    init(includeProgress: Bool = false, deliver: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.includeProgress = includeProgress
        self.deliver = deliver
    }

    static func displayText(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("PROGRESS:")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Queue a line; the first line of a burst schedules the flush.
    func post(_ line: String) {
        let display: String? = includeProgress ? line : Self.displayText(line)
        guard let line = display else { return }
        let schedule = pending.withLock { state -> Bool in
            state.lines.append(line)
            if state.scheduled { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor in self.flush() }
    }

    /// A finishing job drains its final status before removing the running row.
    @MainActor func flush() {
        let lines = pending.withLock { state -> [String] in
            defer { state = Pending() }
            return state.lines
        }
        if !lines.isEmpty { deliver(lines) }
    }

    /// `post` as a `@Sendable` closure, for services' `log:` parameters.
    var sink: @Sendable (String) -> Void {
        { [self] line in self.post(line) }
    }
}
