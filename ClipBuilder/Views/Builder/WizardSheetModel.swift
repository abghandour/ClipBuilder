import Foundation
import Observation

/// View-free orchestration. A preview owns its session until a terminal action;
/// request edits cannot relabel the frozen run or change its provenance.
@MainActor @Observable
final class WizardSheetModel {
    enum Phase: Equatable { case idle, awaitingPrerequisites, running, preview, found, unrecognised, refused, applying, applied, discarded }
    let scriptLibrary: ScriptLibraryModel
    private(set) var replayExport = ScriptReplayExport(reason: "Complete a run to save its replay.")
    private(set) var verifyingReplay = false
    @ObservationIgnored private var retainedReplay: ScriptReplayTranscript?
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    @ObservationIgnored private var activeScriptID: UUID?
    var request = ""
    private(set) var examples = BuilderRequestParser.supportedRequests(library: ScriptLibrarySnapshot())
    private var prefillExamples = false
    var provider: BuilderAgentProvider = .local
    private(set) var agentEvents: [BuilderRunEvent] = []
    private(set) var agentSummary = ""
    @ObservationIgnored private var scriptRun: ScriptRunModel?
    @ObservationIgnored private var pendingJavaScript: (source: String, header: ScriptHeader, params: Data)?
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
    private(set) var resultReasons: [Int64: String] = [:]
    @ObservationIgnored private var finding = false
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

