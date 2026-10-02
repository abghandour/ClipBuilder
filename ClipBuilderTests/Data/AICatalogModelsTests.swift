import Testing
@testable import Clip_Builder

@Suite("AI catalog models")
struct AICatalogModelsTests {
    @Test("Every catalog model has a display name, so raw ids never reach a picker")
    func displayNames() {
        for provider in AICatalog.providers {
            for model in provider.models {
                #expect(AICatalog.modelDisplayNames[model] != nil, "\(provider.key): \(model)")
            }
            #expect(provider.models.contains(provider.defaultModel), "\(provider.key) default")
            #expect(Set(provider.models).count == provider.models.count, "\(provider.key) duplicates")
        }
    }

    @Test("The current Claude, Gemini and Antigravity models are offered", arguments: [
        ("claude", "claude-opus-5-5", "Opus 5.5"),
        ("claude", "claude-sonnet-5-5", "Sonnet 5.5"),
        ("gemini", "gemini-3.8-flash", "Gemini 3.8 Flash"),
        ("antigravity", "gemini-3.8-flash-medium", "Gemini 3.8 Flash (Medium)"),
        ("antigravity", "gemini-3.1-pro-high", "Gemini 3.1 Pro (High)"),
    ])
    func current(provider: String, model: String, name: String) {
        #expect(AICatalog.provider(provider)?.models.contains(model) == true)
        #expect(AICatalog.modelDisplayName(model) == name)
    }

    @Test("Recommended chains only name models the catalog offers")
    func chains() {
        for (task, chain) in AICatalog.recommendedChains {
            for entry in chain {
                #expect(AICatalog.provider(entry.provider)?.models.contains(entry.model) == true,
                        "\(task): \(entry.provider) \(entry.model)")
            }
        }
    }

    @Test("Antigravity replaces Gemini in the subscription chains, API-key entries stay last")
    func subscriptionChains() {
        #expect(AICatalog.provider("antigravity")?.supportsImages == true)
        #expect(AICatalog.provider("antigravity")?.bin == "agy")
        for (task, chain) in AICatalog.recommendedChains {
            let gemini = chain.filter { $0.provider == "gemini" }
            let antigravity = chain.filter { $0.provider == "antigravity" }
            #expect(gemini.count == antigravity.count, "\(task)")
            #expect(chain.suffix(gemini.count).allSatisfy { $0.provider == "gemini" }, "\(task)")
            for (original, replacement) in zip(gemini, antigravity) {
                let expected = original.model == "gemini-3.1-pro-preview" ? "gemini-3.1-pro-high"
                    : ["analysis", "people"].contains(task) ? "gemini-3.8-flash-low" : "gemini-3.8-flash-medium"
                #expect(replacement.model == expected, "\(task)")
            }
        }
    }
}
