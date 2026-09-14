import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Saved script request routing")
struct ScriptRequestRouterTests {
    private func callCount(_ stub: StubAI) -> Int {
        ((try? String(contentsOf: stub.calls, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test func deterministicMatchDoesNotCallAI() async throws {
        let stub = try StubAI(response: "must not be called")
        let record = try ScriptRequestMatcherTests.record(ScriptExamples.muteBRoll)
        let decision = await ScriptRequestRouter().route(request: "mute all b-roll", scripts: [record],
            capture: ScriptRequestMatcherTests.capture(), ai: stub.service)
        guard case .runScript(let selected, let parameters, let reason) = decision else {
            Issue.record("Expected a deterministic script route"); return
        }
        #expect(selected.id == record.id && parameters.isEmpty)
        #expect(reason.contains("0 model calls") && callCount(stub) == 0)
    }

    @Test func ambiguousMatchMakesOneRouteCall() async throws {
        let records = try [ScriptRequestMatcherTests.record(ScriptExamples.muteBRoll), ScriptRequestMatcherTests.record(ScriptExamples.muteBRoll)]
        let stub = try StubAI(response: """
        {"script":"\(records[0].id)","parameters":{},"confidence":0.95,"reason":"Matches the entire request"}
        """)
        let decision = await ScriptRequestRouter().route(request: "mute all b-roll", scripts: records,
            capture: ScriptRequestMatcherTests.capture(), ai: stub.service)
        guard case .runScript(let selected, _, let reason) = decision else {
            Issue.record("Expected the validated classifier route"); return
        }
        #expect(selected.id == records[0].id && reason.contains("1 routing call (Haiku"))
        #expect(callCount(stub) == 1)
        let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
        #expect(prompt.contains("Select a saved Builder script") && prompt.contains(records[0].id.uuidString))
        let resolved = await stub.service.resolveProviderModel(task: "route")
        #expect(resolved.provider == "claude" && resolved.model == "claude-haiku-4-5-20251001")
    }

    @Test(arguments: ["invalid", "low", "unknown", "null", "extra", "range", "type", "choice", "missing"])
    func doubtfulRepliesEscalate(kind: String) async throws {
        let source = ScriptHeaderTests.source(params: #"[{"name":"count","type":"number","min":2,"max":12,"step":1},{"name":"style","type":"choice","choices":["a","b"]}]"#)
        let record = try ScriptRequestMatcherTests.record(source)
        let id = kind == "unknown" ? UUID() : record.id
        var fields: [String: ScriptValue] = [
            "script": .string(id.uuidString), "confidence": .number(kind == "low" ? 0.79 : 0.95),
            "parameters": .object(["count": .number(6), "style": .string("a")]), "reason": .string("match")
        ]
        switch kind {
        case "null": fields["script"] = .null
        case "extra": fields["unexpected"] = .bool(true)
        case "range": fields["parameters"] = .object(["count": .number(99), "style": .string("a")])
        case "type": fields["parameters"] = .object(["count": .string("6"), "style": .string("a")])
        case "choice": fields["parameters"] = .object(["count": .number(6), "style": .string("c")])
        case "missing": fields["parameters"] = .object([:])
        default: break
        }
        let response = kind == "invalid" ? "not JSON" : String(decoding: try JSONEncoder().encode(ScriptValue.object(fields)), as: UTF8.self)
        let stub = try StubAI(response: response)
        let decision = await ScriptRequestRouter().route(request: "Test script", scripts: [record],
            capture: ScriptRequestMatcherTests.capture(), ai: stub.service)
        guard case .escalate = decision else { Issue.record("Expected escalation for \(kind)"); return }
        #expect(callCount(stub) == 1)
    }

    @Test func providerFailureEscalatesWithoutRetry() async throws {
        let stub = try StubAI(response: "provider unavailable", exitCode: 1)
        let records = try [ScriptRequestMatcherTests.record(ScriptExamples.muteBRoll), ScriptRequestMatcherTests.record(ScriptExamples.muteBRoll)]
        let decision = await ScriptRequestRouter().route(request: "mute all b-roll", scripts: records,
            capture: ScriptRequestMatcherTests.capture(), ai: stub.service)
        guard case .escalate = decision else { Issue.record("Expected provider failure to escalate"); return }
        #expect(callCount(stub) == 1)
    }

    @Test func preferenceOffAndNoMatchMakeNoCalls() async throws {
        let stub = try StubAI(response: "must not be called")
        let record = try ScriptRequestMatcherTests.record(ScriptExamples.muteBRoll)
        for (request, enabled) in [("mute all b-roll", false), ("make the intro punchier", true)] {
            let decision = await ScriptRequestRouter().route(request: request, scripts: [record],
                capture: ScriptRequestMatcherTests.capture(), ai: stub.service, preferSavedScripts: enabled)
            guard case .escalate = decision else { Issue.record("Expected escalation"); return }
        }
        #expect(callCount(stub) == 0)
    }

    @Test func routeDefaultsStayCheapUnlessTaskModelIsExplicit() async throws {
        let stub = try StubAI(response: "unused")
        var config = await stub.service.config
        config.providers["claude"]?.model = "claude-sonnet-4-6"
        await stub.service.updateConfig(config)
        let defaultRoute = await stub.service.resolveProviderModel(task: "route")
        #expect(defaultRoute.model == "claude-haiku-4-5-20251001")
        config.taskModels["route"] = "claude-sonnet-4-6"
        await stub.service.updateConfig(config)
        let explicitRoute = await stub.service.resolveProviderModel(task: "route")
        #expect(explicitRoute.model == "claude-sonnet-4-6")
        #expect(AICatalog.tasks.contains("route") && AICatalog.taskLabels["route"] == "Wizard routing")
        #expect(AICatalog.recommendedChains["route"]?.map(\.provider) == ["claude", "gemini", "codex"])
        #expect(callCount(stub) == 0)
    }

    @Test func preferenceDefaultsOnAndPersistsOff() throws {
        let suite = "ScriptRouting.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScriptPreferences(defaults: defaults)
        #expect(preferences.preferSavedScripts)
        preferences.preferSavedScripts = false
        #expect(!ScriptPreferences(defaults: defaults).preferSavedScripts)
    }
}
