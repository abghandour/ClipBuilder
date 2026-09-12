import Foundation
import MCP

/// Reusable S1 execution entry point. Wizard owns manual Apply/Discard and the
/// hydration hold; this object owns execution until every callback has drained.
@MainActor
final class ScriptRunModel {
    let coordinator: BuilderRunCoordinator
    let engine: ScriptEngine
    let header: ScriptHeader
    let params: Data
    private(set) var diagnostic: ScriptDiagnostic?
    private(set) var summary = ""
    private(set) var duration: Double = 0
    private var nextID = 0
    private var attempted = false
    private var job: Task<Void, Never>?
    var onLog: (@MainActor (String) -> Void)?

    init(session: BuilderScriptSession, header: ScriptHeader, params: Data,
         confirmed: [BuilderCommand] = [], seconds: Double = 10,
         ensure: (@MainActor ([BuilderScriptStep]) async -> BuilderScriptResult)? = nil,
         identityMatches: @escaping @MainActor () -> Bool = { true }) {
        self.header = header; self.params = params
        engine = ScriptEngine(seconds: seconds)
        let budget = BuilderRunBudget(BuilderAgentLimits())
        budget.scriptClock = engine.control
        let tools = BuilderTools(session: session, budget: budget, mode: header.mode == "find" ? .find : .edit,
                                 confirmedPrerequisites: confirmed, ensure: ensure)
        coordinator = BuilderRunCoordinator(tools: tools)
        coordinator.identityMatches = identityMatches
    }

    func cancel() {
        engine.cancel()
        coordinator.revoke()
    }

    /// Persistence is injected only for production runs. Validation has no sink.
    func drain() async { await job?.value }

    func run(source: String, record: (@MainActor (BuilderRunRecord) async throws -> Void)? = nil) async {
        guard job == nil, !attempted else { return }
        let task = Task { await perform(source: source, record: record) }
        job = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { [engine] in engine.cancel(); task.cancel() }
        job = nil
    }

    private func perform(source: String, record: (@MainActor (BuilderRunRecord) async throws -> Void)? = nil) async {
        guard !attempted else { return }
        attempted = true
        let started = ContinuousClock.now
        do {
            guard params.count <= 64 * 1024 else { throw ScriptError.invalid("Parameters exceed 64 KiB.") }
            let bootstrap = try ScriptBridge.bootstrap(params: params, name: header.name, mode: header.mode, tools: coordinator.tools)
            let result = await engine.evaluate(source: source, bootstrap: bootstrap) { [self] name, data in
                await call(name: name, data: data)
            }
            diagnostic = result.diagnostic
            if let data = result.summary {
                let safe = try JSONDecoder().decode(ScriptValue.self, from: data)
                if case .object(let fields) = safe, case .string(let text) = fields["summary"] {
                    summary = BuilderRunRedactor().text(text, limit: 64 * 1024)
                } else { summary = BuilderRunRedactor().text(String(decoding: data, as: UTF8.self), limit: 64 * 1024) }
            }
        } catch {
            diagnostic = .init(code: "invalid_script", reason: error.localizedDescription)
        }
        duration = started.duration(to: .now).seconds
        await coordinator.finish(success: diagnostic == nil, message: diagnostic?.reason, duration: duration, freeze: false)
        let session = coordinator.tools.session
        if diagnostic == nil, session.state != .ready {
            diagnostic = .init(code: "invalid_script", reason: coordinator.terminalReason ?? "Run failed.")
        }
        var savedRecord: BuilderRunRecord?
        do {
            if let record, let timelineID = session.timelineID {
                let request = try requestText()
                let audit = BuilderRunRecord(runUUID: session.runUUID, timelineID: timelineID,
                    request: request, provider: "script", model: BuilderRunRedactor().text(header.name.isEmpty ? "ad hoc" : header.name, limit: 256),
                    durationSeconds: duration, status: diagnostic == nil ? .completed : .failed,
                    baselineRevision: session.baselineRevision, summary: summary,
                    libraryEffectsJSON: String(decoding: try JSONEncoder().encode(session.prerequisiteEffects), as: UTF8.self),
                    eventsJSON: String(decoding: try JSONEncoder().encode(coordinator.events), as: UTF8.self))
                try await record(audit)
                savedRecord = audit
            }
            guard coordinator.identityMatches(), session.identityIsCurrent else { throw ApplyFailure.identityChanged }
            if diagnostic == nil { _ = session.freeze() }
        } catch {
            diagnostic = .init(code: "persistence", reason: error.localizedDescription)
            coordinator.auditInvalidated(error.localizedDescription)
            // An identity switch while the audit write was suspended invalidates
            // the already-saved completed row in its original database.
            if var audit = savedRecord, audit.status == .completed, let record {
                audit.status = .failed
                audit.summary = BuilderRunRedactor().text(error.localizedDescription)
                do {
                    audit.eventsJSON = String(decoding: try JSONEncoder().encode(coordinator.events), as: UTF8.self)
                    try await record(audit)
                }
                catch { diagnostic = .init(code: "persistence", reason: "Could not record invalidation: " + error.localizedDescription) }
            }
        }
    }

