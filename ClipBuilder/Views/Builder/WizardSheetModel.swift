import Foundation
import Observation

/// View-free orchestration. A preview owns its session until a terminal action;
/// request edits cannot relabel the frozen run or change its provenance.
@MainActor @Observable
final class WizardSheetModel {
    enum Phase: Equatable { case idle, awaitingPrerequisites, running, preview, found, unrecognised, refused, applying, applied, discarded }
    var request = ""
    var provider: BuilderAgentProvider = .local
    private(set) var agentEvents: [BuilderRunEvent] = []
    private(set) var agentSummary = ""
    @ObservationIgnored private var agentRun: BuilderAgentRun?
    @ObservationIgnored private var pendingAgent = false
    @ObservationIgnored private var runProvider: BuilderAgentProvider = .local
    @ObservationIgnored private var runModel: String?
    @ObservationIgnored private var runBinary: String?
    @ObservationIgnored private var runLimits = BuilderAgentLimits()
    @ObservationIgnored private var agentProvenance: AIProvenance?
    @ObservationIgnored private var agentAuditSaved = false
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
    private(set) var prerequisiteDisclosures: [String] = []
    private(set) var persistentEffects: [PrerequisiteEffect] = []
    @ObservationIgnored private var pendingSteps: [BuilderScriptStep]?

    @ObservationIgnored private var reparseAfterPrerequisites = false

    let profile: String
    let timelineID: Int64?
    let projectID: Int64?

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let database: Database?
    @ObservationIgnored private let prerequisites: BuilderPrerequisites
    @ObservationIgnored private let agentExecutor: BuilderAgentRun.Executor?
    @ObservationIgnored private let historyStore: BuilderWizardHistory
    @ObservationIgnored private let loadLibrary: @MainActor () async throws -> ScriptLibrarySnapshot
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var dismissed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var findContext: ParserContext?
    @ObservationIgnored private var findRevision: Int?

