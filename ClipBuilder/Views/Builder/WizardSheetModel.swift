import Foundation
import Observation

/// View-free orchestration. A preview owns its session until a terminal action;
/// request edits cannot relabel the frozen run or change its provenance.
@MainActor @Observable
final class WizardSheetModel {
    enum Phase: Equatable { case idle, running, preview, found, unrecognised, refused, applying, applied, discarded }
    var request = ""
    private(set) var phase: Phase = .idle
    private(set) var history: [String] = []
    private(set) var log: [String] = []
    private(set) var reasons: [String] = []
    private(set) var failure: ApplyFailure?
    private(set) var diff: TimelineDiff?
    private(set) var diffLines: [String] = []
    private(set) var results: [SceneRecord] = []
    private(set) var beforeVersion: WizardBeforeRecord?
    private(set) var session: BuilderScriptSession?
    private(set) var runRequest = ""
    private(set) var duration: Double = 0
    private var isStarting = false
    let profile: String
    let timelineID: Int64?
    let projectID: Int64?

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let database: Database?
    @ObservationIgnored private let historyStore: BuilderWizardHistory
    @ObservationIgnored private let loadLibrary: @MainActor () async throws -> ScriptLibrarySnapshot
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var dismissed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var findContext: ParserContext?
    @ObservationIgnored private var findRevision: Int?

    init(store: AppStore, history: BuilderWizardHistory = BuilderWizardHistory(),
         loadLibrary: (@MainActor () async throws -> ScriptLibrarySnapshot)? = nil) {
        self.store = store
        database = store.database
        historyStore = history
        profile = store.builder.profileName
        timelineID = store.builder.timelineID
        projectID = store.activeProjectID
        self.history = history.requests(profile: profile)
        self.loadLibrary = loadLibrary ?? { try await BuilderWizardLibrary.snapshot(store: store) }
    }

    var busy: Bool { isStarting || phase == .running || phase == .applying }
    var canApply: Bool { phase == .preview && failure == nil && session?.state == .completed && diff?.isEmpty == false }
    var identityMatches: Bool {
        store.builder.timelineID == timelineID && store.builder.profileName == profile
            && store.activeProjectID == projectID && store.database === database
    }
    var failureMessage: String? {
        guard let failure else { return nil }
        switch failure {
        case .staleRevision: return "The timeline changed. Run again to preview against the latest edits."
        case .identityChanged: return "The open timeline or profile changed. Reopen Wizard on that timeline."
        case .commitInProgress: return "A timeline commit is in progress. Wait for it to finish, then retry."
        case .missingUndoManager: return "Undo is unavailable. Close and reopen Wizard in the Builder window."
        case .missingBeforeVersion: return "The saved before-version is no longer available."
        case .persistence(let reason): return "Could not save the run: \(reason)"
        case .candidateChanged: return "The preview changed. Run again."
        case .notApplicable: return "This run has no applicable timeline changes."
        }
    }

    func beginRun() { task = Task { await run() } }

    func run() async {
        guard !busy, !dismissed else { return }
        isStarting = true
        defer { isStarting = false }
        await discard()
        guard !dismissed, identityMatches else { failure = .identityChanged; return }
        generation += 1
        let token = generation
        let revision = store.builder.revision
        runRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        historyStore.add(runRequest, profile: profile)
        history = historyStore.requests(profile: profile)
        phase = .running
        log = ["Collecting the current Library snapshot…"]
        reasons = []; failure = nil; diff = nil; diffLines = []; results = []; findContext = nil
        let started = Date.now
        do {
            let library = try await loadLibrary()
            try Task.checkCancellation()
            guard !dismissed, token == generation else { return }
            guard identityMatches, library.projectID == projectID else { throw ApplyFailure.identityChanged }
            guard revision == store.builder.revision else { throw ApplyFailure.staleRevision }
            let context = ParserContext(library: library, model: store.builder)
            let parseStarted = Date.now
            let program = BuilderRequestParser().parse(runRequest, context: context)
            appendLog("Parser finished in \(milliseconds(since: parseStarted)).")
            switch program {
            case .unrecognised(let reasons):
                self.reasons = reasons
                phase = .unrecognised
                appendLog("No full recognition. No timeline changes applied.")
            case .find(let filter, _):
                // Page through the actual query surface; never interpret a find as a script.
                results = try find(filter, context: context)
                findContext = context
                findRevision = revision
                phase = .found
                appendLog("Recognised find: \(results.count) scenes. No timeline changes applied.")
            case .script(let steps):
                appendLog("Fully recognised local script: \(steps.count) commands.")
                execute(steps, library: library)
            }
            duration = Date.now.timeIntervalSince(started)
            appendLog("Run finished in \(milliseconds(since: started)).")
        } catch is CancellationError {
            if token == generation { phase = .discarded }
        } catch {
            guard !dismissed, token == generation else { return }
            if let applyFailure = error as? ApplyFailure { failure = applyFailure }
            else { reasons = [error.localizedDescription] }
            phase = .refused
            appendLog(failureMessage ?? error.localizedDescription)
        }
    }

