import Foundation

/// One atomic preview, with no live subscriptions or persistence hooks.
/// Successful lists accumulate until freeze; any refusal aborts the session.
@MainActor
final class BuilderScriptSession {
    enum State { case ready, completed, failed, discarded }
    let runUUID = UUID().uuidString
    let baselineRevision: Int
    private(set) var frozenCandidate: BuilderScriptSnapshot?
    let timelineID: Int64?
    let profileName: String
    let projectID: Int64?
    let baseline: TimelineDocument
    let library: ScriptLibrarySnapshot
    private(set) var state: State = .ready
    private(set) var candidate: TimelineDocument?
    private(set) var result: BuilderScriptResult?
    private var working: BuilderTimelineModel?
    private var frozenDiff: TimelineDiff?

    init(live: BuilderTimelineModel, library: ScriptLibrarySnapshot) {
        baselineRevision = live.revision
        timelineID = live.timelineID
        profileName = live.profileName
        projectID = library.projectID
        baseline = live.document
        self.library = library
        let model = BuilderTimelineModel(mode: .transient)
        library.withLayouts {
            model.seed(document: baseline, scenes: library.scenes,
                       driveBackedPaths: live.driveBackedPaths, selection: live.selection,
                       playhead: live.playhead, focusedTrack: live.focusedTrack, zoom: live.pointsPerSecond)
        }
        working = model
    }

    @discardableResult
    func run(json: Data) -> BuilderScriptResult {
        guard state == .ready else { return closedResult() }
        do { return run(try ScriptRunner.decode(json)) }
        catch { return fail(error.localizedDescription) }
    }

    @discardableResult
    func run(_ steps: [BuilderScriptStep],
             onOutcome: ((Int, CommandOutcome, Double) -> Void)? = nil) -> BuilderScriptResult {
        guard state == .ready, let working else { return closedResult() }
        // The whole-list size limit also applies to programmatic callers.
        do {
            let encoded = try JSONEncoder().encode(steps)
            guard encoded.count <= ScriptRunner.maximumBytes else { return fail("Script exceeds 256 KiB.") }
        } catch { return fail(error.localizedDescription) }
        let runner = ScriptRunner()
        let outcomes = runner.run(steps, model: working, library: library, onOutcome: onOutcome)
        let completed = !outcomes.contains(where: \.isRefused)
        candidate = completed ? working.document : nil
        if !completed {
            frozenDiff = library.withLayouts {
                TimelineDiff(before: baseline, after: runner.diagnosticDocument ?? working.document)
            }
            state = .failed
            working.cancelPendingAutosave()
            self.working = nil
        }
        let result = BuilderScriptResult(outcomes: outcomes, completed: completed,
                                        hasDocumentChanges: completed && !diff().isEmpty)
        self.result = result
        return result
    }

    func diff() -> TimelineDiff {
        library.withLayouts {
            frozenDiff ?? TimelineDiff(before: baseline, after: working?.document ?? baseline)
        }
    }

    /// Close admission and retain a value-only preview for review/Apply.
    @discardableResult
    func freeze() -> TimelineDiff {
        guard state == .ready else { return diff() }
        library.withLayouts { working?.normalizeScriptCandidate() }
        frozenDiff = diff()
        candidate = working?.document
        if let candidate {
            frozenCandidate = BuilderScriptSnapshot(document: candidate, timelineID: timelineID,
                                                    profileName: profileName, runUUID: runUUID)
        }
        working?.cancelPendingAutosave()
        working = nil
        state = .completed
        return diff()
    }

    func discard() {
        working?.cancelPendingAutosave()
        working = nil
        candidate = nil
        frozenCandidate = nil
        frozenDiff = nil
        result = nil
        state = .discarded
    }

    private func fail(_ reason: String) -> BuilderScriptResult {
        frozenDiff = diff()
        working?.cancelPendingAutosave()
        working = nil
        candidate = nil
        frozenCandidate = nil
        state = .failed
        let result = BuilderScriptResult(outcomes: [.refused(code: "invalid_script", reason: reason)],
                                         completed: false, hasDocumentChanges: false)
        self.result = result
        return result
    }

    private func closedResult() -> BuilderScriptResult {
        BuilderScriptResult(outcomes: [.refused(code: "closed", reason: "Session no longer accepts commands.")],
                            completed: false, hasDocumentChanges: false)
    }
}