    init(store: AppStore, history: BuilderWizardHistory = BuilderWizardHistory(),
         loadLibrary: (@MainActor () async throws -> ScriptLibrarySnapshot)? = nil,
         prerequisites: BuilderPrerequisites? = nil,
         agentExecutor: BuilderAgentRun.Executor? = nil) {
        self.store = store
        self.agentExecutor = agentExecutor
        self.prerequisites = prerequisites ?? store.builderPrerequisites
        database = store.database
        historyStore = history
        profile = store.builder.profileName
        timelineID = store.builder.timelineID
        projectID = store.activeProjectID
        self.history = history.requests(profile: profile)
        // The saved provider choice is honoured only while that provider is enabled.
        if let saved = BuilderAgentProvider(rawValue: store.settings.ai.tasks["builder_agent"] ?? ""),
           saved.disabledReason == nil { provider = saved }
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

    func saveProviderPreference() {
        guard !busy, phase != .awaitingPrerequisites, provider.disabledReason == nil else { return }
        store.settings.ai.tasks["builder_agent"] = provider.rawValue
        store.saveSettings()
    }

    func beginRun() {
        guard task == nil, !busy else { return }
        task = Task { await run(); task = nil }
    }

    func run(program suppliedProgram: BuilderProgram? = nil) async {
        guard !busy, !dismissed else { return }
        isStarting = true
        defer { isStarting = false }
        await discard()
        guard !dismissed, identityMatches else { failure = .identityChanged; return }
        generation += 1
        let token = generation
        let revision = store.builder.revision
        runProvider = provider
        let configuredAgent = store.settings.ai.providers[runProvider.rawValue]
        runModel = store.settings.ai.taskModels["builder_agent"] ?? configuredAgent?.model
        runBinary = configuredAgent?.bin
        runLimits = store.settings.builderAgent
        runRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        historyStore.add(runRequest, profile: profile)
        history = historyStore.requests(profile: profile)
        phase = .running
        log = ["Collecting the current Library snapshot…"]
        reasons = []; failure = nil; diff = nil; diffLines = []; results = []; findContext = nil
        pendingSteps = nil; reparseAfterPrerequisites = false; prerequisiteDisclosures = []; persistentEffects = []
        agentEvents = []; agentSummary = ""; agentProvenance = nil; agentAuditSaved = false; pendingAgent = false
        let started = Date.now
        do {
            let library = try await loadLibrary()
            try Task.checkCancellation()
            guard !dismissed, token == generation else { return }
            guard identityMatches, library.projectID == projectID else { throw ApplyFailure.identityChanged }
            guard revision == store.builder.revision else { throw ApplyFailure.staleRevision }
            let context = ParserContext(library: library, model: store.builder)
            let parseStarted = Date.now
            let program: BuilderProgram
            if let suppliedProgram { program = suppliedProgram }
            else {
                #if DEBUG
                if runRequest.hasPrefix("[") { program = .script(try ScriptRunner.decode(Data(runRequest.utf8))) }
                else { program = BuilderRequestParser().parse(runRequest, context: context) }
                #else
                program = BuilderRequestParser().parse(runRequest, context: context)
                #endif
            }
            if runProvider != .local, suppliedProgram == nil {
                if let reason = runProvider.disabledReason { throw ScriptError.invalid(reason) }
                let disclosed: [BuilderScriptStep]
                switch program {
                case .deferred(let steps), .script(let steps): disclosed = steps.filter { $0.command.prerequisite != nil }
                default: disclosed = []
                }
                if disclosed.isEmpty {
                    let session = BuilderScriptSession(live: store.builder, library: library, hydration: store.builderLibraryHydration)
                    self.session = session
                    await executeAgent(session: session, confirmed: [], token: token)
                } else {
                    pendingAgent = true
                    awaitPrerequisites(disclosed, library: library)
                }
                return
            }
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
            case .deferred(let steps):
                reparseAfterPrerequisites = true
                awaitPrerequisites(steps, library: library)
            case .script(let steps):
                appendLog("Fully recognised local script: \(steps.count) commands.")
                if steps.contains(where: { $0.command.prerequisite != nil }) {
                    awaitPrerequisites(steps, library: library)
                } else { execute(steps, library: library) }
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

    private func awaitPrerequisites(_ steps: [BuilderScriptStep], library: ScriptLibrarySnapshot) {
        // Hold this exact baseline and request through confirmation.
        session = BuilderScriptSession(live: store.builder, library: library,
                                       hydration: store.builderLibraryHydration)
        pendingSteps = steps
        prerequisiteDisclosures = Array(Set(steps.compactMap { step in
            step.command.prerequisite.map { "Video \($0.video): \($0.kind.disclosure)" }
        })).sorted()
        phase = .awaitingPrerequisites
        appendLog("Waiting for Library work confirmation. No prerequisites have started.")
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
        let session = BuilderScriptSession(live: store.builder, library: library, hydration: store.builderLibraryHydration)
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

    func beginConfirmedPrerequisites() {
        guard task == nil else { return }
        task = Task { await confirmPrerequisites(); task = nil }
    }

    /// One explicit confirmation covers this frozen program only. Library work
    /// is saved immediately, independently of manual timeline Apply.
    func confirmPrerequisites() async {
        guard phase == .awaitingPrerequisites, !dismissed,
              let steps = pendingSteps, let session else { return }
        pendingSteps = nil
        phase = .running
        if pendingAgent {
            pendingAgent = false
            await executeAgent(session: session, confirmed: steps.map(\.command), token: generation)
            return
        }
        let token = generation
        let started = Date.now
        let library = session.library
        let language = store.settings.transcribeLanguage
        let profileGeneration = store.profileGeneration
        var result = await session.run(steps, prerequisites: prerequisites, confirmed: true,
            refreshLibrary: { [database] in
                guard let database else { throw ApplyFailure.identityChanged }
                return try await library.refreshed(database: database, language: language)
            }, identityMatches: { [self] in identityMatches && !dismissed && token == generation },
            onPrerequisite: { [self] kind, video, report in
                persistentEffects += report.effects
                appendLog("\(kind.rawValue), video \(video): \(report.outcome.summary)")
                if !report.effects.isEmpty { appendLog("Library work already saved. Discard, Undo and Revert will keep it.") }
            }, onOutcome: { [self] index, outcome, elapsed in
                appendLog("\(index + 1). \(String(describing: outcome)) (\(Int(elapsed * 1000)) ms)")
            })
        var executedSteps = steps
        var reparseReasons: [String] = []
        if result.completed, reparseAfterPrerequisites, !dismissed, token == generation {
            let context = ParserContext(library: session.library, model: store.builder)
            switch BuilderRequestParser().parse(runRequest, context: context) {
            case .script(let mutations):
                executedSteps += mutations
                result = session.run(mutations) { [self] index, outcome, elapsed in
                    appendLog("\(steps.count + index + 1). \(String(describing: outcome)) (\(Int(elapsed * 1000)) ms)")
                }
            case .unrecognised(let reasons): reparseReasons = reasons
            case .find: reparseReasons = ["The refreshed request produced a find instead of timeline edits."]
            case .deferred: reparseReasons = ["Silence evidence is still unavailable after Library work. No timeline changes applied."]
            }
        }
        reparseAfterPrerequisites = false
        duration += Date.now.timeIntervalSince(started)
        // Refresh published Library lists through the hydration gate without
        // refreshAll's implicit error sheet. Even cancellation must account for
        // work saved before the service drained.
        if identityMatches, let database {
            do {
                let snapshot = try await database.fetchLibrarySnapshot(projectID: projectID)
                if identityMatches { store.applyLibrarySnapshot(snapshot, generation: profileGeneration) }
            } catch { appendLog("Library work finished; refreshing the Library failed: \(error)") }
        }
        guard !dismissed, token == generation else { return }
        diff = session.freeze()
        diffLines = BuilderWizardDiff.lines(session: session, steps: executedSteps)
        phase = result.completed && reparseReasons.isEmpty ? .preview : .refused
        if phase == .refused {
            reasons = reparseReasons + result.outcomes.compactMap { if case .refused(_, let reason) = $0 { reason } else { nil } }
            appendLog("No timeline changes applied." + (persistentEffects.isEmpty ? "" : " Library work already saved remains."))
        }
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
                                      request: runRequest, provider: provenance.provider, model: provenance.model, durationSeconds: duration,
                                      status: .discarded, baselineRevision: session.baselineRevision)
        let alreadyFailed = agentAuditSaved && session.state == .failed
        agentRun?.cancel()
        session.discard()
        pendingSteps = nil
        phase = .discarded
        appendLog("No timeline changes applied." + (persistentEffects.isEmpty ? "" : " Library work already saved remains."))
        do {
            if let database, session.timelineID != nil, !alreadyFailed { try await database.recordBuilderRun(record) }
        } catch { failure = .persistence(error.localizedDescription); appendLog(failureMessage ?? "Could not record discard.") }
    }

    func cancelRun() {
        guard phase == .running else { return }
        agentRun?.cancel()
        task?.cancel()
        appendLog("Cancelling and waiting for Library work to stop…")
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        generation += 1
        agentRun?.cancel()
        let draining = task
        draining?.cancel()
        task = nil
        if phase == .running { phase = .discarded }
        Task {
            await draining?.value
            await discard()
        }
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

    private func executeAgent(session: BuilderScriptSession, confirmed: [BuilderCommand], token: Int) async {
        let budget = BuilderRunBudget(runLimits)
        let library = session.library
        let language = store.settings.transcribeLanguage
        let profileGeneration = store.profileGeneration
        let tools = BuilderTools(session: session, budget: budget, confirmedPrerequisites: confirmed,
            ensure: { [self] steps in
                await session.run(steps, prerequisites: prerequisites, confirmed: true,
                    refreshLibrary: { [database] in
                        guard let database else { throw ApplyFailure.identityChanged }
                        return try await library.refreshed(database: database, language: language)
                    }, identityMatches: { [self] in identityMatches && !dismissed && token == generation },
                    onPrerequisite: { [self] _, _, report in
                        persistentEffects += report.effects
                    })
            })
        let run: BuilderAgentRun
        if let agentExecutor { run = BuilderAgentRun(provider: runProvider, model: runModel, tools: tools, executor: agentExecutor) }
        else { run = BuilderAgentRun(provider: runProvider, model: runModel, tools: tools) }
        agentRun = run
        run.endpoint.onEvent = { [weak self] event in
            guard let self, !self.dismissed, token == self.generation else { return }
            self.agentEvents.append(event)
        }
        run.onProgress = { [weak self] text in
            guard let self, !self.dismissed, token == self.generation else { return }
            self.appendLog(text)
        }
        if let executable = ProcessRunner.locate(runBinary ?? runProvider.rawValue) {
            await run.run(request: runRequest, executable: executable,
                          parentEnvironment: ProcessRunner.subprocessEnvironment(overrides: nil))
        } else {
            run.failBeforeLaunch("The selected agent CLI is not installed.")
        }
        agentProvenance = run.provenance
        duration = run.provenance.duration ?? 0
        agentSummary = run.finalResponse
        persistentEffects = session.prerequisiteEffects
        // Preserve captured database ownership even after the user switches timelines.
        do {
            if let database, let timelineID = session.timelineID {
                let record = BuilderRunRecord(runUUID: session.runUUID, timelineID: timelineID, request: runRequest,
                    createdAt: (run.provenance.at ?? .now).ISO8601Format(), provider: run.provenance.provider, model: run.provenance.model, durationSeconds: duration,
                    status: session.state == .completed ? .completed : .failed, baselineRevision: session.baselineRevision,
                    summary: run.finalResponse,
                    libraryEffectsJSON: String(decoding: try JSONEncoder().encode(session.prerequisiteEffects), as: UTF8.self),
                    eventsJSON: String(decoding: try JSONEncoder().encode(run.endpoint.events), as: UTF8.self))
                try await database.recordBuilderRun(record)
                agentAuditSaved = true
            }
        } catch { failure = .persistence(error.localizedDescription) }
        agentRun = nil
        if identityMatches, let database, !persistentEffects.isEmpty {
            do {
                let snapshot = try await database.fetchLibrarySnapshot(projectID: projectID)
                if identityMatches { store.applyLibrarySnapshot(snapshot, generation: profileGeneration) }
            } catch { appendLog("Saved Library work could not be refreshed.") }
        }
        guard !dismissed, token == generation else { return }
        diff = session.diff()
        diffLines = BuilderWizardDiff.lines(session: session, steps: tools.executedSteps)
        phase = session.state == .completed && failure == nil ? .preview : .refused
        if let error = run.terminalError { reasons = [error] }
        else if session.state == .failed {
            reasons = session.result?.outcomes.compactMap { if case .refused(_, let reason) = $0 { reason } else { nil } } ?? []
        }
        appendLog("Agent stopped. Review the structured outcomes and complete diff before Apply.")
    }

    private var provenance: AIProvenance {
        agentProvenance ?? AIProvenance(provider: "local", technique: "builder-request-parser", duration: duration)
    }
    private func appendLog(_ line: String) {
        // Cap individual metadata as well as total retained UI log bytes.
        log.append(String(line.prefix(2000)))
        while log.reduce(0, { $0 + $1.utf8.count }) > 64 * 1024 { log.removeFirst() }
    }
    private func milliseconds(since start: Date) -> String { "\(Int(Date.now.timeIntervalSince(start) * 1000)) ms" }
}
