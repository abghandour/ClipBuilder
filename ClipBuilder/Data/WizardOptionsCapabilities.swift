import Foundation

extension WizardOptions {
    /// Apply after form/request/replay overrides, without changing persisted preferences.
    nonisolated func neutralized(for recipe: ReelRecipe) -> WizardOptions {
        let capabilities = recipe.capabilities
        var options = self
        if !capabilities.fightResearch { options.useFightResearch = false }
        if !capabilities.layouts { options.screenCropLayouts = [] }
        if !capabilities.onScreenText {
            options.addCaptions = false
            options.enableTextOverlays = false
            options.captionLanguage = nil
            options.pinnedOverlayTemplate = nil
            options.pinnedOverlayText = nil
        }
        if !capabilities.audioMusic {
            options.useMusic = false
            options.muteSource = false
            options.musicFolder = nil
        }
        if !capabilities.critiqueLoop { options.critiqueLoop = false }
        if !capabilities.reviewProposedCuts { options.reviewProposedCuts = false }
        if !capabilities.bumpers {
            options.includeIntroBumper = false
            options.includeOutroBumper = false
            options.includeMiddleBumper = false
        }
        if !capabilities.branding {
            options.includeWatermark = false
            options.includeHeadline = false
            options.includeOutro = false
        }
        if !capabilities.styleReference { options.tastePreset = "none" }
        if !capabilities.bRoll {
            options.useBRoll = false
            options.brollInstructions = ""
        }
        if !capabilities.cameraFocus { options.highlightFraming = nil }
        if !capabilities.podcastFraming { options.podcastFraming = .followSpeaker }
        if !capabilities.referenceTemplate {
            options.templateJSON = nil
            options.templateLabel = nil
        }
        if capabilities.length != .targetDuration {
            options.targetDurationSeconds = nil
            options.pacing = EditPacing()
        }
        if capabilities.length != .maxSecondsAndCount {
            options.highlightMaxSeconds = nil
            options.highlightMaxCount = nil
        }
        if capabilities.sources == .podcastRecording {
            options.selectedRunIDs = []
            options.sourcePeople = []
            options.favoritesOnly = false
            options.sourceSceneSelection = false
            options.sourceSceneIDs = []
        }
        return options
    }
}
