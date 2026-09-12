import Foundation
import MCP

/// Transport-independent admission, terminal policy and complete callback ownership.
@MainActor
final class BuilderRunCoordinator {
    let tools: BuilderTools
    var identityMatches: @MainActor () -> Bool = { true }
    private(set) var events: [BuilderRunEvent] = []
    var onEvent: (@MainActor (BuilderRunEvent) -> Void)?
    var currentRequestID: String?
    private(set) var stopping = false
    private var active: Task<Data, any Error>?
    private var activeHandler: Task<CallTool.Result, Never>?
    private var terminalRecorded = false
    var redactor = BuilderRunRedactor()
    private(set) var terminalReason: String?
    private var fingerprints: [String: (Data, Data)] = [:]
    private var cachedBytes = 0
    private var consoleBytes = 0
    var hasActiveCall: Bool { activeHandler != nil }

    init(tools: BuilderTools) { self.tools = tools }

    func cached(id: String, fingerprint: Data) throws -> Data? {
        guard !stopping else { throw ScriptError.invalid("Run closed.") }
        guard identityMatches(), tools.session.identityIsCurrent else {
            terminate("Timeline identity or revision changed.")
            throw ScriptError.invalid("Timeline identity or revision changed.")
        }
        if let prior = fingerprints[id] {
            guard prior.0 == fingerprint else {
                terminate("Request ID reused with different arguments.")
                throw ScriptError.invalid("Request ID reused with different arguments.")
            }
            return prior.1
        }
        guard fingerprints.count < 256, cachedBytes + fingerprint.count <= 16 * 1024 * 1024 else {
            terminate("Request deduplication budget exhausted.")
            throw BuilderBudgetExceeded(reason: "Request budget exhausted.")
        }
        return nil
    }

    func cache(id: String, fingerprint: Data, response: Data) {
        guard fingerprints[id] == nil else { return }
        let size = fingerprint.count + response.count
        guard cachedBytes + size <= 16 * 1024 * 1024 else {
            terminate("Request deduplication budget exhausted.")
            return
        }
        fingerprints[id] = (fingerprint, response)
        cachedBytes += size
    }

    func console(level: String, text: String, bytes: Int) throws {
        guard !stopping, !terminalRecorded else { throw ScriptError.invalid("Run closed.") }
        consoleBytes += bytes
        guard consoleBytes <= 64 * 1024 else {
            terminate("Console exceeds 64 KiB.")
            throw BuilderBudgetExceeded(reason: "Console exceeds 64 KiB.")
        }
        let event = BuilderRunEvent(runID: tools.session.runUUID, sequence: events.count + 1,
            toolName: "console." + (["log", "warn", "error"].contains(level) ? level : "log"),
            outcome: .completed, message: redactor.text(text, limit: 64 * 1024))
        do { try tools.budget.chargeLog(JSONEncoder().encode(event).count) }
        catch { terminate("Script log budget exhausted."); throw error }
        events.append(event)
        onEvent?(event)
    }

    func revoke() { stopping = true; active?.cancel(); activeHandler?.cancel() }
    func terminate(_ reason: String) {
        guard tools.session.state != .completed, tools.session.state != .discarded else { return }
        terminalReason = terminalReason ?? reason
        revoke()
        if !hasActiveCall { _ = tools.session.fail(reason) }
    }
    func drain() async { _ = await activeHandler?.value }
    func finish(success: Bool, message: String?, duration: Double, freeze: Bool = true) async {
        revoke()
        await drain()
        if !success { terminate(message ?? "Script failed.") }
        if !identityMatches() || !tools.session.identityIsCurrent { terminate("Timeline identity or revision changed.") }
        if tools.mode == .find, tools.session.sceneReport == nil { terminate("report_scenes is required.") }
        finishEvent(outcome: terminalReason == nil && tools.session.state == .ready ? .completed : .failed,
                    message: terminalReason ?? message, duration: duration)
        if terminalReason == nil, freeze { _ = tools.session.freeze() }
    }

    func call(name: String, arguments: [String: Value]) async -> CallTool.Result {
        guard !Task.isCancelled else {
            terminate("Run cancelled.")
            return refusal("Run cancelled.")
        }
        guard !stopping, tools.session.state == .ready, activeHandler == nil else { return refusal("Run closed or busy.") }
        // Own the entire callback, including result encoding and audit writes.
        // Draining just tools.call would allow a late encoding/log failure to
        // invalidate a session after freeze.
        let handler = Task { await performCall(name: name, arguments: arguments) }
        activeHandler = handler
        let result = await withTaskCancellationHandler {
            await handler.value
        } onCancel: { handler.cancel() }
        activeHandler = nil
        if let terminalReason { _ = tools.session.fail(terminalReason) }
        return result
    }

