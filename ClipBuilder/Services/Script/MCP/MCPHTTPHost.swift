import Foundation
import MCP
import Network

nonisolated struct MCPHTTPFailure: Error {
    let status: Int
    let message: String
}

// Small HTTP/1.1 hosting adapter. No replacement MCP/JSON-RPC dispatcher.
// One request per TCP connection, Content-Length or chunked input, bounded
// headers/body, explicit Connection: close, and a whole-request deadline.
@MainActor
final class MCPHTTPHost {
    let listener: NWListener
    let endpoint: BuilderMCPServer
    var connections: [UUID: NWConnection] = [:]
    var deadlines: [UUID: Task<Void, Never>] = [:]
    var handlers: [UUID: Task<Void, Never>] = [:]
    private var stopping = false
    private var startupResolved = false
    let maxBody = 1_048_576
    private let requestDeadline: Duration

    init(endpoint: BuilderMCPServer, requestDeadline: Duration = .seconds(30)) throws {
        self.endpoint = endpoint
        self.requestDeadline = max(.milliseconds(10), min(.seconds(30), requestDeadline))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        let listener = listener
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            listener.cancel()
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, !self.startupResolved else { return }
                        switch state {
                        case .ready:
                            self.startupResolved = true
                            self.listener.stateUpdateHandler = nil
                            if let port = self.listener.port {
                                self.endpoint.bind(port: port.rawValue)
                                continuation.resume()
                            } else { continuation.resume(throwing: ScriptError.invalid("Listener has no port.")) }
                        case .failed(let error):
                            self.startupResolved = true
                            self.listener.stateUpdateHandler = nil
                            continuation.resume(throwing: error)
                        case .cancelled:
                            self.startupResolved = true
                            self.listener.stateUpdateHandler = nil
                            continuation.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                }
                listener.start(queue: .main)
            }
        } onCancel: { listener.cancel() }
    }

    func accept(_ connection: NWConnection) {
        guard !stopping, connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        deadlines[id] = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.requestDeadline) } catch { return }
            guard self.connections[id] != nil else { return }
            await self.stop()
            _ = self.endpoint.tools.session.fail("HTTP request deadline exceeded.")
        }
        receive(id, buffer: Data())
    }

    func receive(_ id: UUID, buffer: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                buffer.append(data ?? Data())
                do {
                    if let request = try self.parse(buffer) {
                        self.handlers[id] = Task {
                            let response = await self.endpoint.handle(request)
                            self.reply(id, response)
                        }
                    } else if complete || error != nil {
                        self.reply(id, .error(statusCode: 400, .invalidRequest("Incomplete HTTP request")))
                    } else {
                        self.receive(id, buffer: buffer)
                    }
                } catch let failure as MCPHTTPFailure {
                    self.reply(id, .error(statusCode: failure.status, .invalidRequest(failure.message)))
                } catch {
                    self.reply(id, .error(statusCode: 400, .invalidRequest("Malformed HTTP request")))
                }
            }
        }
    }

    /// An oversized body is read to completion (up to this cap) before the
    /// 413 goes out: closing mid-upload resets the socket and the client sees
    /// "connection lost" instead of the status.
    let drainCap = 8 * 1_048_576

    func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= drainCap + 65_536 else { throw MCPHTTPFailure(status: 413, message: "Request too large") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw MCPHTTPFailure(status: 431, message: "Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= 16_384 else { throw MCPHTTPFailure(status: 431, message: "Headers too large") }
        let lines = String(decoding: data[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" else { throw MCPHTTPFailure(status: 400, message: "Expected HTTP/1.1") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw MCPHTTPFailure(status: 400, message: "Malformed header") }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) && $0 != 32 }), headers[key] == nil else {
                throw MCPHTTPFailure(status: 400, message: "Invalid or duplicate header")
            }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["expect"] != nil { throw MCPHTTPFailure(status: 417, message: "Expect is unsupported") }
        let remaining = Data(data[boundary.upperBound...])
        let body: Data
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else {
                throw MCPHTTPFailure(status: 400, message: "Invalid HTTP framing")
            }
            guard let decoded = try decodeChunks(remaining) else { return nil }
            body = decoded
        } else {
            let lengthText = headers["content-length"] ?? "0"
            guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(lengthText), length <= drainCap else {
                throw MCPHTTPFailure(status: 413, message: "Invalid or excessive Content-Length")
            }
            guard remaining.count >= length else { return nil }
            guard length <= maxBody else { throw MCPHTTPFailure(status: 413, message: "Body limit") }
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
                throw MCPHTTPFailure(status: 413, message: "Invalid or excessive chunk")
            }
            offset = lineEnd.upperBound
            if size == 0 {
                guard data.count >= offset + 2 else { return nil }
                // Trailers are unnecessary for these clients; refuse explicitly.
                guard data[offset..<offset + 2] == crlf else { throw MCPHTTPFailure(status: 400, message: "Trailers unsupported") }
                return body
            }
            guard data.count >= offset + size + 2 else { return nil }
            guard data[offset + size..<offset + size + 2] == crlf else { throw MCPHTTPFailure(status: 400, message: "Malformed chunk") }
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
        stopping = true
        endpoint.revoke()
        listener.cancel()
        let active = Array(handlers.values)
        for handler in active { handler.cancel() }
        await endpoint.stop()
        for id in Array(connections.keys) { close(id) }
        for handler in active { await handler.value }
    }
}

