import Foundation
import MCP

/// Per-run SDK endpoint. HTTP admission is serialized on MainActor with the
/// session. The SDK owns JSON-RPC dispatch; this class owns run lifetime.
@MainActor
final class BuilderMCPServer {
    nonisolated static let wireVersion = "2025-06-18"
    private let server = Server(name: "clipbuilder", version: "1", capabilities: .init(tools: .init()))
    private let transport = StatelessHTTPServerTransport()
    let tools: BuilderTools
    private let requestDeadline: Duration
    private(set) var token = UUID().uuidString + UUID().uuidString
    private(set) var port: UInt16 = 0
    private(set) var events: [BuilderRunEvent] = []
    var onEvent: (@MainActor (BuilderRunEvent) -> Void)?
    var onStop: (@MainActor () -> Void)?
    private var busy = false
    private(set) var stopping = false
    private var active: Task<Data, any Error>?
    private var activeHandler: Task<CallTool.Result, Never>?
    private var activeRequestID: String?
    private var seen: [String: (fingerprint: Data, response: HTTPResponse)] = [:]
    private var cachedBytes = 0
    private var host: MCPHTTPHost?
    private var terminalRecorded = false
    private var redactor = BuilderRunRedactor()

    init(tools: BuilderTools, requestDeadline: Duration = .seconds(30)) {
        self.tools = tools
        self.requestDeadline = max(.milliseconds(10), min(.seconds(30), requestDeadline))
    }
    var hasActiveCall: Bool { busy || activeHandler != nil }
    var url: URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }
    func bind(port: UInt16) { self.port = port }

    func start() async throws {
        guard !stopping, host == nil else { throw ScriptError.invalid("Endpoint cannot restart.") }
        redactor = BuilderRunRedactor(secrets: [token])
        try await server.start(transport: transport)
        await server.withMethodHandler(Initialize.self) { _ in
            Initialize.Result(protocolVersion: Self.wireVersion, capabilities: .init(tools: .init()),
                              serverInfo: .init(name: "clipbuilder", version: "1"))
        }
        let definitions = tools.definitions
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: definitions) }
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Run ended") }
            return await self.call(name: params.name, arguments: params.arguments ?? [:])
        }
        do {
            let host = try MCPHTTPHost(endpoint: self, requestDeadline: requestDeadline)
            self.host = host
            try await host.start()
            try Task.checkCancellation()
        } catch { await shutdown(); throw error }
    }

    private func call(name: String, arguments: [String: Value]) async -> CallTool.Result {
        guard !stopping, activeHandler == nil else { return refusal("Run closed or busy.") }
        // Own the entire callback, including result encoding and audit writes.
        // Draining just tools.call would allow a late encoding/log failure to
        // invalidate a session after freeze.
        let handler = Task { await performCall(name: name, arguments: arguments) }
        activeHandler = handler
        let result = await handler.value
        activeHandler = nil
        return result
    }

    private func performCall(name: String, arguments: [String: Value]) async -> CallTool.Result {
        guard !stopping, !Task.isCancelled, active == nil else { return refusal("Run closed or busy.") }
        do { try tools.budget.chargeLog(2048) }
        catch {
            _ = tools.session.fail("Agent log budget exhausted.")
            return refusal("Agent log budget exhausted.")
        }
        let started = Date.now
        let requestID = activeRequestID
        let argumentBytes = (try? JSONEncoder().encode(arguments).count) ?? 0
        let task = Task { try await tools.call(name: name, arguments: arguments) }
        active = task
        var data: Data
        var outcome: BuilderRunEvent.Outcome = .completed
        var detail: String?
        do {
            data = try await task.value
            if tools.session.state == .failed { outcome = .refused }
        } catch {
            outcome = error is CancellationError ? .cancelled : .refused
            let reason = redactor.text(error.localizedDescription)
            detail = reason
            _ = tools.session.fail(reason)
            data = (try? JSONEncoder().encode(CommandOutcome.refused(code: outcome.rawValue, reason: reason))) ?? Data()
        }
        active = nil
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
            _ = tools.session.fail(detail ?? "Result encoding failed.")
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
            _ = tools.session.fail("Agent log budget exhausted.")
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

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard !stopping else { return .error(statusCode: 503, .internalError("Run stopped")) }
        guard request.header("Authorization") == "Bearer \(token)" else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"), extraHeaders: ["WWW-Authenticate": "Bearer realm=\"clipbuilder\""])
        }
        guard request.header("Host") == "127.0.0.1:\(port)" else { return .error(statusCode: 421, .invalidRequest("Unexpected Host")) }
        if let origin = request.header("Origin"), origin != "http://127.0.0.1:\(port)" {
            return .error(statusCode: 403, .invalidRequest("Unexpected Origin"))
        }
        guard request.path == "/mcp" else { return .error(statusCode: 404, .invalidRequest("Not Found")) }
        guard request.method == "POST" else { return await transport.handleRequest(request) }
        guard let body = request.body, body.count <= 1_048_576 else { return .error(statusCode: 413, .invalidRequest("Body limit")) }
        guard let rpc = try? JSONDecoder().decode([String: Value].self, from: body),
              rpc["jsonrpc"]?.stringValue == "2.0", let method = rpc["method"]?.stringValue else {
            return .error(statusCode: 400, .invalidRequest("Expected one JSON-RPC 2.0 message"))
        }
        if let params = rpc["params"], case .object = params {} else if rpc["params"] != nil {
            return .error(statusCode: 400, .invalidRequest("params must be an object"))
        }
        if method != "initialize", request.header("MCP-Protocol-Version") != Self.wireVersion {
            return .error(statusCode: 400, .invalidRequest("Unsupported MCP protocol header"))
        }
        if method == "notifications/cancelled", rpc["id"] == nil {
            // SDK cancellation drops the response. End this run to release its
            // HTTP waiter too, and drain our independently owned session task.
            let response = await transport.handleRequest(request)
            if case .object(let params) = rpc["params"], let id = params["requestId"],
               Self.idKey(id) == activeRequestID {
                revoke()
                active?.cancel()
                await stop()
                _ = tools.session.fail("Agent request cancelled.")
            }
            return response
        }
        guard let id = rpc["id"] else {
            guard method == "notifications/initialized" else { return .error(statusCode: 400, .invalidRequest("Unsupported notification")) }
            return await transport.handleRequest(request)
        }
        guard let key = Self.idKey(id), key.utf8.count <= 128 else {
            return .error(statusCode: 400, .invalidRequest("ID must be a bounded string or integer"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let fingerprint = try? encoder.encode(rpc) else { return .error(statusCode: 400, .invalidRequest("Invalid envelope")) }
        if let prior = seen[key] {
            guard prior.fingerprint == fingerprint else {
                _ = tools.session.fail("Request ID reused with different arguments.")
                return .error(statusCode: 409, .invalidRequest("Request ID reused with different arguments"))
            }
            return prior.response
        }
        guard !busy else { return .error(statusCode: 409, .invalidRequest("One call at a time")) }
        guard seen.count < 256, cachedBytes + fingerprint.count <= 16 * 1024 * 1024 else {
            _ = tools.session.fail("Request deduplication budget exhausted.")
            return .error(statusCode: 429, .invalidRequest("Request budget exhausted"))
        }
        do { try tools.budget.checkTime() } catch {
            _ = tools.session.fail("Agent wall-time budget exhausted.")
            return .error(statusCode: 429, .invalidRequest("Run deadline exceeded"))
        }
        busy = true; activeRequestID = key
        defer { busy = false; activeRequestID = nil }
        let response = await transport.handleRequest(request)
        let bytes = fingerprint.count + (response.bodyData?.count ?? 0)
        if cachedBytes + bytes <= 16 * 1024 * 1024 {
            seen[key] = (fingerprint, response); cachedBytes += bytes
        } else {
            revoke()
            _ = tools.session.fail("Request deduplication budget exhausted.")
        }
        return response
    }

    private static func idKey(_ id: Value) -> String? {
        switch id {
        case .string(let value): "s:" + value
        case .int(let value): "i:\(value)"
        default: nil
        }
    }

    func revoke() {
        let wasStopping = stopping
        stopping = true; token = ""; active?.cancel(); activeHandler?.cancel()
        if !wasStopping { onStop?() }
    }

    /// Host calls this after revocation, before closing sockets.
    func stop() async {
        revoke()
        let draining = activeHandler
        await server.stop()
        _ = await draining?.value
    }

    func shutdown() async {
        if let host { await host.stop() } else { await stop() }
        host = nil
        seen.removeAll(); cachedBytes = 0
    }
}