    private func performCall(name: String, arguments: [String: Value]) async -> CallTool.Result {
        guard !Task.isCancelled else {
            terminate("Run cancelled.")
            return refusal("Run cancelled.")
        }
        guard !stopping, active == nil else { return refusal("Run closed or busy.") }
        guard identityMatches(), tools.session.identityIsCurrent else {
            terminate("Timeline identity or revision changed.")
            return refusal("Timeline identity or revision changed.")
        }
        do { try tools.budget.chargeLog(2048) }
        catch {
            terminate("Agent log budget exhausted.")
            return refusal("Agent log budget exhausted.")
        }
        let started = Date.now
        let requestID = currentRequestID
        let argumentBytes = (try? JSONEncoder().encode(arguments).count) ?? 0
        let task = Task { try await tools.call(name: name, arguments: arguments) }
        active = task
        var data: Data
        var outcome: BuilderRunEvent.Outcome = .completed
        var detail: String?
        do {
            data = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            let result = try? JSONDecoder().decode(BuilderScriptResult.self, from: data)
            if tools.session.state == .failed || (name == "run_script" && result?.completed == false) {
                outcome = .refused
                detail = result?.outcomes.compactMap {
                    if case .refused(_, let reason) = $0 { reason } else { nil }
                }.joined(separator: "; ")
            }
        } catch {
            outcome = error is CancellationError ? .cancelled : .refused
            let reason = redactor.text(error.localizedDescription)
            detail = reason
            // Read-only errors and refused script lists are retryable.
            // Budget failures and cancellation still terminate the run.
            if (!BuilderTools.isReadOnly(name) && name != "run_script") || error is CancellationError || error is BuilderBudgetExceeded {
                terminate(reason)
            }
            data = (try? JSONEncoder().encode(CommandOutcome.refused(code: (error as? BuilderCommandFailure)?.code ?? (error is ScriptError ? "invalid_script" : (error is BuilderBudgetExceeded ? "limit" : outcome.rawValue)), reason: reason))) ?? Data()
        }
        active = nil
        if !identityMatches() || !tools.session.identityIsCurrent {
            terminate("Timeline identity or revision changed.")
            outcome = .refused
            detail = "Timeline identity or revision changed."
            data = (try? JSONEncoder().encode(CommandOutcome.refused(code: "stale_revision", reason: detail ?? ""))) ?? Data()
        }
        if tools.session.state == .failed {
            stopping = true
            terminalReason = terminalReason ?? detail ?? "Tool execution failed."
        }
        // Sanitize string values before encoding so redaction cannot corrupt
        // JSON syntax. Record the actual encoded size and any encoding refusal.
        do {
            let value = try JSONDecoder().decode(Value.self, from: data)
            let safe = try JSONEncoder().encode(sanitize(value))
            guard safe.count <= tools.budget.limits.resultBytes else { throw ScriptError.invalid("Result payload limit.") }
            data = safe
        } catch {
            outcome = .refused
            detail = "Result could not be safely encoded."
            terminate(detail ?? "Result encoding failed.")
            data = (try? JSONEncoder().encode(CommandOutcome.refused(code: "result_limit", reason: "Result could not be safely encoded."))) ?? Data()
        }
        let text = String(decoding: data, as: UTF8.self)
        let event = BuilderRunEvent(runID: tools.session.runUUID, sequence: events.count + 1,
            requestID: requestID.map { redactor.text($0, limit: 128) },
            toolName: tools.definitions.contains(where: { $0.name == name }) ? name : "unavailable_tool",
            sanitizedArguments: redactor.arguments(Array(arguments.keys)), argumentBytes: argumentBytes,
            outcome: outcome, message: detail.map { redactor.text($0, limit: 256) }, resultBytes: data.count, duration: Date.now.timeIntervalSince(started))
        do {
            try tools.budget.chargeLog(max(0, JSONEncoder().encode(event).count - 2048))
            events.append(event)
            onEvent?(event)
        } catch {
            terminate("Agent log budget exhausted.")
            return refusal("Agent log budget exhausted.")
        }
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: outcome != .completed)
    }

    private func sanitize(_ value: Value) -> Value {
        switch value {
        case .string(let text): .string(redactor.text(text, limit: tools.budget.limits.resultBytes))
        case .array(let values): .array(values.map { sanitize($0) })
        case .object(let fields): .object(fields.mapValues { sanitize($0) })
        default: value
        }
    }

    /// A persistence suspension may invalidate a previously successful run.
    /// Both terminal events fit in the reserved audit space; no tool is reopened.
    func auditInvalidated(_ reason: String) {
        guard tools.session.state != .completed, tools.session.state != .discarded else { return }
        terminate(reason)
        guard terminalRecorded, events.last?.outcome == .completed else { return }
        let event = BuilderRunEvent(runID: tools.session.runUUID, sequence: events.count + 1,
            outcome: .failed, message: redactor.text(reason, limit: 256))
        events.append(event)
        onEvent?(event)
    }

    func finishEvent(outcome: BuilderRunEvent.Outcome, message: String?, duration: Double) {
        guard !terminalRecorded else { return }
        terminalRecorded = true
        let event = BuilderRunEvent(runID: tools.session.runUUID, sequence: events.count + 1,
            outcome: outcome, message: message.map { redactor.text($0, limit: 256) }, duration: duration)
        events.append(event)
        onEvent?(event)
    }

    private func refusal(_ reason: String) -> CallTool.Result {
        .init(content: [.text(text: "{\"status\":\"refused\",\"reason\":\"\(reason)\"}", annotations: nil, _meta: nil)], isError: true)
    }

}
