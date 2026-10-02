import Foundation
import Testing
@testable import Clip_Builder

@Suite("Pipeline phase models")
struct PipelinePhaseModelsTests {
    @Test(arguments: ReelRecipe.all)
    func phasesOnlyExposeUniqueConfigurableTasks(_ recipe: ReelRecipe) {
        for phase in PipelinePhase.allCases {
            let tasks = phase.aiTasks(recipe: recipe, useBRoll: true, brollInstructions: "Use training footage")
            #expect(tasks.allSatisfy { AICatalog.tasks.contains($0) })
            #expect(tasks.count == Set(tasks).count)
            switch phase {
            case .transcribe:
                #expect(tasks.isEmpty)
                #expect(phase.onDeviceEngine == "Apple Speech")
            case .framing:
                #expect(tasks.isEmpty)
                #expect(phase.onDeviceEngine == "Apple Vision")
            default:
                #expect(!tasks.isEmpty)
                #expect(phase.onDeviceEngine == nil)
            }
        }
    }

    @Test @MainActor func phaseTasksMatchTheirCallSites() {
        let expected: [(PipelinePhase, [String])] = [
            (.detectPeople, ["people"]),
            (.analyze, DispatchOperation.analyze.aiTasks.filter { $0 != "people" }),
            (.fightScoring, ["analysis"]),
            (.fightResearch, ["fight_research"]),
            (.proposeNames, ["naming"]),
            (.curate, ["curate"]),
            (.critique, ["critique"]),
            (.coverFrame, ["cover"]),
        ]
        for (phase, tasks) in expected {
            #expect(phase.aiTasks(recipe: .custom, useBRoll: false, brollInstructions: "") == tasks)
        }
    }

    @Test func generationUsesTheRecipeModels() {
        #expect(ReelRecipe.custom.capabilities.models != ReelRecipe.podcastHighlights.capabilities.models)
        #expect(PipelinePhase.generate.aiTasks(recipe: .custom, useBRoll: false,
                                              brollInstructions: "") == ["wizard", "captions"])
        #expect(PipelinePhase.generate.aiTasks(recipe: .podcastHighlights, useBRoll: false,
                                              brollInstructions: "") == ["highlights"])
    }

    @Test(arguments: ReelRecipe.all)
    func generationOnlyAddsRequestedSupportedBRollAndNeverCritique(_ recipe: ReelRecipe) {
        for enabled in [false, true] {
            for instructions in ["", " \n\t ", "Use training footage"] {
                let tasks = PipelinePhase.generate.aiTasks(recipe: recipe, useBRoll: enabled,
                                                           brollInstructions: instructions)
                let expectsBRoll = recipe.capabilities.bRoll && enabled
                    && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                #expect(tasks.contains("broll") == expectsBRoll)
                #expect(!tasks.contains("critique"))
                if expectsBRoll { #expect(tasks.last == "broll") }
                #expect(tasks == WizardFormPlan(recipe: recipe).models(useBRoll: enabled, instructions: instructions)
                    .filter { $0 != "critique" })
            }
        }
    }

    @Test @MainActor func pickerChoicePersistsAndResolvesWithoutOverrides() async throws {
        // The process-wide data-folder override ends before the actor await.
        let config = try persistedPickerChoice()
        let service = AIService(config: config)
        let resolved = await service.resolveProviderModel(task: "wizard")
        #expect(resolved.provider == "codex")
        #expect(resolved.model == "gpt-5.6-sol")
    }

    @MainActor
    private func persistedPickerChoice() throws -> AIConfig {
        let scope = try DataFolderOverride()
        defer { withExtendedLifetime(scope) {} }
        let settings = AppSettings()
        let profile = Fixtures.brand()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai))
        store.setTaskModel(task: "wizard", provider: "claude", model: "claude-fable-5-1")
        store.setTaskModel(task: "wizard", provider: "codex", model: "gpt-5.6-sol")
        #expect(store.settings.ai.tasks["wizard"] == "codex")
        #expect(store.settings.ai.taskModels["wizard"] == "gpt-5.6-sol")
        let saved = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: SettingsStore.settingsURL))
        #expect(saved.ai.tasks["wizard"] == "codex")
        #expect(saved.ai.taskModels["wizard"] == "gpt-5.6-sol")
        return saved.ai
    }
}
