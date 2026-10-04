import Foundation

/// Mini's visible presentation choices; mapping never changes the selected footage.
nonisolated struct MiniWizardSettings: Equatable, Sendable {
    var quality: EncodeQuality = .balanced
    var preset: RenderPreset = .portrait1080
    var cameraFocus = ""
    var captions = false
    var englishCaptions = false
    var captionPosition: String?
    var captionStyleID: String?
    var introVideo = false
    var outroVideo = false
    var nameTags = false
    var nameTagContent: String?
    var nameTagStyle: String?
    var nameTagPosition: String?
    var watermark = true
    var outputMode: MiniWizardFlow.OutputMode = .separateVideos

    func step2Options(base: WizardStep2Options) -> WizardStep2Options {
        var result = base
        var render = base.renderSettings ?? RenderSettings()
        render.quality = quality
        render.preset = preset
        result.renderSettings = render
        result.highlightFraming = CropRecipe.Kind(rawValue: cameraFocus)
        result.podcastFraming = cameraFocus == WizardCameraFocus.original ? .original : .followSpeaker
        result.addCaptions = captions
        result.captionPosition = captionPosition
        result.captionStyleID = captionStyleID
        result.captionLanguage = englishCaptions ? "en" : nil
        result.includeIntroBumper = introVideo
        result.includeOutroBumper = outroVideo
        result.includeWatermark = watermark
        result.includeHeadline = false
        result.includeOutro = false
        result.useMusic = false
        result.enableTextOverlays = nameTags
        result.nameTagsOnly = true
        result.nameTags = nameTags
        result.nameTagContent = nameTagContent
        result.nameTagStyle = nameTagStyle
        result.nameTagPosition = nameTagPosition
        return result
    }

    /// Hidden questions must not leak a remembered answer into another video type.
    func effective(for flow: MiniWizardFlow, introAvailable: Bool, outroAvailable: Bool) -> Self {
        var result = self
        if !flow.showsCameraFocus { result.cameraFocus = "" }
        if !flow.showsNameTags { result.nameTags = false }
        if !flow.showsCaptionLanguage { result.englishCaptions = false }
        result.introVideo = introVideo && introAvailable
        result.outroVideo = outroVideo && outroAvailable
        return result
    }

    static func remembered(profile: BrandProfile, defaults: UserDefaults = .standard) -> Self {
        func key(_ field: MiniWizardMemory.Field) -> String { MiniWizardMemory.key(for: field, profileName: profile.profileName) }
        var result = Self()
        result.quality = EncodeQuality(rawValue: defaults.string(forKey: key(.quality)) ?? "")
            ?? profile.defaultRenderSettings.quality
        result.preset = RenderPreset(rawValue: defaults.string(forKey: key(.preset)) ?? "")
            ?? profile.defaultRenderSettings.preset
        if result.quality == .custom { result.quality = .balanced }
        if result.preset == .custom { result.preset = .portrait1080 }
        result.captionPosition = defaults.string(forKey: key(.captionPosition))
        result.captionStyleID = defaults.string(forKey: key(.captionStyleID))
        result.nameTagContent = defaults.string(forKey: key(.nameTagContent))
        result.nameTagStyle = defaults.string(forKey: key(.nameTagStyle))
        result.nameTagPosition = defaults.string(forKey: key(.nameTagPosition))
        result.cameraFocus = defaults.string(forKey: key(.cameraFocus)) ?? ""
        result.outputMode = MiniWizardFlow.OutputMode(rawValue: defaults.string(forKey: key(.outputMode)) ?? "")
            ?? .separateVideos
        result.watermark = WizardDefaults.brandingMode(defaults: defaults).includeWatermark
        for (field, path) in booleanFields {
            if defaults.object(forKey: key(field)) != nil { result[keyPath: path] = defaults.bool(forKey: key(field)) }
        }
        return result
    }

    func remember(profileName: String, defaults: UserDefaults = .standard) {
        func key(_ field: MiniWizardMemory.Field) -> String { MiniWizardMemory.key(for: field, profileName: profileName) }
        defaults.set(quality.rawValue, forKey: key(.quality))
        defaults.set(preset.rawValue, forKey: key(.preset))
        defaults.set(captionPosition, forKey: key(.captionPosition))
        defaults.set(captionStyleID, forKey: key(.captionStyleID))
        defaults.set(nameTagContent, forKey: key(.nameTagContent))
        defaults.set(nameTagStyle, forKey: key(.nameTagStyle))
        defaults.set(nameTagPosition, forKey: key(.nameTagPosition))
        defaults.set(cameraFocus, forKey: key(.cameraFocus))
        defaults.set(outputMode.rawValue, forKey: key(.outputMode))
        for (field, path) in Self.booleanFields { defaults.set(self[keyPath: path], forKey: key(field)) }
    }

    private static var booleanFields: [(MiniWizardMemory.Field, WritableKeyPath<Self, Bool>)] {
        [(.captions, \.captions), (.englishCaptions, \.englishCaptions), (.introVideo, \.introVideo),
         (.outroVideo, \.outroVideo), (.nameTags, \.nameTags), (.watermark, \.watermark)]
    }
}
