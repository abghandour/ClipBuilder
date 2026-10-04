import Foundation

nonisolated extension WizardOptions {
    private enum LegacyKeys: String, CodingKey { case curatedOnly, reviewProposedCuts }

    static func normalizeFavoriteSettings<Value>(_ settings: [String: Value], prefix: String = "") -> [String: Value] {
        var result = settings
        let old = result.removeValue(forKey: prefix + LegacyKeys.curatedOnly.rawValue)
        if result[prefix + "favoritesOnly"] == nil { result[prefix + "favoritesOnly"] = old }
        return result
    }

    static func normalizeSettings(_ settings: [String: JSONSetting]) -> [String: JSONSetting] {
        var result = normalizeFavoriteSettings(settings)
        if let legacy = result.removeValue(forKey: "reviewProposedCuts"), result["workflow"]?.string == nil {
            result["workflow"] = .string((legacy == .bool(true) ? WizardWorkflow.reviewMoments : .automatic).rawValue)
        }
        return result
    }

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
        captionPosition = try values.decodeIfPresent(String.self, forKey: .captionPosition)
        captionStyleID = try values.decodeIfPresent(String.self, forKey: .captionStyleID)
        captionLanguage = try values.decodeIfPresent(String.self, forKey: .captionLanguage)
        workflow = try values.decodeIfPresent(WizardWorkflow.self, forKey: .workflow)
        muteSource = try values.decodeIfPresent(Bool.self, forKey: .muteSource) ?? muteSource
        addCaptions = try values.decodeIfPresent(Bool.self, forKey: .addCaptions) ?? addCaptions
        nameTags = try values.decodeIfPresent(Bool.self, forKey: .nameTags)
        nameTagContent = try values.decodeIfPresent(String.self, forKey: .nameTagContent)
        nameTagStyle = try values.decodeIfPresent(String.self, forKey: .nameTagStyle)
        nameTagPosition = try values.decodeIfPresent(String.self, forKey: .nameTagPosition)
        nameTagsOnly = try values.decodeIfPresent(Bool.self, forKey: .nameTagsOnly)
        enableTextOverlays = try values.decodeIfPresent(Bool.self, forKey: .enableTextOverlays) ?? enableTextOverlays
        useMusic = try values.decodeIfPresent(Bool.self, forKey: .useMusic) ?? useMusic
        aiInstructions = try values.decodeIfPresent(String.self, forKey: .aiInstructions) ?? aiInstructions
        useFightResearch = try values.decodeIfPresent(Bool.self, forKey: .useFightResearch) ?? useFightResearch
        selectedRunIDs = try values.decodeIfPresent(Set<Int64>.self, forKey: .selectedRunIDs) ?? selectedRunIDs
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if workflow == nil, try legacy.decodeIfPresent(Bool.self, forKey: .reviewProposedCuts) == true {
            workflow = .reviewMoments
        }
        favoritesOnly = try values.decodeIfPresent(Bool.self, forKey: .favoritesOnly)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .curatedOnly) ?? favoritesOnly
        tastePreset = try values.decodeIfPresent(String.self, forKey: .tastePreset)
        sourcePeople = try values.decodeIfPresent([String].self, forKey: .sourcePeople) ?? sourcePeople
        modelOverride = try values.decodeIfPresent(String.self, forKey: .modelOverride)
        templateJSON = try values.decodeIfPresent(String.self, forKey: .templateJSON)
        templateLabel = try values.decodeIfPresent(String.self, forKey: .templateLabel)
        targetDurationSeconds = try values.decodeIfPresent(Int.self, forKey: .targetDurationSeconds)
        framingCamera = try values.decodeIfPresent(String.self, forKey: .framingCamera) ?? framingCamera
        highlightFraming = try values.decodeIfPresent(String.self, forKey: .highlightFraming).flatMap(CropRecipe.Kind.init(rawValue:))
        useBRoll = try values.decodeIfPresent(Bool.self, forKey: .useBRoll) ?? useBRoll
        brollInstructions = try values.decodeIfPresent(String.self, forKey: .brollInstructions) ?? brollInstructions
        highlightMaxCount = try values.decodeIfPresent(Int.self, forKey: .highlightMaxCount)
        highlightMaxSeconds = try values.decodeIfPresent(Double.self, forKey: .highlightMaxSeconds).map(PodcastSettings.clampHighlightSeconds)
        podcastFraming = try values.decodeIfPresent(PodcastFramingMode.self, forKey: .podcastFraming) ?? podcastFraming
        if podcastFraming == .splitZoom {
            highlightFraming = .grid
            podcastFraming = .followSpeaker
        }
        screenCropLayouts = try values.decodeIfPresent([String].self, forKey: .screenCropLayouts) ?? screenCropLayouts
        allowedTransitions = try values.decodeIfPresent([String].self, forKey: .allowedTransitions)
        pinnedOverlayTemplate = try values.decodeIfPresent(String.self, forKey: .pinnedOverlayTemplate)
        pinnedOverlayText = try values.decodeIfPresent(String.self, forKey: .pinnedOverlayText)
        formatPreset = try values.decodeIfPresent(String.self, forKey: .formatPreset) ?? formatPreset
        critiqueLoop = try values.decodeIfPresent(Bool.self, forKey: .critiqueLoop) ?? critiqueLoop
        critiqueTargetScore = try values.decodeIfPresent(Int.self, forKey: .critiqueTargetScore) ?? critiqueTargetScore
        critiqueMaxVersions = try values.decodeIfPresent(Int.self, forKey: .critiqueMaxVersions) ?? critiqueMaxVersions
        includeWatermark = try values.decodeIfPresent(Bool.self, forKey: .includeWatermark) ?? includeWatermark
        includeHeadline = try values.decodeIfPresent(Bool.self, forKey: .includeHeadline) ?? includeHeadline
        includeOutro = try values.decodeIfPresent(Bool.self, forKey: .includeOutro) ?? includeOutro
        includeIntroBumper = try values.decodeIfPresent(Bool.self, forKey: .includeIntroBumper) ?? includeIntroBumper
        includeOutroBumper = try values.decodeIfPresent(Bool.self, forKey: .includeOutroBumper) ?? includeOutroBumper
        includeMiddleBumper = try values.decodeIfPresent(Bool.self, forKey: .includeMiddleBumper) ?? includeMiddleBumper
        musicFolder = try values.decodeIfPresent(String.self, forKey: .musicFolder)
    }
}
