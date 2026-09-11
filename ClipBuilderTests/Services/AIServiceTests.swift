import Foundation
import Testing
@testable import Clip_Builder

@Suite("AI service logic")
struct AIServiceTests {
    @Test("Claude timeouts propagate without repeating the request")
    func timeoutIsNotRetried() async throws {
        let directory = try TempDirectory(prefix: "TimeoutAI")
        let script = directory.url.appendingPathComponent("timeout.sh")
        try """
        #!/bin/sh
        printf 'call\n' >> "$0.count"
        cat >/dev/null
        exec /bin/sleep 10
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var config = AIConfig()
        config.providers["claude"] = AIProviderSettings(bin: script.path, model: "fixture")
        let service = AIService(config: config)
        let logs = AIServiceLogSink()
        do {
            _ = try await service.call(prompt: "timeout fixture", task: "fixture",
                                       provider: "claude", timeout: 1, log: { logs.append($0) })
            Issue.record("Expected the process timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
        }
        let calls = try String(contentsOfFile: script.path + ".count", encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 1)
        #expect(!logs.lines.contains { $0.contains("retrying") })
    }

    @Test("terminal provider markers and first-line errors")
    func unavailableMarkers() {
        for marker in ["IneligibleTierError", "This client is NO LONGER SUPPORTED",
                       "Please migrate to the Antigravity client"] {
            #expect(AIService.isProviderUnavailable(marker))
        }
        for ordinary in ["Rate limit exceeded", "session expired", "network unavailable", ""] {
            #expect(!AIService.isProviderUnavailable(ordinary))
        }
        #expect(AIService.firstCLIErrorLine("\n    at ignored.js:1\nIneligibleTierError: unavailable\n    at other.js:2")
            == "IneligibleTierError: unavailable")
    }

    @Test("unavailable Gemini stays skipped after a config update and logs the skip once")
    func unavailableProviderIsSkipped() async throws {
        let directory = try TempDirectory(prefix: "UnavailableAI")
        let failure = directory.url.appendingPathComponent("gemini.sh")
        let success = directory.url.appendingPathComponent("claude.sh")
        try """
        #!/bin/sh
        printf 'call\n' >> "$0.count"
        printf '%s\n' 'IneligibleTierError: This client is no longer supported' '    at secret-stack.js:42' >&2
        exit 1
        """.write(to: failure, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"fixture answer"}]}}'
        """#.write(to: success, atomically: true, encoding: .utf8)
        for script in [failure, success] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        var config = AIConfig()
        for provider in AICatalog.providers {
            config.providers[provider.key] = AIProviderSettings(
                bin: directory.url.appendingPathComponent("missing-" + provider.key).path, model: "fixture")
        }
        config.providers["gemini"] = AIProviderSettings(bin: failure.path, model: "fixture")
        config.providers["claude"] = AIProviderSettings(bin: success.path, model: "fixture")
        config.tasks["analysis"] = "gemini"
        let service = AIService(config: config)
        let logs = AIServiceLogSink()
        // An unknown task has no fallback chain, exposing the classified error.
        do {
            _ = try await service.call(prompt: "fixture", task: "fixture", provider: "gemini",
                                       timeout: 5, log: { logs.append($0) })
            Issue.record("Expected unavailable-provider error")
        } catch let error as AIError {
            guard case .notConfigured(let message) = error else {
                Issue.record("Expected notConfigured, got \(error)")
                return
            }
            #expect(message.contains("Choose another analysis provider in Settings → AI"))
            #expect(message.contains("IneligibleTierError"))
            #expect(!message.contains("secret-stack"))
        }
        await service.updateConfig(config)
        #expect(await service.isProviderAvailable("gemini") == false)
        // A read without a logger must not consume the one-time skip message.
        let candidates = await service.dispatchCandidates(task: "analysis")
        #expect(!candidates.contains { $0.provider == "gemini" })
        for _ in 0..<2 {
            let response = try await service.call(prompt: "fixture", task: "analysis",
                                                  timeout: 5, log: { logs.append($0) })
            #expect(response.provider == "claude")
        }
        let calls = try String(contentsOfFile: failure.path + ".count", encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 1)
        #expect(logs.lines.filter { $0 == "Skipping Gemini CLI: unavailable for this account" }.count == 1)
        #expect(!logs.lines.contains { $0.contains("secret-stack") })
    }

