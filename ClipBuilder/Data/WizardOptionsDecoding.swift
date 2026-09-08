import Foundation

nonisolated extension WizardOptions {
    init(from decoder: Decoder) throws {
        self = WizardOptions()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceSceneSelection = try values.decodeIfPresent(Bool.self, forKey: .sourceSceneSelection) ?? sourceSceneSelection
        sourceSceneIDs = try values.decodeIfPresent(Set<Int64>.self, forKey: .sourceSceneIDs) ?? sourceSceneIDs
        sourceVideoPaths = try values.decodeIfPresent(Set<String>.self, forKey: .sourceVideoPaths) ?? sourceVideoPaths
        sourcesRestricted = try values.decodeIfPresent(Bool.self, forKey: .sourcesRestricted) ?? sourcesRestricted
        stackLevel = try values.decodeIfPresent(String.self, forKey: .stackLevel) ?? stackLevel
        projectID = try values.decodeIfPresent(Int64.self, forKey: .projectID)
        renderSettings = try values.decodeIfPresent(RenderSettings.self, forKey: .renderSettings) ?? renderSettings
        pacing = try values.decodeIfPresent(EditPacing.self, forKey: .pacing) ?? pacing
        captionLanguage = try values.decodeIfPresent(String.self, forKey: .captionLanguage)
        reviewProposedCuts = try values.decodeIfPresent(Bool.self, forKey: .reviewProposedCuts) ?? reviewProposedCuts
        muteSource = try values.decodeIfPresent(Bool.self, forKey: .muteSource) ?? muteSource
        addCaptions = try values.decodeIfPresent(Bool.self, forKey: .addCaptions) ?? addCaptions
        enableTextOverlays = try values.decodeIfPresent(Bool.self, forKey: .enableTextOverlays) ?? enableTextOverlays
        useMusic = try values.decodeIfPresent(Bool.self, forKey: .useMusic) ?? useMusic
        aiInstructions = try values.decodeIfPresent(String.self, forKey: .aiInstructions) ?? aiInstructions
        useFightResearch = try values.decodeIfPresent(Bool.self, forKey: .useFightResearch) ?? useFightResearch
        selectedRunIDs = try values.decodeIfPresent(Set<Int64>.self, forKey: .selectedRunIDs) ?? selectedRunIDs
        curatedOnly = try values.decodeIfPresent(Bool.self, forKey: .curatedOnly) ?? curatedOnly
        tastePreset = try values.decodeIfPresent(String.self, forKey: .tastePreset)
        sourcePeople = try values.decodeIfPresent([String].self, forKey: .sourcePeople) ?? sourcePeople
        modelOverride = try values.decodeIfPresent(String.self, forKey: .modelOverride)
        templateJSON = try values.decodeIfPresent(String.self, forKey: .templateJSON)
        templateLabel = try values.decodeIfPresent(String.self, forKey: .templateLabel)
        targetDurationSeconds = try values.decodeIfPresent(Int.self, forKey: .targetDurationSeconds)
        framingCamera = try values.decodeIfPresent(String.self, forKey: .framingCamera) ?? framingCamera
        podcastFraming = try values.decodeIfPresent(PodcastFramingMode.self, forKey: .podcastFraming) ?? podcastFraming
        screenCropLayouts = try values.decodeIfPresent([String].self, forKey: .screenCropLayouts) ?? screenCropLayouts
        allowedTransitions = try values.decodeIfPresent([String].self, forKey: .allowedTransitions)
        pinnedOverlayTemplate = try values.decodeIfPresent(String.self, forKey: .pinnedOverlayTemplate)
        pinnedOverlayText = try values.decodeIfPresent(String.self, forKey: .pinnedOverlayText)
        formatPreset = try values.decodeIfPresent(String.self, forKey: .formatPreset) ?? formatPreset
        critiqueLoop = try values.decodeIfPresent(Bool.self, forKey: .critiqueLoop) ?? critiqueLoop
        includeWatermark = try values.decodeIfPresent(Bool.self, forKey: .includeWatermark) ?? includeWatermark
        includeHeadline = try values.decodeIfPresent(Bool.self, forKey: .includeHeadline) ?? includeHeadline
        includeOutro = try values.decodeIfPresent(Bool.self, forKey: .includeOutro) ?? includeOutro
        includeIntroBumper = try values.decodeIfPresent(Bool.self, forKey: .includeIntroBumper) ?? includeIntroBumper
        includeOutroBumper = try values.decodeIfPresent(Bool.self, forKey: .includeOutroBumper) ?? includeOutroBumper
        includeMiddleBumper = try values.decodeIfPresent(Bool.self, forKey: .includeMiddleBumper) ?? includeMiddleBumper
    }
}
