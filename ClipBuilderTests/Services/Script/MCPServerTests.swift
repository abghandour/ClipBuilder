import Foundation
import MCP
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder MCP loopback", .timeLimit(.minutes(1)))
struct MCPServerTests {
    private func endpoint() async throws -> BuilderMCPServer {
        let server = BuilderMCPServer(tools: BuilderTools(session: ScriptFixtures.session(), budget: BuilderRunBudget(.init())))
        try await server.start()
        return server
    }

    private func post(_ server: BuilderMCPServer, _ body: String, method: String = "POST",
                      headers: [String: String] = [:], path: String = "/mcp") async throws -> (Data, Int) {
        var request = URLRequest(url: server.url.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("Bearer " + server.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(BuilderMCPServer.wireVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if method == "POST" { request.httpBody = Data(body.utf8) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try #require(response as? HTTPURLResponse).statusCode)
    }

    @Test func sdkClientNegotiatesListsAndCallsTypedTools() async throws {
        let server = try await endpoint()
        let token = server.token
        let transport = HTTPClientTransport(endpoint: server.url, streaming: false, requestModifier: { request in
            var request = request
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return request
        })
        let client = Client(name: "builder-tests", version: "1")
        do {
            let initialized = try await client.connect(transport: transport)
            #expect(initialized.protocolVersion == "2025-06-18")
            let list = try await client.listTools()
            #expect(Set(list.tools.map(\.name)) == ["query", "run_script", "get_document_summary"])
            for tool in list.tools {
                #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false))
            }
            let summary = try await client.callTool(name: "get_document_summary", arguments: [:])
            #expect(summary.isError != true)
            let bad = try await client.callTool(name: "run_script", arguments: ["steps": .array([
                .object(["command": .object(["op": .string("remove_clip"), "clip": .string("invented")])])
            ])])
            #expect(bad.isError == true)
            #expect(server.tools.session.state == .failed)
            #expect(server.events.map(\.outcome) == [.completed, .refused])
            await client.disconnect()
            await server.shutdown()
        } catch { await client.disconnect(); await server.shutdown(); throw error }
    }

    @Test func httpGuardsNotificationsProtocolAndFraming() async throws {
        let server = try await endpoint()
        do {
            let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
            let result = try await post(server, initialize)
            #expect(result.1 == 200)
            #expect(String(decoding: result.0, as: UTF8.self).contains("2025-06-18"))
            let notification = try await post(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            #expect(notification.1 == 202 && notification.0.isEmpty)
            #expect(try await post(server, "", method: "GET").1 == 405)
            #expect(try await post(server, initialize, headers: ["Authorization": "Bearer wrong"]).1 == 401)
            #expect(try await post(server, initialize, headers: ["Origin": "https://example.invalid"]).1 == 403)
            #expect(try await post(server, initialize, headers: ["Host": "localhost:1234"]).1 == 421)
            #expect(try await post(server, initialize, path: "/other").1 == 404)
            let ping = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
            #expect(try await post(server, ping, headers: ["MCP-Protocol-Version": "2024-01-01"]).1 == 400)
            #expect(try await post(server, "[]").1 == 400)
            #expect(try await post(server, String(repeating: "x", count: 1_048_577)).1 == 413)
            // Exercise the exact production parser for header and chunk framing limits.
            let host = try MCPHTTPHost(endpoint: server)
            #expect(throws: (any Error).self) { try host.parse(Data(("POST /mcp HTTP/1.1\r\nX: " + String(repeating: "x", count: 17_000)).utf8)) }
            #expect(throws: (any Error).self) { try host.parse(Data("POST /mcp HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n".utf8)) }
            let chunked = try host.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n".utf8))
            #expect(chunked?.body == Data("{}".utf8))
            await server.shutdown()
        } catch { await server.shutdown(); throw error }
    }

    @Test func duplicateIDsExecuteOnlyOnceAndDifferentArgumentsFailRun() async throws {
        let server = try await endpoint()
        do {
            let body = #"{"jsonrpc":"2.0","id":"edit","method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"add_text","text":"hello"}}]}}}"#
            let first = try await post(server, body)
            let second = try await post(server, body)
            #expect(first.1 == 200 && first.0 == second.0)
            #expect(server.events.count == 1)
            #expect(server.tools.session.workingDocument.textOverlays.count == 1)
            #expect(try await post(server, body.replacingOccurrences(of: "hello", with: "different")).1 == 409)
            #expect(server.tools.session.state == .failed)
            await server.shutdown()
            #expect(server.token.isEmpty)
            let refused = await server.handle(HTTPRequest(method: "GET", path: "/mcp"))
            #expect(refused.statusCode == 503)
        } catch { await server.shutdown(); throw error }
    }

    @Test(arguments: [false, true])
    func cancellationAndShutdownDrainActiveCalls(cancelNotification: Bool) async throws {
        let session = ScriptFixtures.session()
        var entered = false
        var drained = false
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()),
            confirmedPrerequisites: [.ensureTranscript(video: 1)], ensure: { _ in
                entered = true
                do { try await Task.sleep(for: .seconds(20)) } catch {}
                drained = true
                return BuilderScriptResult(outcomes: [.refused(code: "cancelled", reason: "cancelled")], completed: false, hasDocumentChanges: false)
            })
        let server = BuilderMCPServer(tools: tools)
        try await server.start()
        let call = Task { try await post(server, #"{"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"ensure_transcript","arguments":{"video":1}}}"#) }
        for _ in 0..<1000 where !entered { try await Task.sleep(for: .milliseconds(5)) }
        guard entered else {
            await server.shutdown(); _ = await call.result
            throw ScriptError.invalid("Fixture ensure did not start.")
        }
        if cancelNotification {
            let response = try await post(server, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"slow"}}"#)
            #expect(response.1 == 202)
        }
        await server.shutdown()
        _ = await call.result
        #expect(drained)
        session.freeze()
        let before = session.workingDocument
        #expect(!session.run([.init(.addText(text: "late"))]).completed)
        #expect(session.workingDocument == before)
        session.discard()
    }
}

extension MCPServerTests {
    @Test func prerequisitesAreScopedToDisclosedVideoAndCannotBeSmuggled() async throws {
        let session = ScriptFixtures.session()
        var calls = 0
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()), confirmedPrerequisites: [.ensureTranscript(video: 1)], ensure: { _ in
            calls += 1
            return .init(outcomes: [], completed: true, hasDocumentChanges: false)
        })
        #expect(tools.definitions.map(\.name).contains("ensure_transcript"))
        #expect(!tools.definitions.map(\.name).contains("ensure_people"))
        await #expect(throws: (any Error).self) { try await tools.call(name: "ensure_transcript", arguments: ["video": .int(2)]) }
        await #expect(throws: (any Error).self) {
            try await tools.call(name: "run_script", arguments: ["steps": .array([.object([
                "command": .object(["op": .string("ensure_transcript"), "video": .int(1)])
            ])])])
        }
        #expect(calls == 0)
        _ = try await tools.call(name: "ensure_transcript", arguments: ["video": .int(1)])
        #expect(calls == 1)
        session.discard()
    }

    @Test func schemasAndSummaryCoverActualDocumentVocabulary() throws {
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()))
        let tool = try #require(tools.definitions.first { $0.name == "run_script" })
        let schema = String(decoding: try JSONEncoder().encode(tool.inputSchema), as: UTF8.self)
        #expect(schema.contains("source_start") && schema.contains("cover_all") && schema.contains("oneOf"))
        #expect(!schema.contains("sourceStart") && !schema.contains("ensure_transcript"))
        let summary = try BuilderDocumentSummary(document: session.workingDocument, offset: 0, limit: 200)
        #expect(throws: (any Error).self) { try session.query(BuilderQuery(.clips, offset: Int.max)) }
        #expect(summary.rows.contains { $0.lane == "video" })
        #expect(summary.rows.contains { $0.lane == "crop" })
        #expect(try BuilderDocumentSummary(document: session.workingDocument, offset: Int.max, limit: 200).rows.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(!json.contains("/tmp/") && !json.contains("videoFile"))
        session.discard()
    }
}

extension MCPServerTests {
    @Test func requestDeadlineStopsAndDrainsInsteadOfLeavingSDKWaiter() async throws {
        let session = ScriptFixtures.session()
        var entered = false
        var drained = false
        let server = BuilderMCPServer(tools: BuilderTools(session: session, budget: BuilderRunBudget(.init()),
            confirmedPrerequisites: [.ensureTranscript(video: 1)], ensure: { _ in
                entered = true
                do { try await Task.sleep(for: .seconds(20)) } catch {}
                drained = true
                return .init(outcomes: [], completed: false, hasDocumentChanges: false)
            }), requestDeadline: .milliseconds(200))
        try await server.start()
        do {
            _ = try await post(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ensure_transcript","arguments":{"video":1}}}"#)
        } catch {} // The deadline closes the TCP response as well as its waiter.
        await server.shutdown()
        #expect(entered && drained && server.stopping && server.token.isEmpty)
        #expect(session.state == .failed)
        session.discard()
    }
}
