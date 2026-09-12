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
            #expect(Set(list.tools.map(\.name)) == ["ask_user", "query", "run_script", "get_document_summary"])
            for tool in list.tools {
                #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false))
            }
            let summary = try await client.callTool(name: "get_document_summary", arguments: [:])
            #expect(summary.isError != true)
            let before = server.tools.session.workingDocument
            let bad = try await client.callTool(name: "run_script", arguments: ["steps": .array([
                .object(["command": .object(["op": .string("add_text"), "text": .string("rolled back")])]),
                .object(["command": .object(["op": .string("remove_clip"), "clip": .string("invented")])])
            ])])
            #expect(bad.isError == true)
            #expect(server.tools.session.state == .ready)
            #expect(server.tools.session.workingDocument == before)
            let good = try await client.callTool(name: "run_script", arguments: ["steps": .array([
                .object(["command": .object(["op": .string("add_text"), "text": .string("recovered")])])
            ])])
            #expect(good.isError != true)
            #expect(server.tools.session.workingDocument.textOverlays.map { $0.text } == ["recovered"])
            #expect(server.events.map(\.outcome) == [.completed, .refused, .completed])
            await client.disconnect()
            await server.shutdown()
        } catch { await client.disconnect(); await server.shutdown(); throw error }
    }

    @Test(arguments: [
        #"{"name":"query","arguments":{"query":{"kind":"scenes","filter":{"people":["aljo"]}}}}"#,
        #"{"name":"query","arguments":{"query":{"kind":"clips","offset":1000001}}}"#,
        #"{"name":"query","arguments":{"query":{"kind":"clips","limit":0}}}"#,
        #"{"name":"query","arguments":{"query":{"kind":"transcript","video":999999}}}"#,
        #"{"name":"get_document_summary","arguments":{"unknown":true}}"#,
        #"{"name":"get_document_summary","arguments":{"offset":1000001}}"#,
        #"{"name":"get_document_summary","arguments":{"limit":0}}"#
    ])
    func readOnlyRefusalAllowsCorrectedQueryAndScript(params: String) async throws {
        let server = try await endpoint()
        do {
            let bad = try await post(server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":" + params + "}")
            let decoded = try JSONSerialization.jsonObject(with: bad.0)
            let badJSON = try #require(decoded as? [String: Any])
            let badResult = try #require(badJSON["result"] as? [String: Any])
            #expect(badResult["isError"] as? Bool == true)
            #expect(server.tools.session.state == .ready)
            let reason = try #require(server.events.first?.message)
            #expect(!reason.isEmpty)
            let contents = try #require(badResult["content"] as? [[String: Any]])
            let content = try #require(contents.first?["text"] as? String)
            #expect(content.contains(reason))
            _ = try await post(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query","arguments":{"query":{"kind":"clips"}}}}"#)
            _ = try await post(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"add_text","text":"recovered"}}]}}}"#)
            #expect(server.events.map(\.outcome) == [.refused, .completed, .completed])
            #expect(server.tools.session.state == .ready)
            await server.shutdown()
            let diff = server.tools.session.freeze()
            #expect(server.tools.session.state == .completed && !diff.isEmpty)
            #expect(server.tools.session.candidate?.textOverlays.count == 1)
        } catch { await server.shutdown(); throw error }
    }

    @Test func refusedQueriesStillExhaustCallBudget() async throws {
        var limits = BuilderAgentLimits(); limits.toolCalls = 1
        let session = ScriptFixtures.session()
        let server = BuilderMCPServer(tools: BuilderTools(session: session, budget: BuilderRunBudget(limits)))
        try await server.start()
        do {
            _ = try await post(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"query","arguments":{}}}"#)
            #expect(session.state == .ready)
            _ = try await post(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query","arguments":{"query":{"kind":"clips"}}}}"#)
            #expect(session.state == .failed)
            #expect(server.events.last?.message?.contains("budget exhausted") == true)
            await server.shutdown()
        } catch { await server.shutdown(); throw error }
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
            // Long enough that the prerequisite has entered before the deadline fires,
            // even while the rest of the suite loads the machine; short enough to stay quick.
            }), requestDeadline: .seconds(2))
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

