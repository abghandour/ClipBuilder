import Foundation

/// Mini's visible presentation choices; mapping never changes the selected footage.
nonisolated struct MiniWizardSettings: Equatable, Hashable, Sendable, Codable {
    var quality: EncodeQuality = .balanced
    var preset: RenderPreset = .portrait1080
    var cameraFocus = ""
    /// Interview focus pull-back, 0 (tight) to 1 (full height).
    var interviewZoom = 0.0
    var captions = false
    var englishCaptions = false
    var captionPosition: String?
    var captionStyleID: String?
    var introVideo = false
    var outroVideo = false
    /// Bumpers for each slot by library path (travels with presets and Team
    /// Sync, unlike an absolute path); nil = any bumper that allows it.
    var introBumper: String?
    var outroBumper: String?
    var nameTags = false
    var nameTagContent: String?
    var nameTagStyle: String?
    var nameTagStyleID: String?
    var nameTagPosition: String?
    var safeAreaOnly = false
    var safeAreaPlatforms: [String]?
    var watermark = true
    /// A saved overlay used as the watermark; nil or empty = the brand logo.
    var watermarkOverlay: String?
    /// Watermark strength 0...1; nil = the design's default.
    var watermarkOpacity: Double?
    /// A saved overlay template over the finished video: starts at
    /// `overlayStart` seconds, runs `overlayDuration` seconds or to the end.
    var overlay = false
    var overlayTemplate: String?
    var overlayStart: Double = 0
    var overlayDuration: Double?
    /// Overrides for the template's AI-replaceable texts, in template order.
    var overlayTexts: [String] = []
    /// Effect at every cut: "random" or an effect name (TransitionEffect).
    var transition: String = WizardPlanRules.randomTransitionChoice
    /// A look from the Looks library (an EffectCatalog preset id such as
    /// "vintage" or "lut:kodak_portra_160_vc") graded into every clip's
    /// footage; "" = none.
    var look: String = ""
    /// Fight and training footage only: drop the source's sound.
    var muteSourceAudio = false
    /// Fight and training footage only: lay a track from the music library
    /// under the reel; `musicTrack` names it, nil = random by duration.
    var music = false
    var musicTrack: String?
    var dub = false
    var dubLanguage: String?
    var outputMode: MiniWizardFlow.OutputMode = .separateVideos

    init() {}

    enum CodingKeys: String, CodingKey {
        case quality, preset, cameraFocus, interviewZoom, captions, englishCaptions, captionPosition, captionStyleID
        case introVideo, outroVideo, introBumper, outroBumper
        case safeAreaOnly, safeAreaPlatforms
        case nameTags, nameTagContent, nameTagStyle, nameTagStyleID, nameTagPosition
        case watermark, watermarkOverlay, watermarkOpacity
        case overlay, overlayTemplate, overlayStart, overlayDuration, overlayTexts, outputMode, transition, look
        case muteSourceAudio, music, musicTrack, dub, dubLanguage
    }

    /// Saved presets: every key optional so a preset written by an older
    /// build (or a hand-edited file) still loads with defaults for the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        quality = try c.decodeIfPresent(EncodeQuality.self, forKey: .quality) ?? base.quality
        preset = try c.decodeIfPresent(RenderPreset.self, forKey: .preset) ?? base.preset
        cameraFocus = try c.decodeIfPresent(String.self, forKey: .cameraFocus) ?? base.cameraFocus
        interviewZoom = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .interviewZoom) ?? base.interviewZoom))
        captions = try c.decodeIfPresent(Bool.self, forKey: .captions) ?? base.captions
        englishCaptions = try c.decodeIfPresent(Bool.self, forKey: .englishCaptions) ?? base.englishCaptions
        captionPosition = try c.decodeIfPresent(String.self, forKey: .captionPosition)
        captionStyleID = try c.decodeIfPresent(String.self, forKey: .captionStyleID)
        introVideo = try c.decodeIfPresent(Bool.self, forKey: .introVideo) ?? base.introVideo
        outroVideo = try c.decodeIfPresent(Bool.self, forKey: .outroVideo) ?? base.outroVideo
        introBumper = try c.decodeIfPresent(String.self, forKey: .introBumper)
        outroBumper = try c.decodeIfPresent(String.self, forKey: .outroBumper)
        nameTags = try c.decodeIfPresent(Bool.self, forKey: .nameTags) ?? base.nameTags
        nameTagContent = try c.decodeIfPresent(String.self, forKey: .nameTagContent)
        nameTagStyle = try c.decodeIfPresent(String.self, forKey: .nameTagStyle)
        nameTagStyleID = try c.decodeIfPresent(String.self, forKey: .nameTagStyleID)
        safeAreaOnly = try c.decodeIfPresent(Bool.self, forKey: .safeAreaOnly) ?? false
        safeAreaPlatforms = try c.decodeIfPresent([String].self, forKey: .safeAreaPlatforms)
        nameTagPosition = try c.decodeIfPresent(String.self, forKey: .nameTagPosition)
        watermark = try c.decodeIfPresent(Bool.self, forKey: .watermark) ?? base.watermark
        watermarkOverlay = try c.decodeIfPresent(String.self, forKey: .watermarkOverlay)
        watermarkOpacity = try c.decodeIfPresent(Double.self, forKey: .watermarkOpacity)
        overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay) ?? base.overlay
        overlayTemplate = try c.decodeIfPresent(String.self, forKey: .overlayTemplate)
        overlayStart = try c.decodeIfPresent(Double.self, forKey: .overlayStart) ?? base.overlayStart
        overlayDuration = try c.decodeIfPresent(Double.self, forKey: .overlayDuration)
        overlayTexts = try c.decodeIfPresent([String].self, forKey: .overlayTexts) ?? base.overlayTexts
        outputMode = try c.decodeIfPresent(MiniWizardFlow.OutputMode.self, forKey: .outputMode) ?? base.outputMode
        transition = try c.decodeIfPresent(String.self, forKey: .transition) ?? base.transition
        look = try c.decodeIfPresent(String.self, forKey: .look) ?? base.look
        muteSourceAudio = try c.decodeIfPresent(Bool.self, forKey: .muteSourceAudio) ?? base.muteSourceAudio
        music = try c.decodeIfPresent(Bool.self, forKey: .music) ?? base.music
        musicTrack = try c.decodeIfPresent(String.self, forKey: .musicTrack)
        dub = try c.decodeIfPresent(Bool.self, forKey: .dub) ?? false
        dubLanguage = try c.decodeIfPresent(String.self, forKey: .dubLanguage)
        if quality == .custom { quality = .balanced }
        if preset == .custom { preset = .portrait1080 }
    }

    /// Preview and generation share Express's own choices and profile canvas defaults.
    func previewOptions(profile: BrandProfile, base: WizardOptions = WizardOptions()) -> WizardOptions {
        var base = base
        base.renderSettings = profile.defaultRenderSettings
        return WizardOptions.merge(step1: base.step1, step2: step2Options(base: base.step2), base: base)
    }

    func step2Options(base: WizardStep2Options) -> WizardStep2Options {
        var result = base
        var render = base.renderSettings ?? RenderSettings()
        render.quality = quality
        render.preset = preset
        result.renderSettings = render
        result.highlightFraming = CropRecipe.Kind(rawValue: cameraFocus)
        result.interviewZoom = interviewZoom
        result.podcastFraming = cameraFocus == WizardCameraFocus.original ? .original : .followSpeaker
        result.addCaptions = captions
        result.captionPosition = captionPosition
        result.captionStyleID = captionStyleID
        result.captionLanguage = englishCaptions ? "en" : nil
        result.dubLanguage = dub ? (dubLanguage ?? DubLanguageChoices.defaultLanguage) : nil
        result.includeIntroBumper = introVideo
        result.includeOutroBumper = outroVideo
        // Library paths resolve to this Mac's files in AppStore.generateMiniVideos.
        result.introBumperPath = nil
        result.outroBumperPath = nil
        result.includeWatermark = watermark
        let watermarkName = watermarkOverlay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.watermarkOverlayTemplate = watermark && !watermarkName.isEmpty ? watermarkName : nil
        result.watermarkOpacity = watermark ? watermarkOpacity.map { min(1, max(0, $0)) } : nil
        result.includeHeadline = false
        result.includeOutro = false
        result.useMusic = music
        result.muteSource = muteSourceAudio
        result.musicTrack = music ? musicTrackName : nil
        result.musicFolder = nil
        result.enableTextOverlays = nameTags
        result.nameTagsOnly = true
        result.nameTags = nameTags
        result.nameTagContent = nameTagContent
        result.nameTagStyle = nameTagStyle
        result.nameTagStyleID = nameTagStyleID
        result.nameTagPosition = nameTagPosition
        result.safeAreaOnly = safeAreaOnly
        let platforms = safeAreaPlatforms?.compactMap(SocialPlatform.init(rawValue:))
        result.safeAreaPlatforms = platforms?.isEmpty == false ? platforms : nil
        result.transitionChoice = transition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? WizardPlanRules.randomTransitionChoice : transition
        result.lookPreset = lookName
        let overlayName = overlayTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.fixedOverlayTemplate = overlay && !overlayName.isEmpty ? overlayName : nil
        result.fixedOverlayStart = result.fixedOverlayTemplate == nil ? nil : max(0, overlayStart)
        result.fixedOverlayDuration = result.fixedOverlayTemplate == nil ? nil : overlayDuration.map { max(0, $0) }
        result.fixedOverlayTexts = result.fixedOverlayTemplate == nil || overlayTexts.isEmpty ? nil : overlayTexts
        return result
    }

    /// The strength the watermark will render at: the slider value, else
    /// the design's default (logo 0.85, overlay 0.4).
    var effectiveWatermarkOpacity: Double {
        let usesOverlay = watermarkOverlay?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return min(1, max(0, watermarkOpacity ?? (usesOverlay ? WizardFixedOverlay.watermarkOpacity : BrandRenderer.logoWatermarkOpacity)))
    }

    /// The look preset the render will grade with; nil for none.
    var lookName: String? {
        let name = look.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "none" ? nil : name
    }

    /// The track the render will use; nil for a random pick from the library.
    var musicTrackName: String? {
        let name = musicTrack?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The overlay as the render will apply it; nil when off or unnamed.
    var overlayName: String? {
        let name = overlayTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return overlay && !name.isEmpty ? name : nil
    }

    /// Hidden questions must not leak a remembered answer into another video type.
    func effective(for flow: MiniWizardFlow, introAvailable: Bool, outroAvailable: Bool) -> Self {
        var result = self
        if !flow.showsCameraFocus { result.cameraFocus = "" }
        if !flow.showsNameTags { result.nameTags = false }
        if !flow.showsCaptionLanguage { result.englishCaptions = false }
        if !flow.showsAudioOptions {
            result.muteSourceAudio = false
            result.music = false
        }
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
        result.nameTagStyleID = defaults.string(forKey: key(.nameTagStyleID))
        result.nameTagPosition = defaults.string(forKey: key(.nameTagPosition))
        result.safeAreaPlatforms = defaults.stringArray(forKey: key(.safeAreaPlatforms))
        result.cameraFocus = defaults.string(forKey: key(.cameraFocus)) ?? ""
        result.interviewZoom = min(1, max(0, defaults.double(forKey: key(.interviewZoom))))
        result.overlayTemplate = defaults.string(forKey: key(.overlayTemplate))
        result.overlayTexts = defaults.stringArray(forKey: key(.overlayTexts)) ?? []
        result.watermarkOverlay = defaults.string(forKey: key(.watermarkOverlay))
        if defaults.object(forKey: key(.watermarkOpacity)) != nil {
            result.watermarkOpacity = min(1, max(0, defaults.double(forKey: key(.watermarkOpacity))))
        }
        result.introBumper = defaults.string(forKey: key(.introBumper))
        result.outroBumper = defaults.string(forKey: key(.outroBumper))
        if defaults.object(forKey: key(.overlayStart)) != nil {
            result.overlayStart = max(0, defaults.double(forKey: key(.overlayStart)))
        }
        if defaults.object(forKey: key(.overlayDuration)) != nil {
            result.overlayDuration = max(0, defaults.double(forKey: key(.overlayDuration)))
        }
        result.outputMode = MiniWizardFlow.OutputMode(rawValue: defaults.string(forKey: key(.outputMode)) ?? "")
            ?? .separateVideos
        if let transition = defaults.string(forKey: key(.transition)), !transition.isEmpty {
            result.transition = transition
        }
        result.look = defaults.string(forKey: key(.look)) ?? ""
        result.musicTrack = defaults.string(forKey: key(.musicTrack))
        result.dubLanguage = defaults.string(forKey: key(.dubLanguage)) ?? profile.editing?.footage.dubLanguage
        if defaults.object(forKey: key(.dub)) == nil { result.dub = result.dubLanguage != nil }
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
        defaults.set(nameTagStyleID, forKey: key(.nameTagStyleID))
        defaults.set(nameTagPosition, forKey: key(.nameTagPosition))
        defaults.set(safeAreaPlatforms, forKey: key(.safeAreaPlatforms))
        defaults.set(cameraFocus, forKey: key(.cameraFocus))
        defaults.set(interviewZoom, forKey: key(.interviewZoom))
        defaults.set(overlayTemplate, forKey: key(.overlayTemplate))
        defaults.set(overlayTexts, forKey: key(.overlayTexts))
        defaults.set(watermarkOverlay, forKey: key(.watermarkOverlay))
        defaults.set(watermarkOpacity, forKey: key(.watermarkOpacity))
        defaults.set(introBumper, forKey: key(.introBumper))
        defaults.set(outroBumper, forKey: key(.outroBumper))
        defaults.set(overlayStart, forKey: key(.overlayStart))
        defaults.set(overlayDuration, forKey: key(.overlayDuration))
        defaults.set(outputMode.rawValue, forKey: key(.outputMode))
        defaults.set(transition, forKey: key(.transition))
        defaults.set(look, forKey: key(.look))
        defaults.set(musicTrack, forKey: key(.musicTrack))
        defaults.set(dubLanguage, forKey: key(.dubLanguage))
        for (field, path) in Self.booleanFields { defaults.set(self[keyPath: path], forKey: key(field)) }
    }

    private static var booleanFields: [(MiniWizardMemory.Field, WritableKeyPath<Self, Bool>)] {
        [(.captions, \.captions), (.englishCaptions, \.englishCaptions), (.introVideo, \.introVideo),
         (.outroVideo, \.outroVideo), (.nameTags, \.nameTags), (.watermark, \.watermark), (.overlay, \.overlay),
         (.safeAreaOnly, \.safeAreaOnly), (.muteSourceAudio, \.muteSourceAudio), (.music, \.music), (.dub, \.dub)]
    }
}
