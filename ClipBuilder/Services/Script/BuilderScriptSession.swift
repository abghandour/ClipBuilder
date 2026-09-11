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
    private(set) var library: ScriptLibrarySnapshot
    private(set) var prerequisiteEffects: [PrerequisiteEffect] = []
    private(set) var prerequisiteReports: [PrerequisiteReport] = []
    private var runningPrerequisites = false
    private var activePrerequisite: Task<PrerequisiteReport, Never>?
    private let live: BuilderTimelineModel
    private let hydration: BuilderLibraryHydration
    private var hydrationOpen = true
    private(set) var state: State = .ready
    private(set) var candidate: TimelineDocument?
    private(set) var result: BuilderScriptResult?
    private var working: BuilderTimelineModel?
    private var frozenDiff: TimelineDiff?

    init(live: BuilderTimelineModel, library: ScriptLibrarySnapshot, hydration: BuilderLibraryHydration? = nil) {
        self.live = live
        self.hydration = hydration ?? live.scriptLibraryHydration
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
        self.hydration.begin(runUUID)
    }

    isolated deinit {
        if hydrationOpen { hydration.end(runUUID) }
    }

    @discardableResult
    func run(json: Data) -> BuilderScriptResult {
        guard state == .ready, !runningPrerequisites else { return closedResult() }
        do { return run(try ScriptRunner.decode(json)) }
        catch { return fail(error.localizedDescription) }
    }

    @discardableResult
    func run(_ steps: [BuilderScriptStep],
             onOutcome: ((Int, CommandOutcome, Double) -> Void)? = nil) -> BuilderScriptResult {
        guard state == .ready, !runningPrerequisites, let working else { return closedResult() }
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

    /// The pre-mutation prefix may contain queries and ensures in declared
    /// order. No mutation can overtake an await. Effects are durable Library
    /// state, deliberately retained even after failure/discard/Undo/Revert.
    @discardableResult
    func run(_ steps: [BuilderScriptStep], prerequisites: BuilderPrerequisites,
             confirmed: Bool, refreshLibrary: @MainActor () async throws -> ScriptLibrarySnapshot,
             identityMatches: @MainActor () -> Bool = { true },
             onPrerequisite: ((BuilderPrerequisiteKind, Int64, PrerequisiteReport) -> Void)? = nil,
             onOutcome: ((Int, CommandOutcome, Double) -> Void)? = nil) async -> BuilderScriptResult {
        guard state == .ready, !runningPrerequisites else { return closedResult() }
        var mutationStarted = false
        do {
            _ = try ScriptRunner.decode(JSONEncoder().encode(steps))
            guard steps.count(where: { $0.command.prerequisite != nil }) <= 12 else {
                return fail("A run may contain at most twelve prerequisites.")
            }
            for step in steps {
                if let requirement = step.command.prerequisite {
                    guard confirmed, !mutationStarted, step.bind == nil,
                          library.videos.contains(where: { $0.id == requirement.video }) else {
                        return fail("Prerequisites need confirmation, a project video, and must precede mutations.")
                    }
                } else if case .query = step.command {
                    // Queries can occur in either prefix or mutation suffix.
                } else { mutationStarted = true }
            }
        } catch { return fail(error.localizedDescription) }
        guard steps.contains(where: { $0.command.prerequisite != nil }) else {
            return run(steps, onOutcome: onOutcome)
        }
        runningPrerequisites = true
        defer {
            runningPrerequisites = false
            activePrerequisite = nil
            if state == .discarded { endHydration() }
        }
        var prefixOutcomes: [CommandOutcome] = []
        var prefixBytes = 0
        var suffixStart = steps.count
        do {
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                guard state == .ready, identityMatches(), live.timelineID == timelineID,
                      live.profileName == profileName else { throw ApplyFailure.identityChanged }
                guard live.revision == baselineRevision else { throw ApplyFailure.staleRevision }
                if let requirement = step.command.prerequisite {
                    let started = Date.now
                    let job = Task {
                        await prerequisites.ensure(requirement.kind, video: requirement.video) { status in
                            onPrerequisite?(requirement.kind, requirement.video, .init(outcome: status))
                        }
                    }
                    activePrerequisite = job
                    let report = await withTaskCancellationHandler {
                        await job.value
                    } onCancel: { job.cancel() }
                    activePrerequisite = nil
                    prerequisiteEffects += report.effects
                    prerequisiteReports.append(report)
                    onPrerequisite?(requirement.kind, requirement.video, report)
                    // Refresh explicitly from the captured Library, even after
                    // failure, without hydrating the live or baseline document.
                    if identityMatches(), state == .ready {
                        let refreshed = try await refreshLibrary()
                        guard identityMatches(), refreshed.projectID == projectID else { throw ApplyFailure.identityChanged }
                        guard live.revision == baselineRevision else { throw ApplyFailure.staleRevision }
                        library = refreshed
                        if let working {
                            library.withLayouts {
                                working.seed(document: working.document, scenes: library.scenes,
                                             driveBackedPaths: working.driveBackedPaths, selection: working.selection,
                                             playhead: working.playhead, focusedTrack: working.focusedTrack,
                                             zoom: working.pointsPerSecond)
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard state == .ready else { return closedResult() }
                    guard report.outcome.isComplete else { return fail(report.outcome.summary) }
                    let outcome = CommandOutcome.unchanged(reason: report.outcome.summary)
                    prefixOutcomes.append(outcome)
                    onOutcome?(index, outcome, Date.now.timeIntervalSince(started))
                } else if case .query = step.command, let working {
                    let outcomes = ScriptRunner().run([step], model: working, library: library) { _, outcome, elapsed in
                        onOutcome?(index, outcome, elapsed)
                    }
                    prefixOutcomes += outcomes
                    prefixBytes += try JSONEncoder().encode(outcomes).count
                    guard prefixBytes <= ScriptRunner.maximumResultBytes else { return fail("Prerequisite queries exceed 1 MiB.") }
                    if outcomes.contains(where: \.isRefused) { return fail("Prerequisite query refused.") }
                } else { suffixStart = index; break }
            }
            try Task.checkCancellation()
            guard state == .ready, identityMatches() else { throw ApplyFailure.identityChanged }
            guard live.revision == baselineRevision else { throw ApplyFailure.staleRevision }
            runningPrerequisites = false
            let suffix = Array(steps.dropFirst(suffixStart))
            var result = run(suffix) { index, outcome, elapsed in
                onOutcome?(suffixStart + index, outcome, elapsed)
            }
            result.outcomes = prefixOutcomes + result.outcomes
            guard try JSONEncoder().encode(result).count <= ScriptRunner.maximumResultBytes else {
                return fail("Run results exceed 1 MiB.")
            }
            self.result = result
            return result
        } catch {
            guard state == .ready else { return closedResult() }
            return fail(error is CancellationError ? "Cancelled. No timeline changes applied; saved Library work remains." : String(describing: error))
        }
    }

    /// Release only at the terminal UI action, after Apply has checked revision.
    /// A caller that simply closes a session must call discard().
    private func endHydration() {
        guard hydrationOpen else { return }
        hydrationOpen = false
        hydration.end(runUUID)
    }

    func diff() -> TimelineDiff {
        library.withLayouts {
            frozenDiff ?? TimelineDiff(before: baseline, after: working?.document ?? baseline)
        }
    }

    /// Close admission and retain a value-only preview for review/Apply.
    @discardableResult
    func freeze() -> TimelineDiff {
        guard state == .ready, !runningPrerequisites else { return diff() }
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
        activePrerequisite?.cancel()
        if !runningPrerequisites { endHydration() }
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