    func requestText() throws -> String {
        let redactor = BuilderRunRedactor()
        let value = try JSONDecoder().decode(ScriptValue.self, from: params)
        let safe = Self.redact(value, redactor: redactor)
        let data = try JSONEncoder().encode(ScriptValue.object([
            "name": .string(redactor.text(header.name, limit: 256)), "params": safe
        ]))
        guard data.count <= 128 * 1024 else { throw ScriptError.invalid("Redacted request exceeds 128 KiB.") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func redact(_ value: ScriptValue, redactor: BuilderRunRedactor) -> ScriptValue {
        switch value {
        case .string(let text): .string(redactor.text(text, limit: 64 * 1024))
        case .array(let values): .array(values.map { redact($0, redactor: redactor) })
        case .object(let values):
            .object(Dictionary(uniqueKeysWithValues: values.map { key, value in
                let credential = key.range(of: "(?i)password|token|secret|api.?key|authorization", options: .regularExpression) != nil
                return (key, credential ? .string("[REDACTED]") : redact(value, redactor: redactor))
            }))
        default: value
        }
    }

    private func call(name: String, data: Data) async -> Data {
        guard !Task.isCancelled, engine.control.reason == nil, !coordinator.stopping else {
            coordinator.terminate("Run cancelled or timed out.")
            return ScriptBridge.error(engine.control.reason ?? "cancelled", "Run stopped.")
        }
        do {
            guard coordinator.identityMatches(), coordinator.tools.session.identityIsCurrent else {
                coordinator.terminate("Timeline identity or revision changed.")
                return ScriptBridge.error("stale_revision", "Timeline identity or revision changed.")
            }
            if name == "__terminal" {
                let error = try JSONDecoder().decode(ScriptDiagnostic.self, from: data)
                engine.control.cancel(error.code)
                coordinator.terminate(error.reason)
                return ScriptBridge.error(error.code, error.reason)
            }
            if name == "__console" {
                let fields = try JSONDecoder().decode([String: String].self, from: data)
                let text = BuilderRunRedactor().text(fields["text"] ?? "", limit: 64 * 1024)
                try coordinator.console(level: fields["level"] ?? "log", text: text, bytes: data.count)
                onLog?((fields["level"] ?? "log") + ": " + text)
                return Data("{\"value\":null}".utf8)
            }
            nextID += 1
            let id = "script:\(nextID)"
            coordinator.currentRequestID = id
            let arguments = try JSONDecoder().decode([String: Value].self, from: data)
            let fingerprint = try JSONEncoder().encode(Value.object(["tool": .string(name), "arguments": .object(arguments)]))
            if let cached = try coordinator.cached(id: id, fingerprint: fingerprint) { return cached }
            let result = await coordinator.call(name: name, arguments: arguments)
            let texts = result.content.compactMap { content -> String? in
                if case .text(let text, _, _) = content { return text }
                return nil
            }
            let response = try ScriptBridge.response(Data(texts.joined().utf8))
            guard response.count <= 1024 * 1024 else { throw BuilderBudgetExceeded(reason: "Bridge result exceeds 1 MiB.") }
            coordinator.cache(id: id, fingerprint: fingerprint, response: response)
            if let terminal = coordinator.terminalReason { return ScriptBridge.error("closed", terminal) }
            return response
        } catch {
            coordinator.terminate(error.localizedDescription)
            return ScriptBridge.error(error is BuilderBudgetExceeded ? "limit" : "invalid_script", error.localizedDescription)
        }
    }
}
