import Foundation

/// Saved answers for step 1; absent fields retain the current app defaults.
nonisolated struct WizardStep1Options: Codable, Sendable {
    var sourceSceneSelection: Bool?
    var sourceSceneIDs: Set<Int64>?
    var sourceVideoPaths: Set<String>?
    var sourcesRestricted: Bool?
    var selectedRunIDs: Set<Int64>?
    var favoritesOnly: Bool?
    var sourcePeople: [String]?
    var stackLevel: String?
    var projectID: Int64?
    var formatPreset: String?
    var targetDurationSeconds: Int?
    var highlightMaxSeconds: Double?
    var highlightMaxCount: Int?
    var aiInstructions: String?
    var pinnedOverlayText: String?
    var tastePreset: String?
    var useFightResearch: Bool?
    var screenCropLayouts: [String]?
    var critiqueLoop: Bool?
    var critiqueTargetScore: Int?
    var critiqueMaxVersions: Int?
    var modelOverride: String?
    var templateJSON: String?
    var templateLabel: String?
    var workflow: WizardWorkflow?
}

/// Saved answers for step 2; absent fields retain the current app defaults.
nonisolated struct WizardStep2Options: Codable, Sendable {
    var renderSettings: RenderSettings?
    var pacing: EditPacing?
    var useMusic: Bool?
    var muteSource: Bool?
    var musicFolder: String?
    var musicTrack: String?
    var addCaptions: Bool?
    var enableTextOverlays: Bool?
    var captionLanguage: String?
    var pinnedOverlayTemplate: String?
    var overlayStyle: String?
    var overlayAnimation: String?
    var overlayPlacement: String?
    var allowedTransitions: [String]?
    var highlightFraming: CropRecipe.Kind?
    var podcastFraming: PodcastFramingMode?
    var framingCamera: String?
    var useBRoll: Bool?
    var brollInstructions: String?
    var includeIntroBumper: Bool?
    var includeOutroBumper: Bool?
    var includeMiddleBumper: Bool?
    var includeWatermark: Bool?
    var includeHeadline: Bool?
    var includeOutro: Bool?
    var localHashtags: Bool?
}

