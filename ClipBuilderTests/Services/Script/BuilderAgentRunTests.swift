import Darwin
import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder agent", .timeLimit(.minutes(1)))
struct BuilderAgentRunTests {
    @Test(arguments: [BuilderAgentProvider.claude, .codex, .gemini])
    func exactLaunchIsolationAndTokenDelivery(provider: BuilderAgentProvider) throws {
        let token = UUID().uuidString
        let launch = try BuilderAgentLaunch.make(provider: provider, request: "request", model: "test-model",
            endpoint: URL(string: "http://127.0.0.1:49152/mcp")!, token: token,
            parentEnvironment: ["HOME": "/scratch-auth", "PATH": "/usr/bin:/bin", "CODEX_HOME": "/scratch-codex",
                                "NODE_OPTIONS": "--require hostile.js", "UNRELATED_SECRET": "secret", "GEMINI_API_KEY": "fixture-key"])
        defer { try? launch.cleanup() }
        #expect(launch.cwd != URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        #expect(!launch.arguments.joined().contains(token))
        #expect(launch.environment["NODE_OPTIONS"] == nil && launch.environment["UNRELATED_SECRET"] == nil)
        #expect(launch.environment["HOME"] == "/scratch-auth")
        #expect(launch.arguments.suffix(2) == ["--model", "test-model"])
        let permissions = try FileManager.default.attributesOfItem(atPath: launch.root.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        switch provider {
        case .claude:
            #expect(Array(launch.arguments.prefix(16)) == ["-p", "request", "--output-format", "stream-json", "--verbose", "--tools", "", "--allowedTools", "mcp__clipbuilder__*", "--mcp-config", launch.root.appendingPathComponent("mcp.json").path, "--strict-mcp-config", "--permission-mode", "dontAsk", "--setting-sources", ""])
            let config = try String(contentsOf: launch.root.appendingPathComponent("mcp.json"), encoding: .utf8)
            #expect(config.contains(token))
            #expect(!launch.environment.values.contains(token))
            #expect(!launch.arguments.contains("--bare") && !launch.arguments.contains("--safe-mode"))
        case .codex:
            #expect(launch.environment["CLIPBUILDER_MCP_TOKEN"] == token)
            #expect(launch.arguments.contains("mcp_servers.clipbuilder.bearer_token_env_var=\"CLIPBUILDER_MCP_TOKEN\""))
            #expect(provider.disabledReason != nil)
        case .gemini:
            #expect(launch.environment["GEMINI_CLI_HOME"] == launch.root.path)
            #expect(try String(contentsOf: launch.root.appendingPathComponent(".gemini/settings.json"), encoding: .utf8).contains(token))
            #expect(launch.arguments.contains("--policy") && provider.disabledReason != nil)
        case .local: Issue.record("Unexpected local launch")
        }
    }

    @Test func incrementalUTF8PartialFinalErrorsAndMalformedLines() throws {
        var parser = BuilderAgentParser(provider: .claude)
        _ = try parser.feed(Data((#"{"type":"system","tools":["mcp__clipbuilder__query"]}"# + "\n").utf8))
        let bytes = Data((#"{"type":"stream_event","event":{"delta":{"text":"hé🌍"}}}"# + "\n" + #"{"type":"result","subtype":"success","result":"done"}"#).utf8)
        var messages: [BuilderAgentMessage] = []
        for byte in bytes { messages += try parser.feed(Data([byte])) }
        messages += try parser.finish()
        #expect(messages == [.progress("hé🌍"), .final("done")])
        var errorParser = BuilderAgentParser(provider: .claude)
        #expect(try errorParser.feed(Data((#"{"type":"result","subtype":"error","is_error":true}"# + "\n").utf8)) == [.terminalError("Claude reported a terminal failure.")])
        var short = BuilderAgentParser(provider: .claude, maximumLineBytes: 4)
        #expect(throws: (any Error).self) { try short.feed(Data("12345".utf8)) }
        var invalid = BuilderAgentParser(provider: .claude)
        #expect(throws: (any Error).self) { try invalid.feed(Data([0xff, 0x0a])) }
        var unfinished = BuilderAgentParser(provider: .claude)
        #expect(throws: (any Error).self) { try unfinished.finish() }
        var native = BuilderAgentParser(provider: .claude)
        #expect(throws: (any Error).self) { try native.feed(Data((#"{"type":"system","tools":["Bash"]}"# + "\n").utf8)) }
    }

    @Test func budgetsReserveBeforeMutationAndAreSharedAcrossCalls() async throws {
        var limits = BuilderAgentLimits(); limits.toolCalls = 1; limits.affectedItems = 1
        let session = ScriptFixtures.session()
        let tools = BuilderTools(session: session, budget: BuilderRunBudget(limits))
        let before = session.workingDocument
        do {
            _ = try await tools.call(name: "run_script", arguments: ["steps": .array([.object(["command": .object(["op": .string("remove_clips"), "filter": .object([:])])])])])
            Issue.record("Bulk edit exceeded its item reservation")
        } catch {}
        #expect(session.workingDocument == before)
        _ = try await tools.call(name: "get_document_summary", arguments: [:])
        await #expect(throws: (any Error).self) { try await tools.call(name: "get_document_summary", arguments: [:]) }
        session.freeze()
        await #expect(throws: (any Error).self) { try await tools.call(name: "get_document_summary", arguments: [:]) }
        session.discard()
    }

    @Test func fakeExecutorNoRetryAndCleanupAfterTerminalFailure() async throws {
        let session = ScriptFixtures.session()
        let capture = AgentTestCapture()
        let run = BuilderAgentRun(provider: .claude, model: "fixture", tools: BuilderTools(session: session, budget: BuilderRunBudget(.init())),
            executor: { _, launch, _, consume in
                capture.capture(launch)
                try consume(Data((#"{"type":"result","subtype":"error","is_error":true}"# + "\n").utf8))
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 1)
            })
        await run.run(request: "test", executable: URL(fileURLWithPath: "/bin/false"), parentEnvironment: ["PATH": "/bin"])
        await run.run(request: "must not retry", executable: URL(fileURLWithPath: "/bin/false"), parentEnvironment: [:])
        #expect(capture.count == 1)
        #expect(run.terminalError != nil && session.state == .failed)
        #expect(run.endpoint.token.isEmpty)
        let capturedRoot = try #require(capture.root)
        #expect(!FileManager.default.fileExists(atPath: capturedRoot.path))
        session.discard()
    }

    @Test func fakeCLIEnvironmentWorkingDirectoryStderrBoundAndDescendantCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await ProcessRunner.runAgent(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test \"$ONLY_AGENT\" = yes || exit 7; test -z \"$UNRELATED_SECRET\" || exit 8; pwd > cwd; sleep 30 & echo $! > child; i=0; while [ $i -lt 200 ]; do echo diagnostic >&2; i=$((i+1)); done; printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\"}'"],
            cwd: root, environment: ["PATH": "/bin:/usr/bin", "ONLY_AGENT": "yes"], timeout: 5,
            maximumOutputBytes: 8192, stderrTailBytes: 80, stdout: { _ in })
        #expect(result.exitCode == 0 && result.stderr.count == 80)
        // Foundation strips "/private" when resolving symlinks; normalise both sides the same way.
        let reportedCwd = try String(contentsOf: root.appendingPathComponent("cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: reportedCwd).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        let pid = try #require(Int32(try String(contentsOf: root.appendingPathComponent("child"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Allow init to reap the killed orphan; it must not remain running.
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) == -1)
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.runAgent(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while :; do echo too-much; done"],
                cwd: root, environment: ["PATH": "/bin"], timeout: 5, maximumOutputBytes: 128, stdout: { _ in })
        }
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.runAgent(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                cwd: root, environment: [:], timeout: 0.05, maximumOutputBytes: 128, stdout: { _ in })
        }
    }
}

nonisolated private final class AgentTestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var launches: [BuilderAgentLaunch] = []
    func capture(_ launch: BuilderAgentLaunch) { lock.lock(); launches.append(launch); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return launches.count }
    var root: URL? { lock.lock(); defer { lock.unlock() }; return launches.first?.root }
}

extension BuilderAgentRunTests {
    @Test func fakeCLIStreamsSplitBytesThroughProductionRunner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        let script = #"""
        #!/bin/sh
        test "$1" = '-p' || exit 11
        test "$3" = '--output-format' || exit 12
        test "$4" = 'stream-json' || exit 13
        test "$6" = '--tools' || exit 14
        test -z "$7" || exit 15
        printf '{"type":"system","tools":["mcp__clipbuilder__query"]}\n'
        printf '{"type":"stream_event","event":{"delta":{"text":"h'
        printf '\303'
        printf '\251'
        printf '"}}}\n'
        printf 'bounded diagnostic\n' >&2
        printf '{"type":"result","subtype":"success","result":"done"}\n'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = ScriptFixtures.session()
        let run = BuilderAgentRun(provider: .claude, model: nil, tools: BuilderTools(session: session, budget: BuilderRunBudget(.init())))
        var progress: [String] = []
        run.onProgress = { progress.append($0) }
        await run.run(request: "scratch", executable: executable, parentEnvironment: ["PATH": "/bin:/usr/bin"])
        #expect(run.terminalError == nil && run.finalResponse == "done")
        #expect(progress.contains("hé"))
        #expect(session.state == .completed && run.endpoint.token.isEmpty)
        #expect(run.provenance.provider == "claude" && run.provenance.duration != nil)
        session.discard()
    }

    @Test func disabledProvidersCannotReachExecutorAndRedactionPreservesJSON() async throws {
        for provider in [BuilderAgentProvider.codex, .gemini] {
            let session = ScriptFixtures.session()
            let run = BuilderAgentRun(provider: provider, model: nil, tools: BuilderTools(session: session, budget: BuilderRunBudget(.init())),
                executor: { _, _, _, _ in
                    Issue.record("Disabled provider launched")
                    return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
                })
            await run.run(request: "scratch", executable: URL(fileURLWithPath: "/bin/false"), parentEnvironment: [:])
            #expect(run.terminalError == provider.disabledReason)
            #expect(session.state == .failed)
            session.discard()
        }
        let redactor = BuilderRunRedactor(secrets: ["secret-token"])
        #expect(!redactor.text("failure secret-token").contains("secret-token"))
        #expect(!redactor.text("Authorization: Bearer another-secret").contains("another-secret"))
        #expect(redactor.arguments([String(repeating: "x", count: 2000)]).utf8.count <= 256)
    }

    @Test func cancelledProcessAndExhaustedWallPayloadLogBudgets() async throws {
        let task = Task {
            try await ProcessRunner.runAgent(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                cwd: FileManager.default.temporaryDirectory, environment: [:], timeout: 10, maximumOutputBytes: 1024, stdout: { _ in })
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation was ignored") } catch is CancellationError {} catch { Issue.record(error) }
        var limits = BuilderAgentLimits(); limits.wallSeconds = 1; limits.loggedBytes = 1024
        let budget = BuilderRunBudget(limits)
        #expect(throws: (any Error).self) { try budget.admit(arguments: 1_048_576, affected: 0) }
        #expect(throws: (any Error).self) { try budget.chargeLog(1) }
        try await Task.sleep(for: .milliseconds(1050))
        #expect(throws: (any Error).self) { try budget.checkTime() }
    }

    @Test func codexAndGeminiFinalAndErrorStreams() throws {
        var codex = BuilderAgentParser(provider: .codex)
        let codexText = #"{"type":"item.completed","item":{"type":"agent_message","text":"response"}}"# + "\n" + #"{"type":"turn.completed"}"# + "\n"
        #expect(try codex.feed(Data(codexText.utf8)) == [.progress("response"), .final("response")])
        var gemini = BuilderAgentParser(provider: .gemini)
        let geminiText = #"{"type":"message","role":"assistant","content":"response"}"# + "\n" + #"{"type":"result","status":"success"}"# + "\n"
        #expect(try gemini.feed(Data(geminiText.utf8)) == [.progress("response"), .final("response")])
        var failed = BuilderAgentParser(provider: .codex)
        #expect(try failed.feed(Data((#"{"type":"turn.failed"}"# + "\n").utf8)) == [.terminalError("Codex reported a terminal failure.")])
    }
}

extension BuilderAgentRunTests {
    @Test func settingsDecodeOldAndPartialFilesAndClampHardMaximums() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.builderAgent == BuilderAgentLimits())
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"builder_agent":{"toolCalls":4}}"#.utf8))
        #expect(partial.builderAgent.toolCalls == 4 && partial.builderAgent.wallSeconds == 180)
        var limits = BuilderAgentLimits()
        limits.toolCalls = Int.max; limits.affectedItems = Int.max; limits.wallSeconds = .infinity
        limits.argumentBytes = Int.max; limits.resultBytes = Int.max; limits.loggedBytes = Int.max; limits.outputBytes = Int.max
        let bounded = limits.bounded
        #expect(bounded.toolCalls == 128 && bounded.affectedItems == 10_000 && bounded.wallSeconds == 180)
        #expect(bounded.argumentBytes == 256 * 1024 && bounded.resultBytes == 1024 * 1024)
        #expect(bounded.loggedBytes == 1024 * 1024 && bounded.outputBytes == 16 * 1024 * 1024)
    }
}

