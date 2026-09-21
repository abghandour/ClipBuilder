import Foundation
import Testing
@testable import Clip_Builder

@Suite("Small static helpers")
struct SmallStaticsTests {
    @Test("Pipeline falls back from recording recipes without losing per-video scope")
    @MainActor
    func pipelineRecipeFallback() throws {
        let suiteName = "pipeline-recipe-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("podcast_highlights", forKey: "wizard.formatPreset")
        var messages: [String] = []
        var options = AppStore.wizardOptionsFromForm(transcriptsAvailable: true, defaults: defaults) {
            messages.append($0)
        }
        #expect(options.formatPreset == "custom")
        #expect(messages.count == 1)
        #expect(messages.first?.contains("analyzed scenes") == true)
        #expect(defaults.string(forKey: "wizard.formatPreset") == "podcast_highlights")
        // The pipeline supplies these after reading the form, then runWizard neutralizes.
        options.selectedRunIDs = [42]
        options.favoritesOnly = true
        options.projectID = 7
        let dispatched = options.neutralized(for: try #require(ReelRecipe.recipe(id: options.formatPreset)))
        #expect(dispatched.formatPreset == "custom")
        #expect(dispatched.selectedRunIDs == [42])
        #expect(dispatched.favoritesOnly)
        #expect(dispatched.projectID == 7)

        defaults.set("mma-finish", forKey: "wizard.formatPreset")
        messages = []
        let fight = AppStore.wizardOptionsFromForm(transcriptsAvailable: false, defaults: defaults) {
            messages.append($0)
        }
        #expect(fight.formatPreset == "mma-finish")
        #expect(messages.isEmpty)
    }

    @Test("text markup and counts")
    func textOverlayMarkup() {
        let words = TextOverlayRenderer.parseMarkup("hello *bright world*")
        #expect(TextOverlayRenderer.plainText(words) == "hello bright world")
        #expect(TextOverlayRenderer.wordCount(" one   two three ") == 3)
        let color = TextOverlayRenderer.parseColor("#ff8000")
        #expect(abs(color.0 - 1) < 0.001)
        #expect(abs(color.1 - 0.502) < 0.01)
        #expect(abs(color.2) < 0.001)
    }

    @Test("transition overlap math")
    func transitionOverlap() {
        #expect(RenderEngine.consumedOverlap(nil, xfadeDuration: 0.7) == 0)
        #expect(RenderEngine.consumedOverlap("cut", xfadeDuration: 0.7) == 0)
        #expect(RenderEngine.consumedOverlap("fade", xfadeDuration: 0.7) == 0.7)
        #expect(RenderEngine.consumedOverlap("flash_white", xfadeDuration: 0.7) == 0.12)
        #expect(RenderEngine.consumedOverlap("whip_left", xfadeDuration: 0.7) == 0.15)
        #expect(RenderEngine.consumedOverlap("speed_ramp", xfadeDuration: 0.7) == 0.3)
        // Every planner-visible name resolves: crossfades take the full
        // xfade length, flashes and recipes their own shorter overlap,
        // and nothing ever consumes more than the crossfade.
        for name in RenderEngine.allTransitions {
            let overlap = RenderEngine.consumedOverlap(name, xfadeDuration: 0.7)
            #expect(overlap >= 0 && overlap <= 0.7, "\(name) consumed \(overlap)")
            if RenderEngine.transitions.contains(name) {
                #expect(overlap == 0.7, "\(name) is a crossfade")
            }
        }
    }

    @Test("regression: SQL numeric conversion never traps")
    func sqlNumericConversion() {
        #expect(SQLValue.real(.nan).intValue == nil)
        #expect(SQLValue.real(.infinity).intValue == nil)
        #expect(SQLValue.real(.greatestFiniteMagnitude).intValue == nil)
        #expect(SQLValue.text("42").intValue == 42)
        #expect(SQLValue.text("3.5").doubleValue == 3.5)
        #expect(SQLValue.text("nope").doubleValue == nil)
    }

    @Test("fight points, clip reasons, and timeline snapping")
    func modelHelpers() {
        #expect(FightScoring.points(for: "knockdown") == 8)
        #expect(FightScoring.points(for: "unknown") == 1)
        #expect(BuilderTimelineModel.snap(1.24) == 1)
        #expect(BuilderTimelineModel.snap(1.26) == 1.5)
        let json = "[{\"clip_index\":0,\"reason\":\"hook\"},{\"clip_index\":1,\"reason\":\"payoff\"}]"
        #expect(GeneratedVideoRecord.clipReasons(fromPlanClipsJSON: json) == [0: "hook", 1: "payoff"])
    }

    @Test("AI catalog labels known models and providers")
    func aiCatalog() {
        #expect(AICatalog.provider("claude")?.key == "claude")
        #expect(AICatalog.modelDisplayName("claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(AICatalog.modelDisplayName("some-unknown-model") == "some-unknown-model")
        #expect(AICatalog.modelDisplayName("claude-fable-5-1") == "Fable 5.1")
        #expect(AICatalog.modelDisplayName("gpt-6-astra") == "GPT-6 Astra")
        // Every model a provider lists has a friendly name, and every
        // recommended chain names a listed model.
        for provider in AICatalog.providers {
            for model in provider.models {
                #expect(AICatalog.modelDisplayNames[model] != nil, "\(provider.key) \(model)")
            }
        }
        for (task, chain) in AICatalog.recommendedChains {
            for link in chain {
                let listed = AICatalog.providers.first { $0.key == link.provider }?.models.contains(link.model) == true
                #expect(listed, "\(task): \(link.provider) \(link.model)")
            }
        }
        #expect(AICatalog.provider("does-not-exist") == nil)
    }
}
