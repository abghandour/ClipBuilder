import Darwin
import Foundation
import MCP
import Network

let wireVersion = "2025-06-18"
let timelineJSON = #"{"id":"timeline-stub","duration":3,"tracks":[{"id":"main","clips":[{"id":"clip-1","start":0,"duration":3,"source":"fixture.mov"}]}]}"#

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// SDK transport handles JSON-RPC and Streamable HTTP. This wrapper supplies
// the spike's fixed negotiation policy and guards all methods, including GET.
actor Endpoint {
    let server = Server(name: "clipbuilder-spike", version: "0.0.1", capabilities: .init(tools: .init()))
    let transport = StatelessHTTPServerTransport()
    let port: UInt16
    let token: String
    var busy = false
    var stopping = false

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    func start() async throws {
        precondition(Version.supported.contains(wireVersion))
        try await server.start(transport: transport)
        // start() installs default negotiation. Replace it AFTER start(), before
        // listening, so even clients proposing 2025-11-25 get our pinned version.
        // Stateless mode intentionally does not enforce a per-client lifecycle.
        await server.withMethodHandler(Initialize.self) { _ in
            Initialize.Result(
                protocolVersion: wireVersion,
                capabilities: .init(tools: .init()),
                serverInfo: .init(name: "clipbuilder-spike", version: "0.0.1")
            )
        }
        let emptySchema: Value = .object([
            "type": .string("object"), "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
        let tools = [
            Tool(name: "ping_tool", description: "Return pong.", inputSchema: emptySchema),
            Tool(name: "echo_tool", description: "Return text unchanged.", inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["text": .object(["type": .string("string")])]),
                "required": .array([.string("text")]), "additionalProperties": .bool(false)
            ])),
            Tool(name: "timeline_stub", description: "Return a fixed JSON timeline.", inputSchema: emptySchema)
        ]
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments ?? [:]
            let result: String
            switch params.name {
            case "ping_tool", "timeline_stub":
                guard args.isEmpty else { throw MCPError.invalidParams("This tool takes no arguments") }
                result = params.name == "ping_tool" ? "pong" : timelineJSON
            case "echo_tool":
                guard args.count == 1, let text = args["text"]?.stringValue else {
                    throw MCPError.invalidParams("Expected only text: string")
                }
                result = text
            default:
                throw MCPError.invalidParams("Unknown tool")
            }
            return .init(content: [.text(text: result, annotations: nil, _meta: nil)], isError: false)
        }
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard !stopping else { return .error(statusCode: 503, .internalError("Stopping")) }
        guard request.header("Authorization") == "Bearer \(token)" else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"),
                          extraHeaders: ["WWW-Authenticate": "Bearer realm=\"mcp-spike\""])
        }
        guard request.header("Host") == "127.0.0.1:\(port)" else {
            return .error(statusCode: 421, .invalidRequest("Unexpected Host"))
        }
        if let origin = request.header("Origin"), origin != "http://127.0.0.1:\(port)" {
            return .error(statusCode: 403, .invalidRequest("Unexpected Origin"))
        }
        guard request.path == "/mcp" else { return .error(statusCode: 404, .invalidRequest("Not Found")) }
        guard request.method == "POST" else { return await transport.handleRequest(request) }

        // Validate the envelope before SDK admission; invalid IDs must not leave
        // an unmatchable response waiter in the SDK transport.
        guard let body = request.body,
              let rpc = try? JSONDecoder().decode([String: Value].self, from: body),
              rpc["jsonrpc"]?.stringValue == "2.0",
              let method = rpc["method"]?.stringValue else {
            return .error(statusCode: 400, .invalidRequest("Expected one JSON-RPC 2.0 message"))
        }
        if let id = rpc["id"] {
            switch id {
            case .string, .int: break
            default: return .error(statusCode: 400, .invalidRequest("ID must be a string or integer"))
            }
        }
        if let params = rpc["params"], case .object = params {} else if rpc["params"] != nil {
            return .error(statusCode: 400, .invalidRequest("params must be an object"))
        }
        if method != "initialize", request.header("MCP-Protocol-Version") != wireVersion {
            return .error(statusCode: 400, .invalidRequest("MCP-Protocol-Version must be \(wireVersion)"))
        }
        // Only log known method/tool names, never arbitrary arguments or headers.
        let methods = ["initialize", "notifications/initialized", "notifications/cancelled", "tools/list", "tools/call", "ping"]
        var detail = methods.contains(method) ? method : "unknown-method"
        if case .object(let params) = rpc["params"] {
            if method == "tools/call", let name = params["name"]?.stringValue,
               ["ping_tool", "echo_tool", "timeline_stub"].contains(name) { detail += " \(name)" }
        }
        log("MCP \(detail)")
        let isCall = rpc["id"] != nil
        // The runner is sequential. Refuse overlapping requests instead of
        // allowing two clients with the same ID to overwrite an SDK waiter.
        if isCall && busy { return .error(statusCode: 409, .invalidRequest("Spike accepts one call at a time")) }
        if isCall { busy = true }
        defer { if isCall { busy = false } }
        return await transport.handleRequest(request)
    }

    func stop() async {
        stopping = true
        await server.stop()
    }
}

struct HTTPFailure: Error {
    let status: Int
    let message: String
}

// Small HTTP/1.1 hosting adapter. No replacement MCP/JSON-RPC dispatcher.
// One request per TCP connection, Content-Length or chunked input, bounded
// headers/body, explicit Connection: close, and a whole-request deadline.
@MainActor
final class HTTPHost {
    let listener: NWListener
    let endpoint: Endpoint
    var connections: [UUID: NWConnection] = [:]
    var deadlines: [UUID: Task<Void, Never>] = [:]
    var handlers: [UUID: Task<Void, Never>] = [:]
    let maxBody = 1_048_576