extension BuilderAgentRunTests {
    @Test func claudeAssistantEchoAndTurnBoundaries() throws {
        var parser = BuilderAgentParser(provider: .claude)
        let json = #"""
        {"type":"system","tools":["mcp__clipbuilder__query"]}
        {"type":"stream_event","event":{"delta":{"text":"I'll start "}}}
        {"type":"stream_event","event":{"delta":{"text":"by resolving…"}}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"I'll start by resolving…"},{"type":"tool_use","name":"mcp__clipbuilder__query"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Without partial messages."}]}}
        {"type":"result","subtype":"success","result":"done"}
        """#
        let messages = try parser.feed(Data((json + "\n").utf8)) + parser.finish()
        let progress = messages.compactMap { message -> String? in
            if case .progress(let text) = message { return text }
            return nil
        }.joined()
        #expect(progress == "I'll start by resolving…\nWithout partial messages.\n")
        #expect(messages.contains(.toolObserved("mcp__clipbuilder__query")))
    }

    @Test func fakeCLIBurstPreservesAll500Deltas() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"type":"system","tools":[]}'
        i=0
        while [ "$i" -lt 500 ]; do
            printf '{"type":"stream_event","event":{"delta":{"text":"delta-%s|"}}}\n' "$i"
            i=$((i+1))
        done
        printf '%s\n' '{"type":"result","subtype":"success","result":"done"}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = ScriptFixtures.session()
        defer { session.discard() }
        let run = BuilderAgentRun(provider: .claude, model: nil,
            tools: BuilderTools(session: session, budget: BuilderRunBudget(.init())))
        var progress: [String] = []
        run.onProgress = { progress.append($0) }
        await run.run(request: "burst", executable: executable, parentEnvironment: ["PATH": "/bin:/usr/bin"])
        #expect(run.terminalError == nil)
        #expect(run.finalResponse == "done")
        #expect(progress.dropFirst().joined() == (0..<500).map { "delta-\($0)|" }.joined())
    }

    @Test func undrainedStreamPreservesBurst() async throws {
        let (messages, continuation) = AsyncThrowingStream<BuilderAgentMessage, any Error>.makeStream(bufferingPolicy: .unbounded)
        let stream = BuilderAgentStream(provider: .claude, continuation: continuation)
        let delta = #"{"type":"stream_event","event":{"delta":{"text":"x"}}}"# + "\n"
        try stream.consume(Data((#"{"type":"system","tools":[]}"# + "\n"
            + String(repeating: delta, count: 500)
            + #"{"type":"result","subtype":"success","result":"done"}"# + "\n").utf8))
        try stream.finish()
        var progress = ""
        for try await message in messages {
            if case .progress(let text) = message { progress += text }
        }
        #expect(progress == String(repeating: "x", count: 500))
    }
}

extension BuilderAgentRunTests {
    @Test func assistantTurnSeparatorsFlushWithoutBlankProgress() async throws {
        let session = ScriptFixtures.session()
        defer { session.discard() }
        let run = BuilderAgentRun(provider: .claude, model: nil,
            tools: BuilderTools(session: session, budget: BuilderRunBudget(.init())),
            executor: { _, _, _, consume in
                let lines = [
                    #"{"type":"system","tools":["mcp__clipbuilder__query"]}"#,
                    #"{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}"#,
                    #"{"type":"assistant","message":{"content":[]}}"#,
                    #"{"type":"assistant","message":{"content":[{"type":"text","text":"   "}]}}"#,
                    #"{"type":"assistant","message":{"content":[{"type":"text","text":"second"}]}}"#,
                    #"{"type":"result","subtype":"success","result":"done"}"#
                ]
                try consume(Data((lines.joined(separator: "\n") + "\n").utf8))
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
            })
        var progress: [String] = []
        run.onProgress = { progress.append($0) }
        await run.run(request: "test", executable: URL(fileURLWithPath: "/bin/false"), parentEnvironment: ["PATH": "/bin"])
        #expect(run.terminalError == nil)
        #expect(Array(progress.dropFirst()) == ["first", "second"])
        #expect(progress.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test func promptsExplainTimelineContextAndRecoverableEdits() {
        for prompt in [BuilderAgentPrompt.rules, BuilderAgentPrompt.findRules] {
            #expect(prompt.contains("Track I is index 0"))
            #expect(prompt.contains("get_document_summary.selection"))
        }
        let prompt = BuilderAgentPrompt.rules
        #expect(prompt.contains("bindings persist across calls"))
        #expect(prompt.contains("'speech' for 0.05 s cuts"))
        #expect(prompt.contains("'ordinary' snaps to 0.5 s"))
        #expect(prompt.contains("session stays open: fix the arguments and retry"))
    }
}