extension MCPServerTests {
    @Test func findModeListsOnlySearchToolsAndRefusesScript() async throws {
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()), mode: .find,
            confirmedPrerequisites: [.ensureTranscript(video: 1)], ensure: { _ in
                Issue.record("Find must not run prerequisites")
                return .init(outcomes: [], completed: false, hasDocumentChanges: false)
            })
        let server = BuilderMCPServer(tools: tools)
        try await server.start()
        do {
            let (data, _) = try await post(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
            let decoded = try JSONSerialization.jsonObject(with: data)
            let json = try #require(decoded as? [String: Any])
            let result = try #require(json["result"] as? [String: Any])
            let definitions = try #require(result["tools"] as? [[String: Any]])
            #expect(definitions.compactMap { $0["name"] as? String } == ["ask_user", "query", "get_document_summary", "report_scenes"])
            let before = session.workingDocument
            let (refused, _) = try await post(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[]}}}"#)
            #expect(String(decoding: refused, as: UTF8.self).contains("Unknown or unavailable tool"))
            #expect(session.workingDocument == before)
            await server.shutdown()
        } catch { await server.shutdown(); throw error }
        session.discard()
    }

    @Test func sceneReportsValidateIDsCountReasonsAndSingleAnswer() async throws {
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()), mode: .find)
        let before = session.workingDocument
        let valid: Value = .object(["id": .int(1), "reason": .string("A clear matching scene")])
        let badReports: [[String: Value]] = [
            ["scenes": .array([.object(["id": .int(99999), "reason": .string("Unknown")])]), "summary": .string("Matches")],
            ["scenes": .array(Array(repeating: valid, count: 11)), "summary": .string("Too many")],
            ["scenes": .array([.object(["id": .int(1), "reason": .string(String(repeating: "x", count: 501))])]), "summary": .string("Too long")],
            ["scenes": .array([valid, valid]), "summary": .string("Duplicate")]
        ]
        for arguments in badReports {
            await #expect(throws: (any Error).self) { try await tools.call(name: "report_scenes", arguments: arguments) }
            #expect(session.sceneReport == nil && session.state == .ready)
        }
        _ = try await tools.call(name: "report_scenes", arguments: ["scenes": .array([valid]), "summary": .string("One match")])
        #expect(session.sceneReport?.scenes.map(\.id) == [1])
        #expect(session.workingDocument == before)
        await #expect(throws: (any Error).self) {
            try await tools.call(name: "report_scenes", arguments: ["scenes": .array([]), "summary": .string("Replacement")])
        }
        let diff = session.freeze()
        #expect(diff.isEmpty && session.candidate == before)
        session.discard()
    }
}

extension MCPServerTests {
    @Test func summaryIncludesSelectionPlayheadFocusLabelsAndStableIDs() async throws {
        let live = ScriptFixtures.model()
        live.document.trackCount = 2
        let id = live.document.videoTrack[0].uid
        live.selection = .clip(id)
        live.playhead = 1.25
        live.focusedTrack = 1
        let session = BuilderScriptSession(live: live, library: ScriptFixtures.library())
        defer { session.discard() }
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()))
        let data = try await tools.call(name: "get_document_summary", arguments: [:])
        let summary = try JSONDecoder().decode(BuilderDocumentSummary.self, from: data)
        #expect(summary.selection == .object(["kind": .string("clip"), "id": .string(id.uuidString)]))
        #expect(summary.playhead == 1.25 && summary.focusedTrack == .number(1))
        #expect(summary.trackLabels.map { $0.index } == [0, 1])
        #expect(summary.trackLabels.map { $0.label } == ["I", "II"])
        #expect(summary.rows.contains { $0.id == id.uuidString && $0.track == 0 })
        let empty = try BuilderDocumentSummary(document: session.workingDocument, offset: 0, limit: 10)
        #expect(empty.selection == .null && empty.focusedTrack == .null)
        let json = try JSONDecoder().decode(ScriptValue.self, from: JSONEncoder().encode(empty))
        guard case .object(let fields) = json else { Issue.record("Expected object"); return }
        #expect(fields["selection"] == .null)
        let definition = try #require(tools.definitions.first { $0.name == "run_script" })
        let schema = String(decoding: try JSONEncoder().encode(definition.inputSchema), as: UTF8.self)
        #expect(schema.contains("split_clip_evenly") && schema.contains("parts"))
    }

    @Test func malformedScriptsRemainRetryableButConsumeCallBudget() async throws {
        var limits = BuilderAgentLimits(); limits.toolCalls = 1
        let session = ScriptFixtures.session()
        let server = BuilderMCPServer(tools: BuilderTools(session: session, budget: BuilderRunBudget(limits)))
        try await server.start()
        do {
            _ = try await post(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"split_clip_evenly","clip":"id","parts":13}}]}}}"#)
            #expect(session.state == .ready)
            _ = try await post(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"add_text","text":"over budget"}}]}}}"#)
            #expect(session.state == .failed)
            await server.shutdown()
        } catch { await server.shutdown(); throw error }
    }
}

extension MCPServerTests {
    @Test func refusedMiddleToolListKeepsEarlierEditsAndOnlyCompletedDiffSteps() async throws {
        let session = ScriptFixtures.session()
        defer { session.discard() }
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()))
        func call(_ steps: [BuilderScriptStep]) async throws -> BuilderScriptResult {
            let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(steps))
            let data = try await tools.call(name: "run_script", arguments: ["steps": value])
            return try JSONDecoder().decode(BuilderScriptResult.self, from: data)
        }
        let firstSteps = [BuilderScriptStep(.addText(text: "keep"), bind: "title")]
        let first = try await call(firstSteps)
        let before = session.workingDocument
        let clip = before.videoTrack[0].uid.uuidString
        let refused = try await call([.init(.splitClipEvenly(clip: clip, parts: 2)),
                                      .init(.removeClip(clip: "invented"))])
        #expect(!refused.completed && session.state == .ready)
        #expect(session.workingDocument == before && session.result == first)
        #expect(tools.executedSteps == firstSteps)
        let next = try await call([.init(.setText(overlay: "$title", text: "kept and edited"))])
        #expect(next.completed)
        #expect(session.workingDocument.textOverlays.map { $0.text } == ["kept and edited"])
        #expect(!BuilderWizardDiff.lines(session: session, steps: tools.executedSteps).contains { $0.hasPrefix("Split ") })
    }
}