    // AppStore owns the live model; avoid retaining that owner back.
    @ObservationIgnored private unowned let store: AppStore
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
         agentExecutor: BuilderAgentRun.Executor? = nil,
         initialRequest: String = "", prefillExamples: Bool = false) {
        request = initialRequest
        self.prefillExamples = prefillExamples
        self.store = store
        self.agentExecutor = agentExecutor
        self.prerequisites = prerequisites ?? store.builderPrerequisites
        database = store.database
        scriptLibrary = ScriptLibraryModel(database: store.database)
        historyStore = history
        profile = store.builder.profileName
        timelineID = store.builder.timelineID
        projectID = store.activeProjectID
        self.history = history.requests(profile: profile)
        // The saved provider choice is honoured only while that provider is enabled.
        if let saved = BuilderAgentProvider(rawValue: store.settings.ai.tasks["builder_agent"] ?? ""),
           saved.disabledReason == nil { provider = saved }
        self.loadLibrary = loadLibrary ?? { [weak store] in
            guard let store else { throw ApplyFailure.identityChanged }
            return try await BuilderWizardLibrary.snapshot(store: store)
        }
    }

    var scriptRevision: Int { store.builder.revision }

    func captureForScript() async throws -> ScriptCapture {
        guard identityMatches, !dismissed else { throw ApplyFailure.identityChanged }
        let revision = store.builder.revision
        let library = try await loadLibrary()
        guard identityMatches, library.projectID == projectID, !dismissed else { throw ApplyFailure.identityChanged }
        guard revision == store.builder.revision else { throw ApplyFailure.staleRevision }
        return ScriptCapture(model: store.builder, library: library)
    }

    func runLibraryScript() throws {
        guard let capture = scriptLibrary.capture, capture.matches(store.builder), identityMatches else {
            scriptLibrary.invalidate()
            throw ApplyFailure.staleRevision
        }
        let params = try scriptLibrary.parameters()
        activeScriptID = scriptLibrary.editingID
        beginJavaScript(source: scriptLibrary.source, params: params, expectedCapture: capture)
    }

    private func resetReplay() {
        replayTask?.cancel(); replayTask = nil; retainedReplay = nil
        verifyingReplay = false
        replayExport = .init(reason: "Complete a run to save its replay.")
    }

    private func retainReplay(_ session: BuilderScriptSession) {
        guard session.state == .completed, !finding else { return }
        let transcript = session.replay
        retainedReplay = transcript
        let token = generation
        let name = runRequest
        replayTask?.cancel()
        verifyingReplay = true
        replayExport = .init(reason: "Checking replay equivalence…")
        replayTask = Task { [weak self] in
            let result = await ScriptReplayExporter.verify(transcript, name: name)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.replayExport = result
            self.verifyingReplay = false
            self.replayTask = nil
        }
    }

    func saveReplay() async {
        guard let source = replayExport.source, let database, identityMatches else { return }
        do {
            let record = try await database.saveBuilderScript(source: source)
            scriptLibrary.selectedID = record.id
            await scriptLibrary.refresh()
        } catch { scriptLibrary.fail(error) }
    }

    func refreshExamples() async {
        do {
            let library = try await loadLibrary()
            guard !dismissed, identityMatches else { return }
            examples = BuilderRequestParser.supportedRequests(library: library)
            if prefillExamples, phase == .idle, !busy, request.isEmpty { request = Self.prefill(from: examples) }
            prefillExamples = false
        } catch {
            // Generic examples remain useful when the Library cannot be read.
            if !dismissed, identityMatches, prefillExamples, phase == .idle, !busy, request.isEmpty {
                request = Self.prefill(from: examples)
            }
            prefillExamples = false
        }
    }

    /// One runnable request, never a placeholder and never several lines: the
    /// parser accepts a single request, so a multi-line prefill could only fail.
    static func prefill(from examples: [String]) -> String {
        examples.first { !$0.contains("<") } ?? ""
    }

    /// The picker creates exactly the same frozen preview as a local request.
    /// It never executes Apply on behalf of the user.
    func previewFoundAddition(_ found: BuilderWizardPickerRequest, sceneID: Int64,
                              at: Double, track: Int, duration: Double,
                              sourceStart: Double, coverAll: Bool) {
        guard phase == .idle, !busy, !dismissed else { return }
        request = found.request
        runRequest = "Add found scene as B-roll: " + found.request
        do {
            try found.validate(store: store)
            guard found.scenes.contains(where: { $0.id == sceneID }) else {
                throw ScriptError.invalid("This scene was not in the find results.")
            }
            execute([.init(.addCutaway(scene: sceneID, at: at, track: track, duration: duration,
                                      sourceStart: sourceStart, coverAll: coverAll))], library: found.context.library)
        } catch {
            failure = error as? ApplyFailure
            reasons = [failureMessage ?? error.localizedDescription]
            phase = .refused
        }
    }

    var busy: Bool { isStarting || phase == .running || phase == .applying }
    var latestLogLine: String? { log.last }
    var hasStatus: Bool { phase != .idle || !log.isEmpty }
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

    enum CopyKind { case log, toolOutcomes, everything }

    var statusText: String {
        if let failureMessage { return failureMessage }
        switch phase {
        case .idle: return "Describe the edit you want to preview."
        case .awaitingPrerequisites: return "Confirm Library work before running."
        case .running: return finding ? "Searching the Library…" : "Running — building your preview…"
        case .preview: return "Ready to apply — \(diff?.changes.count ?? 0) changes"
        case .found: return "Found \(results.count) matching scenes"
        case .unrecognised: return reasons.first ?? "Request not recognised. Try a supported request."
        case .refused: return reasons.first ?? "Run refused. No timeline changes applied."
        case .applying: return "Applying timeline changes…"
        case .applied: return "Changes applied"
        case .discarded: return "Preview discarded"
        }
    }

    var explanationText: AttributedString {
        (try? AttributedString(markdown: agentSummary,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(agentSummary)
    }

    /// Pure export; clipboard access belongs to the view. Use the captured request
    /// so editing the field cannot relabel the results of the previous run.
    func copyText(kind: CopyKind) -> String {
        let outcomes = agentEvents.map { event in
            "\(event.sequence). \(event.toolName ?? "run") · \(event.outcome.rawValue)"
                + (event.message.map { " · " + $0 } ?? "")
                + " · \(event.argumentBytes) B in / \(event.resultBytes) B out · \(Int(event.duration * 1000)) ms"
        }.joined(separator: "\n")
        switch kind {
        case .log: return log.joined(separator: "\n")
        case .toolOutcomes: return outcomes
        case .everything:
            return [
                "Request\n" + (runRequest.isEmpty ? request : runRequest),
                "Status\n" + ([statusText] + reasons.filter { $0 != statusText }).joined(separator: "\n"),
                "Timeline changes\n" + diffLines.joined(separator: "\n"),
                "Library work\n" + (prerequisiteDisclosures + persistentEffects.map { "Video \($0.videoID): \($0.summary)" }).joined(separator: "\n"),
                "Tool outcomes\n" + outcomes,
                "Agent explanation\n" + String(explanationText.characters),
                "Run log\n" + log.joined(separator: "\n")
            ].joined(separator: "\n\n")
        }
    }

    /// Clear only the bounded presentation log; audit events and saved runs survive.
    func clearLog() { log.removeAll() }

    func saveProviderPreference() {
        guard !busy, phase != .awaitingPrerequisites, provider.disabledReason == nil else { return }
        store.settings.ai.tasks["builder_agent"] = provider.rawValue
        store.saveSettings()
    }

    func refuseJavaScriptFile(_ error: any Error) {
        reasons = [error.localizedDescription]
        phase = .refused
        appendLog(error.localizedDescription)
    }

    /// Shared debug/file and saved-library entry point.
    func beginJavaScript(source: String, params: Data = Data("{}".utf8), expectedCapture: ScriptCapture? = nil) {
        guard task == nil, !busy else { return }
        if expectedCapture == nil { activeScriptID = nil }
        task = Task { await previewJavaScript(source: source, params: params, expectedCapture: expectedCapture); task = nil }
    }

    func previewJavaScript(source: String, params: Data = Data("{}".utf8), expectedCapture: ScriptCapture? = nil) async {
        guard !busy, !dismissed else { return }
        await discard()
        guard identityMatches, !dismissed else { failure = .identityChanged; return }
        if let expectedCapture, !expectedCapture.matches(store.builder) {
            failure = .staleRevision; phase = .refused; scriptLibrary.invalidate(); return
        }
        generation += 1
        resetReplay()
        let token = generation
        let revision = store.builder.revision
        phase = .running
        reasons = []; failure = nil; agentEvents = []; agentSummary = ""; log = []
        agentAuditSaved = false; agentProvenance = nil; persistentEffects = []; prerequisiteDisclosures = []
        pendingJavaScript = nil; pendingSteps = nil; pendingAgent = false
        diff = nil; diffLines = []; results = []; resultReasons = [:]; findContext = nil; finding = false
        do {
            let header = try ScriptHeader.parse(source)
            let library: ScriptLibrarySnapshot
            if let expectedCapture { library = expectedCapture.library }
            else { library = try await loadLibrary() }
            try Task.checkCancellation()
            guard identityMatches, token == generation, !dismissed, library.projectID == projectID else {
                throw ApplyFailure.identityChanged
            }
            guard store.builder.revision == revision else { throw ApplyFailure.staleRevision }
            let capture = ScriptCapture(model: store.builder, library: library)
            let (resolved, commands) = try header.resolve(params, capture: capture)
            request = header.name
            runRequest = header.name
            finding = header.mode == "find"
            if finding {
                findContext = ParserContext(library: library, model: store.builder)
                findRevision = revision
            }
            let session = BuilderScriptSession(live: store.builder, library: library, hydration: store.builderLibraryHydration)
            self.session = session
            if !commands.isEmpty {
                pendingJavaScript = (source, header, resolved)
                pendingSteps = commands.map { BuilderScriptStep($0) }
                prerequisiteDisclosures = commands.compactMap { $0.prerequisite.map { "Video \($0.video): \($0.kind.disclosure)" } }
                phase = .awaitingPrerequisites
            } else {
                await executeJavaScript(source: source, header: header, params: resolved, session: session, confirmed: [], token: token)
            }
        } catch {
            failure = error as? ApplyFailure
            reasons = [failureMessage ?? error.localizedDescription]
            phase = .refused
        }
    }

    private func executeJavaScript(source: String, header: ScriptHeader, params: Data,
                                   session: BuilderScriptSession, confirmed: [BuilderCommand], token: Int) async {
        let library = session.library
        let language = store.settings.transcribeLanguage
        let profileGeneration = store.profileGeneration
        let run = ScriptRunModel(session: session, header: header, params: params, confirmed: confirmed,
            ensure: { [self] steps in
                await session.run(steps, prerequisites: prerequisites, confirmed: true,
                    refreshLibrary: { [database] in
                        guard let database else { throw ApplyFailure.identityChanged }
                        return try await library.refreshed(database: database, language: language)
                    }, identityMatches: { [self] in identityMatches && !dismissed && token == generation })
            }, identityMatches: { [self] in identityMatches && !dismissed && token == generation })
        scriptRun = run
        run.onLog = { [weak self] text in self?.appendLog(text) }
        run.coordinator.onEvent = { [weak self] event in self?.agentEvents.append(event) }
        do { runRequest = try run.requestText() }
        catch { reasons = [error.localizedDescription]; phase = .refused; scriptRun = nil; session.discard(); self.session = nil; return }
        await run.run(source: source, record: { [database] record in
            guard let database else { throw ApplyFailure.persistence("Captured database is unavailable.") }
            try await database.recordBuilderRun(record)
        })
        duration = run.duration
        agentProvenance = AIProvenance(provider: "script", model: header.name, duration: duration)
        agentSummary = run.summary
        agentAuditSaved = run.diagnostic?.code != "persistence"
        persistentEffects = session.prerequisiteEffects
        scriptRun = nil
        if identityMatches, let database, !persistentEffects.isEmpty {
            do {
                let snapshot = try await database.fetchLibrarySnapshot(projectID: projectID)
                if identityMatches { store.applyLibrarySnapshot(snapshot, generation: profileGeneration) }
            } catch { appendLog("Saved Library work could not be refreshed.") }
        }
        guard !dismissed, token == generation else { return }
        diff = session.diff()
        diffLines = BuilderWizardDiff.lines(session: session, steps: run.coordinator.tools.executedSteps)
        phase = session.state == .completed && run.diagnostic == nil ? .preview : .refused
        if phase == .preview { retainReplay(session) }
        if let id = activeScriptID, let database {
            do { try await database.markBuilderScriptRun(id: id, status: phase == .preview ? .completed : .failed) }
            catch { scriptLibrary.fail(error) }
            await scriptLibrary.refresh()
        }
        if let diagnostic = run.diagnostic {
            reasons = [diagnostic.reason + (diagnostic.line.map { " (line \($0))" } ?? "")]
            appendLog(reasons[0])
        }
        if finding, phase == .preview, let report = session.sceneReport {
            results = report.scenes.compactMap { entry in session.library.scenes.first { $0.id == entry.id } }
            resultReasons = Dictionary(uniqueKeysWithValues: report.scenes.map { ($0.id, $0.reason) })
            phase = .found
            self.session = nil
            session.discard()
        } else if phase == .refused {
            session.discard()
            self.session = nil
        }
    }

    func beginRun() {
        guard task == nil, !busy else { return }
        task = Task { await run(); task = nil }
    }

    func run(program suppliedProgram: BuilderProgram? = nil) async {
        guard !busy, !dismissed else { return }
        isStarting = true
        activeScriptID = nil
        defer { isStarting = false }
        await discard()
        guard !dismissed, identityMatches else { failure = .identityChanged; return }
        generation += 1
        resetReplay()
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
        log = []
        appendLog("Collecting the current Library snapshot…")
        reasons = []; failure = nil; diff = nil; diffLines = []; results = []; resultReasons = [:]; findContext = nil; finding = false
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
            // Recognised finds always stay local, regardless of the provider picker.
            // Assisted finds take their own read-only agent path below.
            let isFind: Bool
            switch program {
            case .find, .assistedFind: isFind = true
            default: isFind = false
            }
            if runProvider != .local, suppliedProgram == nil, !isFind {
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
            case .assistedFind(let request, let unresolved):
                finding = true
                guard runProvider != .local else {
                    reasons = ["Could not resolve: " + unresolved.map { "'" + $0 + "'" }.joined(separator: ", ")
                        + "; choose Claude to let the assistant search"]
                    phase = .refused
                    appendLog(reasons[0])
                    return
                }
                runRequest = request
                findContext = context
                findRevision = revision
                let session = BuilderScriptSession(live: store.builder, library: library, hydration: store.builderLibraryHydration)
                self.session = session
                await executeAgent(session: session, confirmed: [], token: token, mode: .find)
            case .find(let filter, _):
                let matches = Array(BuilderSceneSearch.ranked(filter, library: library).prefix(BuilderSceneSearch.limit))
                results = matches.map(\.scene)
                resultReasons = Dictionary(matches.map { ($0.scene.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
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
        if phase == .preview { retainReplay(session) }
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
        if let pending = pendingJavaScript {
            pendingJavaScript = nil
            await executeJavaScript(source: pending.source, header: pending.header, params: pending.params,
                                    session: session, confirmed: steps.map(\.command), token: generation)
            return
        }
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
            case .find, .assistedFind: reparseReasons = ["The refreshed request produced a find instead of timeline edits."]
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
        if phase == .preview { retainReplay(session) }
        if phase == .refused {
            reasons = reparseReasons + result.outcomes.compactMap { if case .refused(_, let reason) = $0 { reason } else { nil } }
            appendLog("No timeline changes applied." + (persistentEffects.isEmpty ? "" : " Library work already saved remains."))
        }
    }

    func addAllAsBRoll() { previewBRoll(results) }

    func addAsBRoll(sceneID: Int64) {
        guard let scene = results.first(where: { $0.id == sceneID }) else { return }
        previewBRoll([scene])
    }

    private func previewBRoll(_ scenes: [SceneRecord]) {
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
        // Search was already audited. This explicit edit has local provenance
        // and a fresh session/run UUID, just like a deterministic addition.
        agentProvenance = nil
        agentAuditSaved = false
        finding = false
        let steps = scenes.map { scene in
            defer { at += scene.duration }
            return BuilderScriptStep(.addCutaway(scene: scene.id, at: at, track: store.builder.focusedTrack ?? 0,
                                                 duration: scene.duration, coverAll: false))
        }
        execute(steps, library: context.library)
    }

    func pickerRequest(sceneID: Int64? = nil) -> BuilderWizardPickerRequest? {
        guard phase == .found, identityMatches, let context = findContext, let revision = findRevision else { return nil }
        let scenes = sceneID.map { id in results.filter { $0.id == id } } ?? results
        guard !scenes.isEmpty else { return nil }
        return .init(request: runRequest, scenes: scenes, context: context, revision: revision,
                     profile: profile, timelineID: timelineID, database: database,
                     time: store.builder.playhead, track: store.builder.focusedTrack ?? 0)
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
            if let id = activeScriptID, let database {
                do { try await database.markBuilderScriptRun(id: id, status: .applied); await scriptLibrary.refresh() }
                catch { scriptLibrary.fail(error) }
            }
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
        let drainingScript = scriptRun
        drainingScript?.cancel()
        await drainingScript?.drain()
        let record = BuilderRunRecord(runUUID: session.runUUID, timelineID: session.timelineID ?? 0,
                                      request: runRequest, provider: provenance.provider, model: provenance.model, durationSeconds: duration,
                                      status: .discarded, baselineRevision: session.baselineRevision)
        let alreadyFailed = agentAuditSaved && (session.state == .failed || finding)
        scriptRun?.cancel()
        agentRun?.cancel()
        session.discard()
        pendingJavaScript = nil
        pendingSteps = nil
        phase = .discarded
        appendLog("No timeline changes applied." + (persistentEffects.isEmpty ? "" : " Library work already saved remains."))
        do {
            if let database, session.timelineID != nil, !alreadyFailed { try await database.recordBuilderRun(record) }
        } catch { failure = .persistence(error.localizedDescription); appendLog(failureMessage ?? "Could not record discard.") }
    }

    func cancelRun() {
        guard phase == .running else { return }
        scriptRun?.cancel()
        agentRun?.cancel()
        task?.cancel()
        appendLog("Cancelling and waiting for Library work to stop…")
    }

    func dismiss() {
        if store.builderWizard === self { store.builderWizard = nil }
        guard !dismissed else { return }
        dismissed = true
        replayTask?.cancel()
        scriptLibrary.invalidate()
        generation += 1
        scriptRun?.cancel()
        agentRun?.cancel()
        let draining = task
        draining?.cancel()
        task = nil
        if phase == .running { phase = .discarded }
        Task { [self, store] in
            // A dismissed model may outlive its window while work drains.
            defer { withExtendedLifetime(store) {} }
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

    private func executeAgent(session: BuilderScriptSession, confirmed: [BuilderCommand], token: Int, mode: BuilderTools.Mode = .edit) async {
        let budget = BuilderRunBudget(runLimits)
        let library = session.library
        let language = store.settings.transcribeLanguage
        let profileGeneration = store.profileGeneration
        let tools = BuilderTools(session: session, budget: budget, mode: mode, confirmedPrerequisites: confirmed,
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
        run.endpoint.coordinator.identityMatches = { [self] in identityMatches && !dismissed && token == generation }
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
        agentSummary = mode == .find ? (session.sceneReport?.summary ?? "") : run.finalResponse
        persistentEffects = session.prerequisiteEffects
        // Preserve captured database ownership even after the user switches timelines.
        do {
            if let database, let timelineID = session.timelineID {
                let record = BuilderRunRecord(runUUID: session.runUUID, timelineID: timelineID, request: runRequest,
                    createdAt: (run.provenance.at ?? .now).ISO8601Format(), provider: run.provenance.provider, model: run.provenance.model, durationSeconds: duration,
                    status: session.state == .completed ? .completed : .failed, baselineRevision: session.baselineRevision,
                    summary: agentSummary,
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
        if phase == .preview { retainReplay(session) }
        if phase == .refused {
            // The terminal error can be generic; put the actual tool refusals first.
            let refusedEvents = agentEvents.filter { $0.toolName != nil && $0.outcome != .completed }
            // A corrected query may precede a fatal mutation refusal. Lead with
            // the mutation's reason so the banner describes what ended the run.
            let terminalTools = refusedEvents.filter { !BuilderTools.isReadOnly($0.toolName ?? "") }
            let readOnlyTools = refusedEvents.filter { BuilderTools.isReadOnly($0.toolName ?? "") }
            let toolReasons: [String] = (terminalTools + readOnlyTools).compactMap { $0.message }
            let sessionReasons: [String] = session.result?.outcomes.compactMap { outcome -> String? in
                if case .refused(_, let reason) = outcome { return reason }
                return nil
            } ?? []
            let terminal: [String] = run.terminalError.map { [$0] } ?? []
            let ordered: [String] = toolReasons + sessionReasons + terminal
            reasons = []
            for reason in ordered where !reason.isEmpty && !reasons.contains(reason) { reasons.append(reason) }
        }
        if mode == .find {
            if phase != .refused, let report = session.sceneReport {
                let byID = Dictionary(session.library.scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let entries = Array(report.scenes.prefix(BuilderSceneSearch.limit))
                results = entries.compactMap { byID[$0.id] }
                resultReasons = Dictionary(entries.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
                phase = .found
            }
            diff = nil; diffLines = []
            // A completed search has no Apply/discard transaction. Release its
            // hydration hold after auditing; later additions create a new session.
            if self.session === session { self.session = nil }
            session.discard()
            appendLog("Search finished. No timeline changes applied.")
        } else {
            appendLog("Agent stopped. Review the structured outcomes and complete diff before Apply.")
        }
    }

    private var provenance: AIProvenance {
        agentProvenance ?? AIProvenance(provider: "local", technique: "builder-request-parser", duration: duration)
    }
    func appendLog(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.recordUnifiedLog(channel: "builder-wizard", text: line)
        // Cap individual metadata as well as total retained UI log bytes.
        log += line.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { String($0.prefix(2000)) }
        while log.reduce(0, { $0 + $1.utf8.count }) > 64 * 1024 { log.removeFirst() }
    }
    private func milliseconds(since start: Date) -> String { "\(Int(Date.now.timeIntervalSince(start) * 1000)) ms" }
}
