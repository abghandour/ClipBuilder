import Foundation
import Testing
@testable import Clip_Builder

@Suite("AI service logic")
struct AIServiceTests {
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
}
