import Foundation

/// Pure form policy. Persisted choices survive switching recipes; only the
/// controls and the options dispatched to the engine change.
nonisolated struct WizardFormPlan: Sendable {
    let capabilities: ReelRecipe.Capabilities

    init(recipe: ReelRecipe) {
        capabilities = recipe.capabilities
    }

    /// A capability transition starts a fresh review choice for the new recipe.
    static func reviewProposedCuts(podcastFraming: Bool, reviewCutsByDefault: Bool) -> Bool {
        podcastFraming && reviewCutsByDefault
    }

    static func recipeForSceneHandoff(current: ReelRecipe, lastSceneRecipeID: String) -> ReelRecipe {
        guard current.capabilities.sources != .scenes else { return current }
        guard let previous = ReelRecipe.recipe(id: lastSceneRecipeID),
              previous.capabilities.sources == .scenes else { return .custom }
        return previous
    }

    func models(useBRoll: Bool, instructions: String) -> [String] {
        capabilities.models + (capabilities.bRoll && useBRoll
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ["broll"] : [])
    }

    var copiedTextKeys: [String] {
        (capabilities.layouts ? ["framingCamera"] : [])
            + (capabilities.referenceTemplate ? ["templateLabel"] : [])
            + (capabilities.onScreenText ? ["pinnedOverlayTemplate", "pinnedOverlayText"] : [])
    }

    var copiedToggleKeys: [String] {
        (capabilities.fightResearch ? ["useFightResearch"] : [])
            + (capabilities.branding ? ["includeWatermark", "includeHeadline", "includeOutro"] : [])
    }
}