    init(port: UInt16, endpoint: Endpoint) throws {
        self.endpoint = endpoint
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listener.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        self.listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.connections[id] != nil else { return }
            log("HTTP deadline expired; stopping spike to release SDK waiters")
            await self.stop()
            Darwin.exit(1)
        }
        receive(id, buffer: Data(), logged: false)
    }

    func receive(_ id: UUID, buffer: Data, logged: Bool) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                buffer.append(data ?? Data())
                var logged = logged
                if !logged, let end = buffer.range(of: Data("\r\n".utf8)) {
                    // Escape control characters and redact the configured token
                    // even if a malformed client puts it in the request target.
                    let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    let safe = line.replacingOccurrences(of: await self.endpoint.token, with: "[REDACTED]")
                    log("HTTP \(String(reflecting: safe))")
                    logged = true
                }
                do {
                    if let request = try self.parse(buffer) {
                        self.handlers[id] = Task {
                            let response = await self.endpoint.handle(request)
                            self.reply(id, response)
                        }
                    } else if complete || error != nil {
                        self.reply(id, .error(statusCode: 400, .invalidRequest("Incomplete HTTP request")))
                    } else {
                        self.receive(id, buffer: buffer, logged: logged)
                    }
                } catch let failure as HTTPFailure {
                    self.reply(id, .error(statusCode: failure.status, .invalidRequest(failure.message)))
                } catch {
                    self.reply(id, .error(statusCode: 400, .invalidRequest("Malformed HTTP request")))
                }
            }
        }
    }

    func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= maxBody + 65_536 else { throw HTTPFailure(status: 413, message: "Request too large") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw HTTPFailure(status: 431, message: "Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= 16_384 else { throw HTTPFailure(status: 431, message: "Headers too large") }
        let lines = String(decoding: data[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" else { throw HTTPFailure(status: 400, message: "Expected HTTP/1.1") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPFailure(status: 400, message: "Malformed header") }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) && $0 != 32 }), headers[key] == nil else {
                throw HTTPFailure(status: 400, message: "Invalid or duplicate header")
            }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["expect"] != nil { throw HTTPFailure(status: 417, message: "Expect is unsupported") }
        let remaining = Data(data[boundary.upperBound...])
        let body: Data
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else {
                throw HTTPFailure(status: 400, message: "Invalid HTTP framing")
            }
            guard let decoded = try decodeChunks(remaining) else { return nil }
            body = decoded
        } else {
            let lengthText = headers["content-length"] ?? "0"
            guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(lengthText), length <= maxBody else {
                throw HTTPFailure(status: 413, message: "Invalid or excessive Content-Length")
            }
            guard remaining.count >= length else { return nil }
            body = Data(remaining.prefix(length))
        }
        return HTTPRequest(method: String(first[0]), headers: headers, body: body, path: String(first[1]))
    }

    func decodeChunks(_ data: Data) throws -> Data? {
        var offset = 0
        var body = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: offset..<data.count) else { return nil }
            let sizeText = String(decoding: data[offset..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";", omittingEmptySubsequences: false).first ?? ""
            guard !sizeText.isEmpty, sizeText.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }), let size = Int(sizeText, radix: 16), size <= maxBody - body.count else {
                throw HTTPFailure(status: 413, message: "Invalid or excessive chunk")
            }
            offset = lineEnd.upperBound
            if size == 0 {
                guard data.count >= offset + 2 else { return nil }
                // Trailers are unnecessary for these clients; refuse explicitly.
                guard data[offset..<offset + 2] == crlf else { throw HTTPFailure(status: 400, message: "Trailers unsupported") }
                return body
            }
            guard data.count >= offset + size + 2 else { return nil }
            guard data[offset + size..<offset + size + 2] == crlf else { throw HTTPFailure(status: 400, message: "Malformed chunk") }
            body.append(data[offset..<offset + size])
            offset += size + 2
        }
    }

    func reply(_ id: UUID, _ response: HTTPResponse) {
        guard let connection = connections[id] else { return }
        let body = response.bodyData ?? Data()
        var head = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
        for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        log("HTTP response \(response.statusCode)")
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    func close(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        handlers.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    func stop() async {
        listener.cancel()
        await endpoint.stop()
        for id in Array(connections.keys) { close(id) }
    }
}

@main
enum Spike {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 3, let port = UInt16(args[1]), port > 0,
              !args[2].isEmpty, args[2].utf8.allSatisfy({ (33...126).contains($0) }) else {
            log("Usage: mcp-spike PORT BEARER_TOKEN (nonempty visible ASCII)")
            Darwin.exit(64)
        }
        let endpoint = Endpoint(port: port, token: args[2])
        do {
            try await endpoint.start()
            let host = try HTTPHost(port: port, endpoint: endpoint)
            let (signals, continuation) = AsyncStream<Int32>.makeStream()
            let sources = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { continuation.yield(number) }
                source.resume()
                return source
            }
            try await host.start()
            log("Listening http://127.0.0.1:\(port)/mcp protocol=\(wireVersion) SDK=0.12.1")
            for await _ in signals { break }
            log("Stopping")
            await host.stop()
            for source in sources { source.cancel() }
            continuation.finish()
        } catch {
            log("Server startup failed: \(error)")
            await endpoint.stop()
            Darwin.exit(1)
        }
    }
}
