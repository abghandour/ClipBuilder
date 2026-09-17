import Foundation
import Testing
@testable import Clip_Builder

@Suite("Model discovery")
struct ModelDiscoveryTests {
    /// The shape of ~/.codex/models_cache.json on September 17, 2026.
    static let codexCache = """
    {
      "models": [
        {"slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "description": "Our most capable model for complex, demanding work.", "visibility": "list"},
        {"slug": "gpt-reserve", "display_name": "GPT-Reserve", "description": "Fast and affordable agentic coding model.", "visibility": "hide"},
        {"slug": "gpt-5.6-sol", "display_name": "GPT-5.6-Sol", "description": "Reliable agentic workhorse for everyday tasks.", "visibility": "list"},
        {"slug": "gpt-5.6-sol", "display_name": "duplicate", "visibility": "list"},
        {"display_name": "no slug", "visibility": "list"},
        {"slug": "gpt-5.5", "display_name": "  ", "visibility": "list"}
      ]
    }
    """

    @Test("Codex's models cache lists its visible models in order, once each, hidden ones left out")
    func codexCache() {
        let models = ModelDiscovery.codexModels(data: Data(Self.codexCache.utf8))
        #expect(models.map(\.id) == ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.5"])
        #expect(models[0].name == "GPT-6-Astra")
        #expect(models[0].description == "Our most capable model for complex, demanding work.")
        // A blank display name falls back to the slug.
        #expect(models[2].name == "gpt-5.5")
        #expect(models.allSatisfy { $0.provider == "codex" })
    }

    @Test("a missing or unreadable cache yields nothing, so the catalog stands")
    func unreadableCache() {
        #expect(ModelDiscovery.codexModels(data: Data("not json".utf8)).isEmpty)
        #expect(ModelDiscovery.codexModels(data: Data("{\"models\": 3}".utf8)).isEmpty)
        let missing = URL(fileURLWithPath: "/nonexistent/models_cache.json")
        let found = ModelDiscovery.discover(codexCache: missing)
        #expect(found["codex"] == nil)
        // Claude's aliases are always there and never claim to be complete.
        #expect(found["claude"]?.authoritative == false)
        #expect(found["claude"]?.models.map(\.id) == ["haiku", "sonnet", "opus", "fable"])
    }
}

@Suite("Catalog with discovered models", .serialized)
struct AICatalogDiscoveryTests {
    private func withDiscovered<T>(_ found: [String: DiscoveredProviderModels], _ body: () throws -> T) rethrows -> T {
        AICatalog.applyDiscovered(found)
        defer { AICatalog.applyDiscovered([:]) }
        return try body()
    }

    @Test("discovered models lead the picker, catalog leftovers follow, and names and descriptions come from the CLI")
    func merge() {
        let astra = DiscoveredModel(provider: "codex", id: "gpt-6-astra", name: "GPT-6 Astra (CLI)", description: "Most capable")
        let brandNew = DiscoveredModel(provider: "codex", id: "gpt-7-nova", name: "GPT-7 Nova", description: nil)
        withDiscovered(["codex": DiscoveredProviderModels(models: [brandNew, astra], authoritative: true)]) {
            let models = AICatalog.models(for: "codex")
            #expect(models.prefix(2) == ["gpt-7-nova", "gpt-6-astra"])
            #expect(models.contains("gpt-5"))
            #expect(Set(models).count == models.count)
            // The catalog's own name wins for a model it knows; the CLI names the rest.
            #expect(AICatalog.modelDisplayName("gpt-6-astra") == "GPT-6 Astra")
            #expect(AICatalog.modelDisplayName("gpt-7-nova") == "GPT-7 Nova")
            #expect(AICatalog.modelDescription("gpt-6-astra") == "Most capable")
            // An authoritative list decides what is offered; other providers are unaffected.
            #expect(AICatalog.offers(provider: "codex", model: "gpt-6-astra"))
            #expect(!AICatalog.offers(provider: "codex", model: "gpt-5"))
            #expect(AICatalog.offers(provider: "gemini", model: "gemini-2.5-flash"))
        }
        // Nothing discovered: the catalog alone, everything offered.
        #expect(AICatalog.models(for: "codex") == AICatalog.provider("codex")?.models)
        #expect(AICatalog.offers(provider: "codex", model: "gpt-5"))
    }

    @Test("a non-authoritative list only adds entries")
    func aliases() {
        let fable = DiscoveredModel(provider: "claude", id: "fable", name: "Fable (latest)", description: nil)
        withDiscovered(["claude": DiscoveredProviderModels(models: [fable], authoritative: false)]) {
            #expect(AICatalog.models(for: "claude").first == "fable")
            #expect(AICatalog.models(for: "claude").contains("claude-fable-5-1"))
            #expect(AICatalog.offers(provider: "claude", model: "claude-fable-5"))
            #expect(AICatalog.modelDisplayName("fable") == "Fable (latest)")
        }
    }
}
