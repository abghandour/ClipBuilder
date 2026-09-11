import Foundation

@MainActor
final class BuilderAgentRun {
    typealias Executor = @Sendable (URL, BuilderAgentLaunch, BuilderAgentLimits,
                                   @escaping @Sendable (Data) throws -> Void) async throws -> ProcessResult
    let endpoint: BuilderMCPServer
    let provider: BuilderAgentProvider
    private(set) var provenance: AIProvenance
    private(set) var finalResponse = ""
    private(set) var terminalError: String?
    var onProgress: (@MainActor (String) -> Void)?
    private var process: Task<ProcessResult, any Error>?
    private let executor: Executor
    private var attempted = false
    private var exceededDeadline = false

    init(provider: BuilderAgentProvider, model: String?, tools: BuilderTools,
         executor: @escaping Executor = { executable, launch, limits, consume in
             try await ProcessRunner.runAgent(executable: executable, arguments: launch.arguments,
                 cwd: launch.cwd, environment: launch.environment, timeout: limits.wallSeconds,
                 maximumOutputBytes: limits.outputBytes, stdout: consume)
         }) {
        self.provider = provider
        provenance = AIProvenance(provider: provider.rawValue, model: model, task: "builder_agent", at: .now, technique: "mcp-agent")
        endpoint = BuilderMCPServer(tools: tools)
        self.executor = executor
        endpoint.onStop = { [weak self] in self?.process?.cancel() }
    }

    func run(request: String, executable: URL, parentEnvironment: [String: String]) async {
        guard !attempted else { return }
        attempted = true
        let started = Date.now
        let remaining = max(0, endpoint.tools.budget.limits.wallSeconds
            - endpoint.tools.budget.started.duration(to: .now).seconds)
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self else { return }
            self.exceededDeadline = true
            self.cancel()
            await self.endpoint.shutdown()
        }
        var launch: BuilderAgentLaunch?
        var redactor = BuilderRunRedactor()
        do {
            if let reason = provider.disabledReason { throw ScriptError.invalid(reason) }
            guard provider != .local else { throw ScriptError.invalid("Local parser does not use an agent.") }
            guard request.utf8.count <= endpoint.tools.budget.limits.argumentBytes else { throw ScriptError.invalid("Request too large.") }
            try Task.checkCancellation()
            try await endpoint.start()
            try endpoint.tools.budget.checkTime()
            guard !endpoint.stopping else { throw CancellationError() }
            redactor = BuilderRunRedactor(secrets: [endpoint.token] + parentEnvironment.filter {
                $0.key.contains("KEY") || $0.key.contains("TOKEN") || $0.key.contains("SECRET")
            }.map(\.value))
            let prompt = BuilderAgentPrompt.request(request, model: provenance.model,
                mode: endpoint.tools.mode, disclosures: endpoint.tools.confirmedPrerequisites.compactMap { command in
                    command.prerequisite.map { "Video \($0.video): \($0.kind.disclosure)" }
                })
            let configuration = try BuilderAgentLaunch.make(provider: provider, request: prompt, model: provenance.model,
                endpoint: endpoint.url, token: endpoint.token, parentEnvironment: parentEnvironment, mode: endpoint.tools.mode)
            launch = configuration
            // Total bytes are bounded by ProcessRunner.runAgent maximumOutputBytes
            // and the parser's per-line limit; partial-message bursts must not drop events.
            let (messages, continuation) = AsyncThrowingStream<BuilderAgentMessage, any Error>.makeStream(bufferingPolicy: .unbounded)
            let stream = BuilderAgentStream(provider: provider, continuation: continuation)
            let limits = endpoint.tools.budget.limits
            let executor = executor
            let child = Task {
                do {
                    let result = try await executor(executable, configuration, limits, { try stream.consume($0) })
                    guard result.exitCode == 0 else { throw ScriptError.invalid("Agent exited with status \(result.exitCode). " + String(decoding: result.stderr, as: UTF8.self)) }
                    try stream.finish()
                    return result
                } catch { continuation.finish(throwing: error); throw error }
            }
            process = child
            var progressLine = ""
            onProgress?("Agent is planning with Builder tools…")
            try await withTaskCancellationHandler {
                for try await message in messages {
                    try Task.checkCancellation()
                    try endpoint.tools.budget.checkTime()
                    switch message {
                    case .progress(let text):
                        // Do not reveal a bearer/API key split across provider
                        // delta events. Redact complete lines, then flush at final.
                        guard progressLine.utf8.count + text.utf8.count <= 16 * 1024 else {
                            throw ScriptError.invalid("Agent progress line exceeds limit.")
                        }
                        progressLine += text
                        while let newline = progressLine.firstIndex(of: "\n") {
                            let line = String(progressLine[..<newline])
                            progressLine.removeSubrange(...newline)
                            let safe = redactor.text(line, limit: 16 * 1024)
                            try endpoint.tools.budget.chargeLog(safe.utf8.count)
                            onProgress?(safe)
                        }
                    case .final(let text):
                        if !progressLine.isEmpty {
                            let safe = redactor.text(progressLine, limit: 16 * 1024)
                            try endpoint.tools.budget.chargeLog(safe.utf8.count)
                            onProgress?(safe)
                            progressLine = ""
                        }
                        finalResponse = redactor.text(text, limit: 16 * 1024)
                        try endpoint.tools.budget.chargeLog(finalResponse.utf8.count)
                    case .model(let model): provenance.model = redactor.text(model, limit: 128)
                    case .terminalError(let reason): throw ScriptError.invalid(reason)
                    case .toolObserved: break // Only endpoint events establish outcomes.
                    }
                }
                _ = try await child.value
            } onCancel: { child.cancel() }
            guard !endpoint.stopping, !endpoint.hasActiveCall, endpoint.tools.session.state == .ready else {
                throw ScriptError.invalid("Agent run was refused or stopped. No timeline changes applied.")
            }
        } catch {
            terminalError = redactor.text(error is CancellationError ? "Cancelled. No timeline changes applied." : error.localizedDescription)
            process?.cancel()
        }
        endpoint.revoke()
        process?.cancel()
        _ = await process?.result
        process = nil
        await endpoint.shutdown()
        if terminalError == nil, endpoint.tools.session.state != .ready {
            terminalError = "Agent ended with refused or incomplete tool work. No timeline changes applied."
        }
        if let launch {
            do { try launch.cleanup() }
            catch { terminalError = "Could not remove the private agent configuration directory." }
        }
        watchdog.cancel()
        await watchdog.value
        if exceededDeadline { terminalError = "Agent wall-time budget exhausted. No timeline changes applied." }
        provenance.duration = Date.now.timeIntervalSince(started)
        if terminalError == nil, endpoint.tools.mode == .find, endpoint.tools.session.sceneReport == nil {
            terminalError = "The assistant did not call report_scenes. No search results were reported."
        }
        if let terminalError { _ = endpoint.tools.session.fail(terminalError) }
        endpoint.finishEvent(outcome: terminalError == nil ? .completed : .failed,
                             message: terminalError, duration: provenance.duration ?? 0)
        // No HTTP handler or child callback can mutate after this point.
        _ = endpoint.tools.session.freeze()
    }

    func failBeforeLaunch(_ reason: String) {
        guard !attempted else { return }
        attempted = true
        terminalError = reason
        provenance.duration = 0
        endpoint.revoke()
        _ = endpoint.tools.session.fail(reason)
        endpoint.finishEvent(outcome: .failed, message: reason, duration: 0)
    }

    func cancel() { endpoint.revoke(); process?.cancel() }
}
