import Foundation
import Testing
@testable import Clip_Builder

@Suite("Reel recipes")
struct ReelRecipeTests {
    @Test("Every recipe has a unique id, a title, and a summary; all but Custom carry a format block")
    func catalogInvariants() {
        let ids = ReelRecipe.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ReelRecipe.all.first?.id == ReelRecipe.customID)
        for recipe in ReelRecipe.all {
            #expect(!recipe.title.isEmpty)
            #expect(!recipe.summary.isEmpty, "\(recipe.id) needs a summary for the Wizard caption")
            #expect(!recipe.summary.hasSuffix(" "))
            if recipe.id == ReelRecipe.customID {
                #expect(recipe.promptBlock.isEmpty)
            } else {
                #expect(recipe.promptBlock.contains("## FORMAT:"), "\(recipe.id) needs a planner format block")
                #expect(recipe.promptBlock.contains("hard requirements"))
            }
        }
    }

    @Test("The picker sections cover the persisted ids the app has always used")
    func knownIDs() {
        let expected = ["custom", "mma-finish", "mma-submission", "mma-exchange", "mma-technique",
                        "recap", "compilation", "interview", "podcast", "podcast_highlights"]
        #expect(ReelRecipe.all.map(\.id) == expected)
        #expect(ReelRecipe.menuSections.count == 3)
    }

    @Test("Prompt block lookup is empty for Custom, learned types, and unknown ids")
    func promptLookup() {
        #expect(ReelRecipe.promptBlock(for: "custom").isEmpty)
        #expect(ReelRecipe.promptBlock(for: "cat:walkouts").isEmpty)
        #expect(ReelRecipe.promptBlock(for: "nope").isEmpty)
        #expect(ReelRecipe.promptBlock(for: "recap").contains("## FORMAT: FIGHT RECAP"))
        #expect(ReelRecipe.recipe(id: "mma-exchange")?.title == "MMA exchange")
    }

    @Test("Every recipe declares the expected capability table", arguments: ReelRecipe.all)
    func capabilityTable(_ recipe: ReelRecipe) {
        let c = recipe.capabilities
        let highlights = recipe.id == "podcast_highlights"
        let spoken = ["interview", "podcast"].contains(recipe.id)
        let custom = recipe.id == "custom"
        #expect(c.sources == (highlights ? .podcastRecording : .scenes))
        #expect(c.length == (highlights ? .maxSecondsAndCount : .targetDuration))
        #expect(c.podcastFraming == (spoken || custom))
        #expect(c.cameraFocus == highlights)
        #expect(c.bRoll == (spoken || custom || highlights))
        #expect(c.fightResearch == (!spoken && !highlights))
        #expect(c.layouts == (!spoken && !highlights))
        #expect(c.audioMusic == !highlights)
        #expect(c.onScreenText == !highlights)
        #expect(c.critiqueLoop == !highlights)
        #expect(c.reviewProposedCuts == !highlights)
        #expect(c.styleReference == !highlights)
        #expect(c.bumpers == !highlights)
        #expect(c.branding == !highlights)
        #expect(c.referenceTemplate == !highlights)
        #expect(c.models == (highlights ? ["highlights"] : ["wizard", "critique", "captions"]))
    }

    @Test("Hidden options are neutral; every other encoded option is preserved", arguments: ReelRecipe.all)
    func neutralization(_ recipe: ReelRecipe) throws {
        var original = WizardOptions()
        original.formatPreset = recipe.id
        original.projectID = 42
        original.useFightResearch = true
        original.screenCropLayouts = ["Two people"]
        original.addCaptions = true
        original.enableTextOverlays = true
        original.captionLanguage = "fr"
        original.pinnedOverlayTemplate = "Name"
        original.pinnedOverlayText = "Speaker"
        original.useMusic = true
        original.muteSource = true
        original.musicFolder = "Music"
        original.critiqueLoop = true
        original.reviewProposedCuts = true
        original.includeIntroBumper = true
        original.includeOutroBumper = true
        original.includeMiddleBumper = true
        original.includeWatermark = true
        original.includeHeadline = true
        original.includeOutro = true
        original.tastePreset = "cat:test"
        original.useBRoll = true
        original.brollInstructions = "Show the guest's fight"
        original.highlightFraming = CropRecipe.Kind.allCases.first
        original.podcastFraming = .splitZoom
        original.templateJSON = "{}"
        original.templateLabel = "Reference"
        original.targetDurationSeconds = 22
        original.pacing = EditPacing(cadence: .twoSeconds, curve: .accelerate)
        original.highlightMaxSeconds = 30
        original.highlightMaxCount = 4
        original.selectedRunIDs = [1]
        original.sourcePeople = ["guest"]
        original.favoritesOnly = true
        original.sourceSceneSelection = true
        original.sourceSceneIDs = [2]
        original.sourcesRestricted = true
        original.sourceVideoPaths = ["recording.mp4"]
        original.modelOverride = "model"
        original.aiInstructions = "Keep the reaction"
        original.allowedTransitions = ["cut"]

        let encoder = JSONEncoder()
        func json(_ options: WizardOptions) throws -> [String: JSONSetting] {
            try JSONDecoder().decode([String: JSONSetting].self, from: encoder.encode(options))
        }
        var expected = try json(original)
        let highlights = recipe.id == "podcast_highlights"
        let spoken = ["interview", "podcast"].contains(recipe.id)
        let fight = !highlights && !spoken && recipe.id != "custom"
        if highlights || spoken {
            expected["useFightResearch"] = .bool(false)
            expected["screenCropLayouts"] = .array([])
        }
        if highlights {
            for key in ["addCaptions", "enableTextOverlays", "useMusic", "muteSource", "critiqueLoop",
                        "reviewProposedCuts", "includeIntroBumper", "includeOutroBumper", "includeMiddleBumper",
                        "includeWatermark", "includeHeadline", "includeOutro", "favoritesOnly", "sourceSceneSelection"] {
                expected[key] = .bool(false)
            }
            for key in ["captionLanguage", "pinnedOverlayTemplate", "pinnedOverlayText", "musicFolder",
                        "templateJSON", "templateLabel", "targetDurationSeconds"] {
                expected.removeValue(forKey: key)
            }
            for key in ["selectedRunIDs", "sourcePeople", "sourceSceneIDs"] { expected[key] = .array([]) }
            expected["tastePreset"] = .string("none")
            expected["pacing"] = try json(WizardOptions())["pacing"]
        } else {
            expected.removeValue(forKey: "highlightFraming")
            expected.removeValue(forKey: "highlightMaxSeconds")
            expected.removeValue(forKey: "highlightMaxCount")
        }
        if highlights || fight {
            expected["podcastFraming"] = try json(WizardOptions())["podcastFraming"]
        }
        if fight {
            expected["useBRoll"] = .bool(false)
            expected["brollInstructions"] = .string("")
        }
        let result = original.neutralized(for: recipe)
        #expect(try json(result) == expected)
        #expect(try json(result.neutralized(for: recipe)) == expected)
        #expect(original.useFightResearch && original.reviewProposedCuts && original.highlightMaxCount == 4)
    }

    @Test("Form policy uses capabilities and only offers the B-roll model with instructions", arguments: ReelRecipe.all)
    func formPlan(_ recipe: ReelRecipe) {
        let plan = WizardFormPlan(recipe: recipe)
        #expect(plan.capabilities == recipe.capabilities)
        #expect(plan.models(useBRoll: true, instructions: " \n ") == recipe.capabilities.models)
        #expect(plan.models(useBRoll: false, instructions: "guest footage") == recipe.capabilities.models)
        #expect(plan.models(useBRoll: true, instructions: "guest footage")
                == recipe.capabilities.models + (recipe.capabilities.bRoll ? ["broll"] : []))
        #expect(plan.copiedTextKeys.contains("templateLabel") == recipe.capabilities.referenceTemplate)
        #expect(plan.copiedTextKeys.contains("pinnedOverlayText") == recipe.capabilities.onScreenText)
        #expect(plan.copiedToggleKeys.contains("useFightResearch") == recipe.capabilities.fightResearch)
        #expect(plan.copiedToggleKeys.contains("includeOutro") == recipe.capabilities.branding)
    }

    @Test("Podcast recipes have distinct titles and follow Interview in the menu")
    func spokenMenuTitles() {
        #expect(ReelRecipe.menuSections.last?.suffix(3).map(\.title) == [
            "Interview clip", "Podcast clip · One reel", "Podcast highlights · Multiple reels",
        ])
        #expect(ReelRecipe.podcast.id == "podcast")
        #expect(ReelRecipe.podcast.summary.contains("One complete question-and-answer exchange"))
        #expect(ReelRecipe.podcast.promptBlock.contains("Choose exactly one scene"))
    }

    @Test("Entering podcast framing arms review from Settings; leaving disarms it",
          arguments: [true, false])
    func reviewCutsTransition(reviewByDefault: Bool) {
        var review = false
        review = WizardFormPlan.reviewProposedCuts(podcastFraming: true, reviewCutsByDefault: reviewByDefault)
        #expect(review == reviewByDefault)
        // Even a manually armed review choice must not leak into the next recipe.
        review = true
        review = WizardFormPlan.reviewProposedCuts(podcastFraming: false, reviewCutsByDefault: reviewByDefault)
        #expect(!review)
        review = WizardFormPlan.reviewProposedCuts(podcastFraming: true, reviewCutsByDefault: reviewByDefault)
        #expect(review == reviewByDefault)
    }

    @Test("Scene handoffs preserve scene recipes and restore a valid previous recipe",
          arguments: ReelRecipe.all)
    func sceneHandoffRecipe(_ recipe: ReelRecipe) {
        let result = WizardFormPlan.recipeForSceneHandoff(current: recipe, lastSceneRecipeID: "mma-finish")
        #expect(result == (recipe.capabilities.sources == .scenes ? recipe : .mmaFinish))
        for invalid in ["", "unknown", "podcast_highlights"] {
            let fallback = WizardFormPlan.recipeForSceneHandoff(current: recipe, lastSceneRecipeID: invalid)
            #expect(fallback == (recipe.capabilities.sources == .scenes ? recipe : .custom))
        }
    }
}