extension MCPServerTests {
    @Test func authorInventoryAndGeneratedReference() async throws {
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()), mode: .author,
            confirmedPrerequisites: [.ensureTranscript(video: 1)], ensure: { _ in
                Issue.record("Author mode must not call production prerequisites")
                return .init(outcomes: [], completed: true, hasDocumentChanges: false)
            })
        let server = BuilderMCPServer(tools: tools)
        try await server.start()
        let token = server.token
        let client = Client(name: "author-tests", version: "1")
        let transport = HTTPClientTransport(endpoint: server.url, streaming: false, requestModifier: { request in
            var request = request
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return request
        })
        do {
            _ = try await client.connect(transport: transport)
            let list = try await client.listTools()
            #expect(list.tools.map { $0.name } == ["ask_user", "query", "get_document_summary", "script_reference", "submit_script"])
            let response = try await client.callTool(name: "script_reference", arguments: [:])
            #expect(response.isError != true)
            let text = response.content.compactMap { content -> String? in
                if case .text(let text, _, _) = content { return text }
                return nil
            }.joined()
            let fields = try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
            let reference = try #require(fields["reference"])
            #expect(reference.utf8.count < 24 * 1024)
            for name in BuilderCommandCatalog.operations.keys { #expect(reference.contains(name)) }
            for kind in BuilderQuery.Kind.allCases { #expect(reference.contains(kind.rawValue)) }
            #expect(reference.contains("sampleParams") && reference.contains("actualValues") && reference.contains("requires"))
            // Unknown tools cannot execute even when called without listing first.
            for name in ["run_script", "report_scenes", "ensure_transcript"] {
                await #expect(throws: (any Error).self) { try await tools.call(name: name, arguments: [:]) }
            }
            #expect(session.diff().isEmpty && session.authoredScript == nil)
            await client.disconnect(); await server.shutdown(); session.discard()
        } catch { await client.disconnect(); await server.shutdown(); session.discard(); throw error }
    }

    @Test func authorFourthSubmissionRefusedAfterThreeFailures() async throws {
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(.init()), mode: .author)
        let coordinator = BuilderRunCoordinator(tools: tools)
        let before = session.workingDocument
        for attempt in 1...3 {
            let response = await coordinator.call(name: "submit_script", arguments: [
                "source": .string("bad header \(attempt)"), "sampleParams": .object([:])
            ])
            #expect(response.isError == true)
            #expect(tools.submissionAttempts == attempt)
            #expect(session.state == (attempt == 3 ? .failed : .ready))
        }
        let last = try #require(tools.lastSubmission)
        #expect(last.status == "diagnostics" && !last.diagnostics.isEmpty)
        let fourth = await coordinator.call(name: "submit_script", arguments: [
            "source": .string(ScriptHeaderTests.source("return {summary:'valid'};")), "sampleParams": .object([:])
        ])
        #expect(fourth.isError == true && tools.submissionAttempts == 3)
        #expect(coordinator.stopping && session.authoredScript == nil)
        #expect(coordinator.events.count == 3)
        #expect(coordinator.events.last?.message == last.diagnostics.first?.reason)
        #expect(session.state == .failed && session.workingDocument == before && session.frozenCandidate == nil)
        session.discard()
    }

    @Test func authorSubmissionConsumesCoordinatorCallBudget() async throws {
        var limits = BuilderAgentLimits(); limits.toolCalls = 1
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(limits), mode: .author)
        let coordinator = BuilderRunCoordinator(tools: tools)
        _ = await coordinator.call(name: "get_document_summary", arguments: [:])
        let result = await coordinator.call(name: "submit_script", arguments: [
            "source": .string(ScriptHeaderTests.source("return {};")), "sampleParams": .object([:])
        ])
        #expect(result.isError == true && coordinator.stopping)
        #expect(session.authoredScript == nil && tools.submissionAttempts == 0)
        session.discard()
    }
}

extension MCPServerTests {
    @Test func clarificationPausesToolsWithoutApplyingOrFreezing() async throws {
        let server = try await endpoint()
        defer { Task { await server.shutdown() } }
        let tools = server.tools
        let baseline = tools.session.workingDocument
        await #expect(throws: (any Error).self) {
            try await tools.call(name: "ask_user", arguments: ["question": .string("  ")])
        }
        #expect(tools.clarificationQuestion == nil)
        _ = try await tools.call(name: "ask_user", arguments: ["question": .string("Which track?")])
        #expect(tools.clarificationQuestion == "Which track?")
        await #expect(throws: (any Error).self) {
            try await tools.call(name: "get_document_summary", arguments: [:])
        }
        #expect(tools.session.state == .ready && tools.session.workingDocument == baseline)
        #expect(BuilderTools.isReadOnly("ask_user"))
    }
}
