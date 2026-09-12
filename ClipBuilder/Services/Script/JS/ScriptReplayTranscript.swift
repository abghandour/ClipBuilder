import Foundation

/// Value-only replay ownership survives the session's terminal Apply/Discard.
/// Failed lists never enter this transcript; their outcomes remain in the audit.
nonisolated struct ScriptReplayTranscript: Sendable {
    struct Entry: Sendable {
        var steps: [BuilderScriptStep]
        var result: BuilderScriptResult
        var libraryAfterPrerequisite: ScriptLibrarySnapshot?
        var report: PrerequisiteReport?
        var selection: TimelineSelection?
    }
    let capture: ScriptCapture
    private(set) var entries: [Entry] = []
    private(set) var bytes = 0
    private(set) var disabledReason: String?
    private(set) var expectedDiff: TimelineDiff?

    init(capture: ScriptCapture) {
        self.capture = capture
        do { bytes = try JSONEncoder().encode(ScriptValue.stored(capture)).count }
        catch { disabledReason = "Missing baseline provenance." }
        if bytes > 4 * 1024 * 1024 { disabledReason = "Replay exceeds 4 MiB." }
    }

    mutating func finish(_ diff: TimelineDiff) {
        guard disabledReason == nil else { return }
        do {
            let size = try JSONEncoder().encode(diff).count
            guard bytes + size <= 4 * 1024 * 1024 else {
                disabledReason = "Replay and normalized diff exceed 4 MiB."
                entries.removeAll()
                return
            }
            bytes += size
            expectedDiff = diff
        } catch { disabledReason = "Missing normalized diff provenance."; entries.removeAll() }
    }

    mutating func append(_ entry: Entry) {
        guard disabledReason == nil, entry.result.completed else { return }
        do {
            let size = try JSONEncoder().encode(entry.steps).count + JSONEncoder().encode(entry.result).count
                + (entry.libraryAfterPrerequisite.map { try JSONEncoder().encode(ScriptValue.stored($0)).count } ?? 0)
                + (entry.report.map { try JSONEncoder().encode(ScriptValue.stored($0)).count } ?? 0)
            guard entries.count < 128, bytes + size <= 4 * 1024 * 1024 else {
                disabledReason = "Replay exceeds 128 entries or 4 MiB."
                entries.removeAll()
                return
            }
            bytes += size
            entries.append(entry)
        } catch { disabledReason = "Missing replay provenance."; entries.removeAll() }
    }
}
