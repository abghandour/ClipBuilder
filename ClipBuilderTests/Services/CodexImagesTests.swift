import Foundation
import Testing
@testable import Clip_Builder

@Suite("Codex with image frames")
struct CodexImagesTests {
    @Test("frames ride to Codex as attached images, listed in order at the top of the prompt")
    func codexTakesFrames() async throws {
        let stub = try StubAI(response: "{\"people\": []}")
        let frames = [AIFrame(jpeg: Data([0xFF, 0xD8, 0xFF]), label: "3.5s"),
                      AIFrame(jpeg: Data([0xFF, 0xD8, 0xFF]), label: "7.0s")]
        var logs: [String] = []
        let response = try await stub.service.call(prompt: "Who is here?", task: "people", frames: frames,
                                                   provider: "codex", timeout: 5, log: { logs.append($0) })
        #expect(response.provider == "codex")
        let prompt = try String(contentsOf: stub.prompts, encoding: .utf8)
        #expect(prompt.contains("The attached images, in order:\nImage 1: 3.5s\nImage 2: 7.0s"))
        #expect(prompt.contains("Who is here?"))
        #expect(AICatalog.provider("codex")?.supportsImages == true)
    }

    @Test("a frame task routed to a text-only provider with no fallback says so instead of blaming missing CLIs")
    func textOnlyProviderExplains() async throws {
        let stub = try StubAI(response: "{}")
        var config = AIConfig()
        // Only Qwen (text-only) is "installed"; every image-capable CLI is absent.
        for provider in AICatalog.providers {
            config.providers[provider.key] = AIProviderSettings(
                bin: provider.key == "qwen" ? stub.directory.url.appendingPathComponent("model").path : "/nonexistent/\(provider.key)",
                model: nil)
        }
        config.tasks["people"] = "qwen"
        let service = AIService(config: config)
        do {
            _ = try await service.call(prompt: "x", task: "people",
                                       frames: [AIFrame(jpeg: Data([0xFF]), label: "1.0s")], timeout: 5)
            Issue.record("Expected no candidates")
        } catch let error as AIError {
            let message = "\(error)"
            #expect(message.contains("cannot take image frames"))
            #expect(message.contains("Qwen Code"))
        }
        // Every routable task has a fallback chain, so a skipped provider is never the end.
        for task in AICatalog.taskDefaults.keys {
            #expect(AICatalog.recommendedChains[task] != nil, Comment(rawValue: task))
        }
    }
}