nonisolated extension WizardOptions {
    var step1: WizardStep1Options {
        var result = WizardStep1Options()
        result.sourceSceneSelection = sourceSceneSelection
        result.sourceSceneIDs = sourceSceneIDs
        result.sourceVideoPaths = sourceVideoPaths
        result.sourcesRestricted = sourcesRestricted
        result.selectedRunIDs = selectedRunIDs
        result.favoritesOnly = favoritesOnly
        result.sourcePeople = sourcePeople
        result.stackLevel = stackLevel
        result.projectID = projectID
        result.formatPreset = formatPreset
        result.targetDurationSeconds = targetDurationSeconds
        result.highlightMaxSeconds = highlightMaxSeconds
        result.highlightMaxCount = highlightMaxCount
        result.aiInstructions = aiInstructions
        result.pinnedOverlayText = pinnedOverlayText
        result.tastePreset = tastePreset
        result.useFightResearch = useFightResearch
        result.screenCropLayouts = screenCropLayouts
        result.critiqueLoop = critiqueLoop
        result.critiqueTargetScore = critiqueTargetScore
        result.critiqueMaxVersions = critiqueMaxVersions
        result.modelOverride = modelOverride
        result.templateJSON = templateJSON
        result.templateLabel = templateLabel
        result.workflow = workflow
        return result
    }

    var step2: WizardStep2Options {
        var result = WizardStep2Options()
        result.renderSettings = renderSettings
        result.pacing = pacing
        result.useMusic = useMusic
        result.muteSource = muteSource
        result.musicFolder = musicFolder
        result.musicTrack = musicTrack
        result.addCaptions = addCaptions
        result.enableTextOverlays = enableTextOverlays
        result.captionLanguage = captionLanguage
        result.pinnedOverlayTemplate = pinnedOverlayTemplate
        result.overlayStyle = overlayStyle
        result.overlayAnimation = overlayAnimation
        result.overlayPlacement = overlayPlacement
        result.allowedTransitions = allowedTransitions
        result.highlightFraming = highlightFraming
        result.podcastFraming = podcastFraming
        result.framingCamera = framingCamera
        result.useBRoll = useBRoll
        result.brollInstructions = brollInstructions
        result.includeIntroBumper = includeIntroBumper
        result.includeOutroBumper = includeOutroBumper
        result.includeMiddleBumper = includeMiddleBumper
        result.includeWatermark = includeWatermark
        result.includeHeadline = includeHeadline
        result.includeOutro = includeOutro
        result.localHashtags = localHashtags
        return result
    }

    /// Merge both steps without losing fields when changing only the look.
    /// Runtime account benchmarks remain on the caller-provided base.
    static func merge(step1: WizardStep1Options, step2: WizardStep2Options,
                      base: WizardOptions = WizardOptions()) -> WizardOptions {
        var result = base
        result.sourceSceneSelection = step1.sourceSceneSelection ?? base.sourceSceneSelection
        result.sourceSceneIDs = step1.sourceSceneIDs ?? base.sourceSceneIDs
        result.sourceVideoPaths = step1.sourceVideoPaths ?? base.sourceVideoPaths
        result.sourcesRestricted = step1.sourcesRestricted ?? base.sourcesRestricted
        result.selectedRunIDs = step1.selectedRunIDs ?? base.selectedRunIDs
        result.favoritesOnly = step1.favoritesOnly ?? base.favoritesOnly
        result.sourcePeople = step1.sourcePeople ?? base.sourcePeople
        result.stackLevel = step1.stackLevel ?? base.stackLevel
        result.projectID = step1.projectID
        result.formatPreset = step1.formatPreset ?? base.formatPreset
        result.targetDurationSeconds = step1.targetDurationSeconds
        result.highlightMaxSeconds = step1.highlightMaxSeconds
        result.highlightMaxCount = step1.highlightMaxCount
        result.aiInstructions = step1.aiInstructions ?? base.aiInstructions
        result.pinnedOverlayText = step1.pinnedOverlayText
        result.tastePreset = step1.tastePreset
        result.useFightResearch = step1.useFightResearch ?? base.useFightResearch
        result.screenCropLayouts = step1.screenCropLayouts ?? base.screenCropLayouts
        result.critiqueLoop = step1.critiqueLoop ?? base.critiqueLoop
        result.critiqueTargetScore = step1.critiqueTargetScore ?? base.critiqueTargetScore
        result.critiqueMaxVersions = step1.critiqueMaxVersions ?? base.critiqueMaxVersions
        result.modelOverride = step1.modelOverride
        result.templateJSON = step1.templateJSON
        result.templateLabel = step1.templateLabel
        result.workflow = step1.workflow
        result.renderSettings = step2.renderSettings ?? base.renderSettings
        result.pacing = step2.pacing ?? base.pacing
        result.useMusic = step2.useMusic ?? base.useMusic
        result.muteSource = step2.muteSource ?? base.muteSource
        result.musicFolder = step2.musicFolder
        result.musicTrack = step2.musicTrack
        result.addCaptions = step2.addCaptions ?? base.addCaptions
        result.enableTextOverlays = step2.enableTextOverlays ?? base.enableTextOverlays
        result.captionLanguage = step2.captionLanguage
        result.pinnedOverlayTemplate = step2.pinnedOverlayTemplate
        result.overlayStyle = step2.overlayStyle
        result.overlayAnimation = step2.overlayAnimation
        result.overlayPlacement = step2.overlayPlacement
        result.allowedTransitions = step2.allowedTransitions
        result.highlightFraming = step2.highlightFraming
        result.podcastFraming = step2.podcastFraming ?? base.podcastFraming
        result.framingCamera = step2.framingCamera ?? base.framingCamera
        result.useBRoll = step2.useBRoll ?? base.useBRoll
        result.brollInstructions = step2.brollInstructions ?? base.brollInstructions
        result.includeIntroBumper = step2.includeIntroBumper ?? base.includeIntroBumper
        result.includeOutroBumper = step2.includeOutroBumper ?? base.includeOutroBumper
        result.includeMiddleBumper = step2.includeMiddleBumper ?? base.includeMiddleBumper
        result.includeWatermark = step2.includeWatermark ?? base.includeWatermark
        result.includeHeadline = step2.includeHeadline ?? base.includeHeadline
        result.includeOutro = step2.includeOutro ?? base.includeOutro
        result.localHashtags = step2.localHashtags ?? base.localHashtags
        return result
    }
}