    @Test("AI JSON parser accepts fences and prose")
    func responseParser() throws {
        let fenced = try #require(AIResponseParser.jsonObject(from: "```json\n{\"ok\":true}\n```"))
        #expect(fenced["ok"] as? Bool == true)
        #expect(AIResponseParser.jsonObject(from: "Here: {\"value\":2} trailing")?["value"] as? Int == 2)
        #expect(AIResponseParser.jsonObject(from: "not json") == nil)
    }

    @Test("progress lines reject noisy or multiline output")
    func progressLines() {
        #expect(AIProgressLine.from("  Working…  ") == "Working…")
        #expect(AIProgressLine.from("────") == nil)
        #expect(AIProgressLine.from("one\ntwo") == nil)
        #expect(AIProgressLine.from(String(repeating: "x", count: 161)) == nil)
    }

    @Test("task model override wins provider default")
    func modelResolution() async {
        var config = AIConfig()
        config.tasks["wizard"] = "claude"
        config.taskModels["wizard"] = "task-model"
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "provider-model")
        let service = AIService(config: config)

        let resolved = await service.resolveProviderModel(task: "wizard")
        #expect(resolved.provider == "claude")
        #expect(resolved.model == "task-model")

        let explicit = await service.resolveProviderModel(task: "wizard", provider: "claude", model: "explicit")
        #expect(explicit.model == "explicit")

        let candidates = await service.dispatchCandidates(task: "wizard", providerOverride: "claude")
        #expect(candidates.first?.provider == "claude")
        #expect(Set(candidates.map(\.provider)).count == candidates.count)
    }
    @Test("native video does not load fallback stills on success")
    func nativeVideoIsLazy() async throws {
        var config = AIConfig()
        config.providers["gemini"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        let service = AIService(config: config)
        let source = AnalysisFrameSource {
            Issue.record("Native success must not extract the fallback grid")
            return []
        }
        let response = try await service.call(
            prompt: "Analyze video", task: "analysis", video: URL(fileURLWithPath: "/tmp/native.mp4"),
            fallbackFrames: { try await source.frames() }, provider: "gemini", timeout: 5)
        #expect(response.provider == "gemini")
        #expect(!response.fellBack)
    }

    @Test("native failure lazily supplies stills and records the answering provider")
    func nativeVideoFallbackProvenance() async throws {
        let directory = try TempDirectory(prefix: "LazyAI")
        let failure = directory.url.appendingPathComponent("fail.sh")
        let success = directory.url.appendingPathComponent("answer.sh")
        try "#!/bin/sh\nexit 1\n".write(to: failure, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"fixture answer"}]}}'
        """#.write(to: success, atomically: true, encoding: .utf8)
        for script in [failure, success] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        var config = AIConfig()
        config.providers["gemini"] = AIProviderSettings(bin: failure.path, model: "native-fixture")
        config.providers["claude"] = AIProviderSettings(bin: success.path, model: "still-fixture")
        let service = AIService(config: config)
        let capture = AIRunCapture()
        let counter = FrameLoadCounter()
        let timeoutCounts = AIServiceLogSink()
        let response = try await AIRunCapture.context.withValue(capture) {
            try await service.call(
                prompt: "Analyze video", task: "analysis", video: URL(fileURLWithPath: "/tmp/native.mp4"),
                fallbackFrames: {
                    await counter.increment()
                    return [AIFrame(jpeg: Data("fixture".utf8), label: "1.0s")]
                }, provider: "gemini", timeout: 5,
                timeoutForFrameCount: { count in
                    timeoutCounts.append(String(count))
                    return 5
                })
        }
        #expect(timeoutCounts.lines == ["1"])
        #expect(await counter.count == 1)
        #expect(response.provider == "claude")
        #expect(response.fellBack)
        #expect(capture.roles.count == 1)
        #expect(capture.roles.first?.provenance.provider == "claude")
    }

    @Test("video-only requests cannot fall through to a provider without video support")
    func videoRequiresCapableProvider() async throws {
        var config = AIConfig()
        config.providers["claude"] = AIProviderSettings(bin: "/bin/echo", model: "fixture")
        config.providers["gemini"] = AIProviderSettings(bin: "/nonexistent/clipbuilder-test-gemini", model: "fixture")
        let service = AIService(config: config)
        do {
            _ = try await service.call(prompt: "Analyze", task: "analysis",
                                       video: URL(fileURLWithPath: "/tmp/native.mp4"),
                                       provider: "claude", timeout: 5)
            Issue.record("Video-only request must fail without a capable provider or still fallback")
        } catch let error as AIError {
            #expect(error.description.contains("still-frame fallback"))
        }
    }
}

private actor FrameLoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}


private final class AIServiceLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}