    private func find(_ filter: SceneFilter, context: ParserContext) throws -> [SceneRecord] {
        var ids: [Int64] = []
        var offset = 0
        repeat {
            var query = BuilderQuery(.scenes, offset: offset, limit: 200)
            query.sceneFilter = filter
            let page = try query.execute(model: store.builder, library: context.library) { _ in
                throw ScriptError.invalid("Find does not resolve clip IDs.")
            }
            ids += page.scenes.map(\.id)
            guard ids.count <= ScriptRunner.maximumAffectedItems else {
                throw ScriptError.invalid("Find exceeds 2,000 scenes. Narrow the request.")
            }
            guard let next = page.nextOffset else { break }
            offset = next
        } while true
        let byID = Dictionary(context.library.scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    private func execute(_ steps: [BuilderScriptStep], library: ScriptLibrarySnapshot) {
        let session = BuilderScriptSession(live: store.builder, library: library)
        self.session = session
        let result = session.run(steps) { [self] index, outcome, elapsed in
            let command = String(describing: steps[index].command)
            let detail: String
            switch outcome {
            case .applied(_, _, let warnings): detail = "Applied" + (warnings.isEmpty ? "" : ": " + warnings.joined(separator: "; "))
            case .unchanged(let reason): detail = "Unchanged: \(reason)"
            case .refused(let code, let reason): detail = "Refused [\(code)]: \(reason)"
            }
            appendLog("\(index + 1). \(command): \(detail) (\(Int(elapsed * 1000)) ms)")
            if outcome.isRefused { reasons.append(detail) }
        }
        diff = session.freeze()
        diffLines = BuilderWizardDiff.lines(session: session, steps: steps)
        phase = result.completed ? .preview : .refused
        if !result.completed { appendLog("Run refused. No timeline changes applied.") }
    }

    func addAllAsBRoll() {
        guard phase == .found, let context = findContext, identityMatches else { failure = .identityChanged; return }
        guard findRevision == store.builder.revision,
              TimelineDiff(before: context.document, after: store.builder.document).isEmpty else { failure = .staleRevision; return }
        guard results.count <= ScriptRunner.maximumSteps else {
            reasons = ["Adding these results would exceed 200 commands. Narrow the find request."]
            return
        }
        failure = nil
        // Explicit user action starts a new mutation preview; always requires Apply.
        runRequest = "Add find results as B-roll: " + runRequest
        var at = store.builder.playhead
        let steps = results.map { scene in
            defer { at += scene.duration }
            return BuilderScriptStep(.addCutaway(scene: scene.id, at: at, track: store.builder.focusedTrack ?? 0,
                                                 duration: scene.duration, coverAll: false))
        }
        execute(steps, library: context.library)
    }

    func pickerRequest() -> BuilderTimelineModel.BRollRequest? {
        guard phase == .found, identityMatches else { return nil }
        return .init(time: store.builder.playhead, track: store.builder.focusedTrack ?? 0)
    }

    func apply() async {
        guard canApply, let session else { return }
        phase = .applying
        let result = await store.applyWizardRun(session: session, request: runRequest, provenance: provenance)
        switch result {
        case .success:
            self.session = nil
            session.discard()
            phase = .applied
            appendLog("Applied as one undoable timeline edit.")
            await refreshBeforeVersion()
        case .failure(let failure):
            self.failure = failure
            phase = .preview
            appendLog(failureMessage ?? "Apply failed.")
            if dismissed { await discard() }
        }
    }

    func retryApply() async { failure = nil; await apply() }

    func discard() async {
        guard phase != .applying else { return }
        guard let session else { return }
        self.session = nil
        // The captured database/timeline remain the audit owner after a switch.
        // Clear preview synchronously before suspension, but retain its immutable identity.
        let record = BuilderRunRecord(runUUID: session.runUUID, timelineID: session.timelineID ?? 0,
                                      request: runRequest, provider: "local", durationSeconds: duration,
                                      status: .discarded, baselineRevision: session.baselineRevision)
        session.discard()
        phase = .discarded
        do {
            if let database, session.timelineID != nil { try await database.recordBuilderRun(record) }
        } catch { failure = .persistence(error.localizedDescription); appendLog(failureMessage ?? "Could not record discard.") }
    }

    func dismiss() {
        dismissed = true
        generation += 1
        task?.cancel()
        task = nil
        if phase == .running { phase = .discarded }
        Task { await discard() }
    }

    func refreshBeforeVersion() async {
        guard let database, let timelineID, identityMatches else { beforeVersion = nil; return }
        do {
            let before = try await database.fetchWizardBefore(timelineID: timelineID)
            if identityMatches { beforeVersion = before }
        } catch { failure = .persistence(error.localizedDescription) }
    }

    func revert() async {
        guard !busy, let timelineID, let beforeVersion, identityMatches else { return }
        isStarting = true
        defer { isStarting = false }
        await discard()
        failure = nil
        phase = .applying
        switch await store.revertLastWizardRun(timelineID: timelineID, expectedRunUUID: beforeVersion.runUUID) {
        case .success: phase = .idle; self.beforeVersion = nil; diff = nil; diffLines = []; appendLog("Reverted the last Wizard run.")
        case .failure(let failure):
            self.failure = failure
            phase = .refused
            if failure == .staleRevision { await refreshBeforeVersion() }
        }
    }

    private var provenance: AIProvenance {
        AIProvenance(provider: "local", technique: "builder-request-parser", duration: duration)
    }
    private func appendLog(_ line: String) {
        // Cap individual metadata as well as total retained UI log bytes.
        log.append(String(line.prefix(2000)))
        while log.reduce(0, { $0 + $1.utf8.count }) > 64 * 1024 { log.removeFirst() }
    }
    private func milliseconds(since start: Date) -> String { "\(Int(Date.now.timeIntervalSince(start) * 1000)) ms" }
}
