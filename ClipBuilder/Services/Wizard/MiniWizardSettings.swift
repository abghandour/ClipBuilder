import Foundation

/// Mini's visible presentation choices; mapping never changes the selected footage.
nonisolated struct MiniWizardSettings: Equatable, Hashable, Sendable, Codable {
    var quality: EncodeQuality = .balanced
    var preset: RenderPreset = .portrait1080
    var framing = Framing()
    var cameraFocus = ""
    /// VIP focus pull-back, 0 (tight) to 1 (full height).
    var interviewZoom = 0.0
    /// VIP focus moves by zooming in place instead of panning toward the interviewer.
    var interviewZoomMoves = false
    var interviewCuts: Bool? = false
    var interviewPunchIn: String?

    /// Manual cutaways are included only after an edit or an explicit opt-in.
    var includeBRoll: Bool?
    var includesBRoll: Bool {
        get { includeBRoll ?? false }
        set { includeBRoll = newValue }
    }

    var captions = false
    var englishCaptions = false
    var captionPosition: String?
    var speakerCaptionPositions: [String: String]?
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
    var drawnPauses: Bool?
    /// Nil preserves the old, uncut speech.
    var removeFillerWords: Bool?
    var strikeHighlightStyle: String?
    var actionOverlays: Bool?
    var pauseOnContact: Bool?
    var pauseOnContactSeconds: Double?
    var slowIntoContact: Bool?
    var slowIntoContactStrength: String?
    var flashOnContact: Bool?
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
    /// Where the design was dragged in the preview (`custom:x,y`); nil = as designed.
    var overlayPosition: String?
    /// Hand placements of the design's components from the preview; empty
    /// keeps the design.
    var overlayEdits = OverlayEdits()
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

    mutating func didEditBRoll() { includeBRoll = true }

    var resolvedActionOverlays: Bool {
        get { actionOverlays == true }
        set { actionOverlays = newValue }
    }

    var resolvedSlowIntoContact: Bool {
        get { slowIntoContact == true }
        set { slowIntoContact = newValue }
    }

    var resolvedSlowIntoContactStrength: String {
        get { (StrikeImpactRules.Strength(rawValue: slowIntoContactStrength ?? "") ?? .medium).rawValue }
        set { slowIntoContactStrength = newValue }
    }

    var resolvedFlashOnContact: Bool {
        get { flashOnContact == true }
        set { flashOnContact = newValue }
    }

    var resolvedPauseOnContact: Bool {
        get { pauseOnContact == true }
        set { pauseOnContact = newValue }
    }

    var resolvedPauseOnContactSeconds: Double {
        get {
            let value = pauseOnContactSeconds ?? StrikeHighlightRules.impactHold
            return value.isFinite ? min(StrikeFreezeRules.holdRange.upperBound, max(StrikeFreezeRules.holdRange.lowerBound, value))
                : StrikeHighlightRules.impactHold
        }
        set { pauseOnContactSeconds = newValue.isFinite
            ? min(StrikeFreezeRules.holdRange.upperBound, max(StrikeFreezeRules.holdRange.lowerBound, newValue))
            : StrikeHighlightRules.impactHold }
    }

    var resolvedInterviewCuts: Bool {
        get { interviewCuts ?? false }
        set { interviewCuts = newValue }
    }

    var resolvedInterviewPunchIn: String {
        get { InterviewPunchIn(rawValue: interviewPunchIn ?? "")?.rawValue ?? InterviewPunchIn.vip.rawValue }
        set { interviewPunchIn = newValue }
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case framing
        case includeBRoll
        case quality, preset, cameraFocus, interviewZoom, interviewZoomMoves, interviewCuts, interviewPunchIn, captions, englishCaptions, captionPosition, speakerCaptionPositions, captionStyleID
        case introVideo, outroVideo, introBumper, outroBumper
        case safeAreaOnly, safeAreaPlatforms
        case nameTags, nameTagContent, nameTagStyle, nameTagStyleID, nameTagPosition
        case watermark, watermarkOverlay, watermarkOpacity
        case removeFillerWords, drawnPauses, strikeHighlightStyle
        case actionOverlays, pauseOnContact, pauseOnContactSeconds, slowIntoContact, slowIntoContactStrength, flashOnContact
        case overlay, overlayTemplate, overlayStart, overlayDuration, overlayTexts, overlayPosition, overlayEdits, outputMode, transition, look
        case muteSourceAudio, music, musicTrack, dub, dubLanguage
    }
    /// Legacy controls remain readable; new snapshots carry only Framing.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(framing, forKey: .framing)
        try c.encodeIfPresent(includeBRoll, forKey: .includeBRoll)
        try c.encodeIfPresent(quality, forKey: .quality)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encodeIfPresent(captions, forKey: .captions)
        try c.encodeIfPresent(englishCaptions, forKey: .englishCaptions)
        try c.encodeIfPresent(captionPosition, forKey: .captionPosition)
        try c.encodeIfPresent(speakerCaptionPositions, forKey: .speakerCaptionPositions)
        try c.encodeIfPresent(captionStyleID, forKey: .captionStyleID)
        try c.encodeIfPresent(introVideo, forKey: .introVideo)
        try c.encodeIfPresent(outroVideo, forKey: .outroVideo)
        try c.encodeIfPresent(introBumper, forKey: .introBumper)
        try c.encodeIfPresent(outroBumper, forKey: .outroBumper)
        try c.encodeIfPresent(safeAreaOnly, forKey: .safeAreaOnly)
        try c.encodeIfPresent(safeAreaPlatforms, forKey: .safeAreaPlatforms)
        try c.encodeIfPresent(nameTags, forKey: .nameTags)
        try c.encodeIfPresent(nameTagContent, forKey: .nameTagContent)
        try c.encodeIfPresent(nameTagStyle, forKey: .nameTagStyle)
        try c.encodeIfPresent(nameTagStyleID, forKey: .nameTagStyleID)
        try c.encodeIfPresent(nameTagPosition, forKey: .nameTagPosition)
        try c.encodeIfPresent(drawnPauses, forKey: .drawnPauses)
        try c.encodeIfPresent(removeFillerWords, forKey: .removeFillerWords)
        try c.encodeIfPresent(strikeHighlightStyle, forKey: .strikeHighlightStyle)
        try c.encodeIfPresent(actionOverlays, forKey: .actionOverlays)
        try c.encodeIfPresent(pauseOnContact, forKey: .pauseOnContact)
        try c.encodeIfPresent(pauseOnContactSeconds, forKey: .pauseOnContactSeconds)
        try c.encodeIfPresent(slowIntoContact, forKey: .slowIntoContact)
        try c.encodeIfPresent(slowIntoContactStrength, forKey: .slowIntoContactStrength)
        try c.encodeIfPresent(flashOnContact, forKey: .flashOnContact)
        try c.encodeIfPresent(watermark, forKey: .watermark)
        try c.encodeIfPresent(watermarkOverlay, forKey: .watermarkOverlay)
        try c.encodeIfPresent(watermarkOpacity, forKey: .watermarkOpacity)
        try c.encodeIfPresent(overlay, forKey: .overlay)
        try c.encodeIfPresent(overlayTemplate, forKey: .overlayTemplate)
        try c.encodeIfPresent(overlayStart, forKey: .overlayStart)
        try c.encodeIfPresent(overlayDuration, forKey: .overlayDuration)
        try c.encodeIfPresent(overlayTexts, forKey: .overlayTexts)
        try c.encodeIfPresent(overlayPosition, forKey: .overlayPosition)
        try c.encodeIfPresent(overlayEdits, forKey: .overlayEdits)
        try c.encodeIfPresent(outputMode, forKey: .outputMode)
        try c.encodeIfPresent(transition, forKey: .transition)
        try c.encodeIfPresent(look, forKey: .look)
        try c.encodeIfPresent(muteSourceAudio, forKey: .muteSourceAudio)
        try c.encodeIfPresent(music, forKey: .music)
        try c.encodeIfPresent(musicTrack, forKey: .musicTrack)
        try c.encodeIfPresent(dub, forKey: .dub)
        try c.encodeIfPresent(dubLanguage, forKey: .dubLanguage)
    }


    /// Saved presets: every key optional so a preset written by an older
    /// build (or a hand-edited file) still loads with defaults for the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        includeBRoll = try c.decodeIfPresent(Bool.self, forKey: .includeBRoll)
        quality = try c.decodeIfPresent(EncodeQuality.self, forKey: .quality) ?? base.quality
        preset = try c.decodeIfPresent(RenderPreset.self, forKey: .preset) ?? base.preset
        cameraFocus = try c.decodeIfPresent(String.self, forKey: .cameraFocus) ?? base.cameraFocus
        interviewZoom = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .interviewZoom) ?? base.interviewZoom))
        interviewZoomMoves = try c.decodeIfPresent(Bool.self, forKey: .interviewZoomMoves) ?? base.interviewZoomMoves
        interviewCuts = try c.decodeIfPresent(Bool.self, forKey: .interviewCuts) ?? base.interviewCuts
        interviewPunchIn = try c.decodeIfPresent(String.self, forKey: .interviewPunchIn)
        captions = try c.decodeIfPresent(Bool.self, forKey: .captions) ?? base.captions
        englishCaptions = try c.decodeIfPresent(Bool.self, forKey: .englishCaptions) ?? base.englishCaptions
        captionPosition = try c.decodeIfPresent(String.self, forKey: .captionPosition)
        speakerCaptionPositions = try c.decodeIfPresent([String: String].self, forKey: .speakerCaptionPositions)
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
        drawnPauses = try c.decodeIfPresent(Bool.self, forKey: .drawnPauses)
        removeFillerWords = try c.decodeIfPresent(Bool.self, forKey: .removeFillerWords)
        strikeHighlightStyle = try c.decodeIfPresent(String.self, forKey: .strikeHighlightStyle)
        actionOverlays = try c.decodeIfPresent(Bool.self, forKey: .actionOverlays)
        pauseOnContact = try c.decodeIfPresent(Bool.self, forKey: .pauseOnContact)
        pauseOnContactSeconds = try c.decodeIfPresent(Double.self, forKey: .pauseOnContactSeconds)
        slowIntoContact = try c.decodeIfPresent(Bool.self, forKey: .slowIntoContact)
        slowIntoContactStrength = try c.decodeIfPresent(String.self, forKey: .slowIntoContactStrength)
        flashOnContact = try c.decodeIfPresent(Bool.self, forKey: .flashOnContact)
        watermark = try c.decodeIfPresent(Bool.self, forKey: .watermark) ?? base.watermark
        watermarkOverlay = try c.decodeIfPresent(String.self, forKey: .watermarkOverlay)
        watermarkOpacity = try c.decodeIfPresent(Double.self, forKey: .watermarkOpacity)
        overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay) ?? base.overlay
        overlayTemplate = try c.decodeIfPresent(String.self, forKey: .overlayTemplate)
        overlayStart = try c.decodeIfPresent(Double.self, forKey: .overlayStart) ?? base.overlayStart
        overlayDuration = try c.decodeIfPresent(Double.self, forKey: .overlayDuration)
        overlayTexts = try c.decodeIfPresent([String].self, forKey: .overlayTexts) ?? base.overlayTexts
        overlayPosition = try c.decodeIfPresent(String.self, forKey: .overlayPosition)
        overlayEdits = try c.decodeIfPresent(OverlayEdits.self, forKey: .overlayEdits) ?? OverlayEdits()
        outputMode = try c.decodeIfPresent(MiniWizardFlow.OutputMode.self, forKey: .outputMode) ?? base.outputMode
        transition = try c.decodeIfPresent(String.self, forKey: .transition) ?? base.transition
        look = try c.decodeIfPresent(String.self, forKey: .look) ?? base.look
        muteSourceAudio = try c.decodeIfPresent(Bool.self, forKey: .muteSourceAudio) ?? base.muteSourceAudio
        music = try c.decodeIfPresent(Bool.self, forKey: .music) ?? base.music
        musicTrack = try c.decodeIfPresent(String.self, forKey: .musicTrack)
        dub = try c.decodeIfPresent(Bool.self, forKey: .dub) ?? false
        dubLanguage = try c.decodeIfPresent(String.self, forKey: .dubLanguage)
        framing = try c.decodeIfPresent(Framing.self, forKey: .framing) ?? Framing()
        let oldKeys: [WizardOptions.CodingKeys] = [.podcastFraming, .highlightFraming, .interviewZoom,
            .interviewZoomMoves, .interviewCuts, .interviewPunchIn, .framingCamera]
        let oldValues = try decoder.container(keyedBy: WizardOptions.CodingKeys.self)
        if !c.contains(.framing), c.contains(.cameraFocus) || oldKeys.contains(where: { oldValues.contains($0) }) {
            var old = try WizardOptions(from: decoder)
            if !cameraFocus.isEmpty {
                old.highlightFraming = CropRecipe.Kind(rawValue: cameraFocus)
                old.podcastFraming = cameraFocus == WizardCameraFocus.original ? .original : .followSpeaker
            }
            framing = Framing.legacy(from: old)
        }
        if quality == .custom { quality = .balanced }
        if preset == .custom { preset = .portrait1080 }
    }

    var legacyFraming: Framing {
        var old = WizardOptions()
        old.highlightFraming = CropRecipe.Kind(rawValue: cameraFocus)
        old.podcastFraming = cameraFocus == WizardCameraFocus.original ? .original : .followSpeaker
        old.interviewZoom = interviewZoom
        old.interviewCuts = interviewCuts
        return Framing.legacy(from: old)
    }

    /// Preview and generation share Express's own choices and profile canvas defaults.
    func previewOptions(profile: BrandProfile, base: WizardOptions = WizardOptions()) -> WizardOptions {
        var base = base
        base.renderSettings = profile.defaultRenderSettings
        return WizardOptions.merge(step1: base.step1, step2: step2Options(base: base.step2), base: base)
    }

    func step2Options(base: WizardStep2Options) -> WizardStep2Options {
        var result = base
        result.useBRoll = includesBRoll
        var render = base.renderSettings ?? RenderSettings()
        render.quality = quality
        render.preset = preset
        result.renderSettings = render
        result.framing = framing
        result.dubLanguage = dub ? (dubLanguage ?? DubLanguageChoices.defaultLanguage) : nil
        result.includeIntroBumper = introVideo
        result.includeOutroBumper = outroVideo
        // Library paths resolve to this Mac's files in AppStore.generateMiniVideos.
        result.introBumperPath = nil
        result.outroBumperPath = nil
        result.includeHeadline = false
        result.includeOutro = false
        result.useMusic = music
        result.muteSource = muteSourceAudio
        result.musicTrack = music ? musicTrackName : nil
        result.musicFolder = nil
        result.transitionChoice = transition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? WizardPlanRules.randomTransitionChoice : transition
        result.lookPreset = lookName
        applyOverlayOptions(to: &result)
        return result
    }

    /// The language the captions are shown in when it is not the one spoken:
    /// the dub's, or English. Nil with captions off or in the spoken language.
    var voiceCaptionLanguage: String? {
        guard captions else { return nil }
        if dub { return dubLanguage ?? DubLanguageChoices.defaultLanguage }
        return englishCaptions ? "en" : nil
    }

    /// The Overlays tab's choices as render options: captions, name tags,
    /// safe area, watermark, fight actions and the fixed overlay. Generate maps them here
    /// and the rough cut sheet's Overlays tab puts them back on a cut that
    /// `WizardRoughCut.options` stripped, so both render the same picture.
    func applyOverlayOptions(to result: inout WizardStep2Options) {
        result.drawnPauses = drawnPauses
        result.removeFillerWords = removeFillerWords
        result.strikeHighlightStyle = strikeHighlightStyle
        result.strikeHighlights = actionOverlays == true
        result.strikeImpactFreeze = pauseOnContact == true ? resolvedPauseOnContactSeconds : nil
        result.strikeSlowMotion = slowIntoContact == true ? resolvedSlowIntoContactStrength : nil
        result.strikeFlash = flashOnContact == true ? true : nil
        result.addCaptions = captions
        result.captionPosition = captionPosition
        result.speakerCaptionPositions = speakerCaptionPositions
        result.captionStyleID = captionStyleID
        result.captionLanguage = englishCaptions ? "en" : nil
        result.includeWatermark = watermark
        let watermarkName = watermarkOverlay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.watermarkOverlayTemplate = watermark && !watermarkName.isEmpty ? watermarkName : nil
        result.watermarkOpacity = watermark ? watermarkOpacity.map { min(1, max(0, $0)) } : nil
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
        let overlayName = overlayTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.fixedOverlayTemplate = overlay && !overlayName.isEmpty ? overlayName : nil
        result.fixedOverlayStart = result.fixedOverlayTemplate == nil ? nil : max(0, overlayStart)
        result.fixedOverlayDuration = result.fixedOverlayTemplate == nil ? nil : overlayDuration.map { max(0, $0) }
        result.fixedOverlayTexts = result.fixedOverlayTemplate == nil || overlayTexts.isEmpty ? nil : overlayTexts
        result.fixedOverlayPosition = result.fixedOverlayTemplate == nil ? nil : overlayPosition.flatMap { CustomPosition.isCustom($0) ? $0 : nil }
        result.fixedOverlayEdits = result.fixedOverlayTemplate == nil ? nil : overlayEdits.trimmed
    }

    /// These settings with `other`'s Overlays tab choices (captions, name
    /// tags, safe area, watermark, fight actions, overlay design and placements); every
    /// other choice stays. The rough cut sheet's Apply lands here.
    /// `nameTags`, `captionLanguage` and `strikeActions` say whether the sheet showed those
    /// rows: a hidden row's value was forced by `effective(for:)`, not
    /// chosen, so the page keeps its own.
    func adoptingOverlays(from other: Self, nameTags: Bool = true, captionLanguage: Bool = true, strikeActions: Bool = true) -> Self {
        var result = self
        result.drawnPauses = other.drawnPauses
        result.removeFillerWords = other.removeFillerWords
        if strikeActions {
            result.strikeHighlightStyle = other.strikeHighlightStyle
            result.actionOverlays = other.actionOverlays
            result.pauseOnContact = other.pauseOnContact
            result.pauseOnContactSeconds = other.pauseOnContactSeconds
            result.slowIntoContact = other.slowIntoContact
            result.slowIntoContactStrength = other.slowIntoContactStrength
            result.flashOnContact = other.flashOnContact
        }
        result.captions = other.captions
        if captionLanguage, other.captions { result.englishCaptions = other.englishCaptions }
        result.captionPosition = other.captionPosition
        result.speakerCaptionPositions = other.speakerCaptionPositions
        result.captionStyleID = other.captionStyleID
        if nameTags { result.nameTags = other.nameTags }
        result.nameTagContent = other.nameTagContent
        result.nameTagStyle = other.nameTagStyle
        result.nameTagStyleID = other.nameTagStyleID
        result.nameTagPosition = other.nameTagPosition
        result.safeAreaOnly = other.safeAreaOnly
        result.safeAreaPlatforms = other.safeAreaPlatforms
        result.watermark = other.watermark
        result.watermarkOverlay = other.watermarkOverlay
        result.watermarkOpacity = other.watermarkOpacity
        result.overlay = other.overlay
        result.overlayTemplate = other.overlayTemplate
        result.overlayStart = other.overlayStart
        result.overlayDuration = other.overlayDuration
        result.overlayTexts = other.overlayTexts
        result.overlayPosition = other.overlayPosition
        result.overlayEdits = other.overlayEdits
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
        if !FramingMenu.allowed(type: flow.video?.type ?? .other).contains(result.framing.subject) {
            result.framing = FramingMenu.default(type: flow.video?.type ?? .other)
        }
        if !flow.isPodcastOrInterview { result.includeBRoll = false }
        if !flow.hasTranscript, result.removeFillerWords == true {
            result.removeFillerWords = false
        }
        if !flow.showsStrikeActions {
            // Only a choice that is on is forced off: a never-set value stays
            // nil, so hiding the rows leaves untouched settings equal.
            if result.actionOverlays == true { result.actionOverlays = false }
            if result.pauseOnContact == true { result.pauseOnContact = false }
            if result.slowIntoContact == true { result.slowIntoContact = false }
            if result.flashOnContact == true { result.flashOnContact = false }
        }
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

    /// Express's starting point for a profile: every choice at its default,
    /// the canvas and quality from the profile, the dub language from the
    /// profile's footage defaults. What Reset restores.
    static func defaults(profile: BrandProfile) -> Self {
        var result = Self()
        result.quality = profile.defaultRenderSettings.quality
        result.preset = profile.defaultRenderSettings.preset
        if result.quality == .custom { result.quality = .balanced }
        if result.preset == .custom { result.preset = .portrait1080 }
        result.dubLanguage = profile.editing?.footage.dubLanguage
        result.dub = result.dubLanguage != nil
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
        if defaults.object(forKey: key(.includeBRoll)) != nil { result.includeBRoll = defaults.bool(forKey: key(.includeBRoll)) }
        let impactOptions = defaults.dictionary(forKey: MiniWizardMemory.impactOptionsKey(profileName: profile.profileName))
        result.slowIntoContact = impactOptions?["slowIntoContact"] as? Bool
        result.slowIntoContactStrength = impactOptions?["slowIntoContactStrength"] as? String
        result.flashOnContact = impactOptions?["flashOnContact"] as? Bool
        let drawingOptions = defaults.dictionary(forKey: MiniWizardMemory.drawingOptionsKey(profileName: profile.profileName))
        result.removeFillerWords = defaults.object(forKey: key(.removeFillerWords)) as? Bool
        result.drawnPauses = drawingOptions?["drawnPauses"] as? Bool
        result.strikeHighlightStyle = drawingOptions?["strikeHighlightStyle"] as? String
        if defaults.object(forKey: key(.actionOverlays)) != nil { result.actionOverlays = defaults.bool(forKey: key(.actionOverlays)) }
        if defaults.object(forKey: key(.pauseOnContact)) != nil { result.pauseOnContact = defaults.bool(forKey: key(.pauseOnContact)) }
        if defaults.object(forKey: key(.pauseOnContactSeconds)) != nil { result.pauseOnContactSeconds = defaults.double(forKey: key(.pauseOnContactSeconds)) }
        result.captionPosition = defaults.string(forKey: key(.captionPosition))
        result.speakerCaptionPositions = defaults.dictionary(forKey: key(.speakerCaptionPositions)) as? [String: String]
        result.captionStyleID = defaults.string(forKey: key(.captionStyleID))
        result.nameTagContent = defaults.string(forKey: key(.nameTagContent))
        result.nameTagStyle = defaults.string(forKey: key(.nameTagStyle))
        result.nameTagStyleID = defaults.string(forKey: key(.nameTagStyleID))
        result.nameTagPosition = defaults.string(forKey: key(.nameTagPosition))
        result.safeAreaPlatforms = defaults.stringArray(forKey: key(.safeAreaPlatforms))
        result.interviewPunchIn = defaults.string(forKey: key(.interviewPunchIn))
        result.cameraFocus = defaults.string(forKey: key(.cameraFocus)) ?? ""
        result.interviewZoom = min(1, max(0, defaults.double(forKey: key(.interviewZoom))))
        result.overlayTemplate = defaults.string(forKey: key(.overlayTemplate))
        result.overlayTexts = defaults.stringArray(forKey: key(.overlayTexts)) ?? []
        result.overlayPosition = defaults.string(forKey: key(.overlayPosition))
        result.overlayEdits = OverlayEdits.split(defaults.string(forKey: key(.overlayEdits)))
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
        if let saved = Framing.split(defaults.string(forKey: key(.framing))) {
            result.framing = saved
            // A focus frame is dragged for one video's picture; restored on
            // another video it frames nobody.
            result.framing.focusFrame = nil
        } else {
            result.framing = result.legacyFraming
            let oldFields: [MiniWizardMemory.Field] = [.cameraFocus, .interviewZoom, .interviewZoomMoves, .interviewCuts, .interviewPunchIn]
            if oldFields.contains(where: { defaults.object(forKey: key($0)) != nil }) {
                defaults.set(result.framing.joined, forKey: key(.framing))
            }
        }
        return result
    }

    /// True when any remembered key changed. Identical writes still post
    /// `didChangeNotification`, so skip them.
    @discardableResult
    func remember(profileName: String, defaults: UserDefaults = .standard) -> Bool {
        func key(_ field: MiniWizardMemory.Field) -> String { MiniWizardMemory.key(for: field, profileName: profileName) }
        var changed = false
        func set(_ value: Any?, forKey key: String) { if defaults.setIfChanged(value, forKey: key) { changed = true } }
        var impactOptions: [String: Any] = [:]
        if let slowIntoContact { impactOptions["slowIntoContact"] = slowIntoContact }
        if let slowIntoContactStrength { impactOptions["slowIntoContactStrength"] = slowIntoContactStrength }
        if let flashOnContact { impactOptions["flashOnContact"] = flashOnContact }
        set(impactOptions.isEmpty ? nil : impactOptions,
            forKey: MiniWizardMemory.impactOptionsKey(profileName: profileName))
        set(removeFillerWords, forKey: key(.removeFillerWords))
        var drawingOptions: [String: Any] = [:]
        if let drawnPauses { drawingOptions["drawnPauses"] = drawnPauses }
        if let strikeHighlightStyle { drawingOptions["strikeHighlightStyle"] = strikeHighlightStyle }
        set(drawingOptions.isEmpty ? nil : drawingOptions,
            forKey: MiniWizardMemory.drawingOptionsKey(profileName: profileName))
        set(actionOverlays, forKey: key(.actionOverlays))
        set(pauseOnContact, forKey: key(.pauseOnContact))
        set(pauseOnContactSeconds, forKey: key(.pauseOnContactSeconds))
        set(includeBRoll, forKey: key(.includeBRoll))
        set(quality.rawValue, forKey: key(.quality))
        set(preset.rawValue, forKey: key(.preset))
        set(captionPosition, forKey: key(.captionPosition))
        set(speakerCaptionPositions, forKey: key(.speakerCaptionPositions))
        set(captionStyleID, forKey: key(.captionStyleID))
        set(nameTagContent, forKey: key(.nameTagContent))
        set(nameTagStyle, forKey: key(.nameTagStyle))
        set(nameTagStyleID, forKey: key(.nameTagStyleID))
        set(nameTagPosition, forKey: key(.nameTagPosition))
        set(safeAreaPlatforms, forKey: key(.safeAreaPlatforms))
        var framing = framing
        framing.focusFrame = nil
        set(framing.joined, forKey: key(.framing))
        set(overlayTemplate, forKey: key(.overlayTemplate))
        set(overlayTexts, forKey: key(.overlayTexts))
        set(overlayPosition, forKey: key(.overlayPosition))
        set(overlayEdits.trimmed?.joined, forKey: key(.overlayEdits))
        set(watermarkOverlay, forKey: key(.watermarkOverlay))
        set(watermarkOpacity, forKey: key(.watermarkOpacity))
        set(introBumper, forKey: key(.introBumper))
        set(outroBumper, forKey: key(.outroBumper))
        set(overlayStart, forKey: key(.overlayStart))
        set(overlayDuration, forKey: key(.overlayDuration))
        set(outputMode.rawValue, forKey: key(.outputMode))
        set(transition, forKey: key(.transition))
        set(look, forKey: key(.look))
        set(musicTrack, forKey: key(.musicTrack))
        set(dubLanguage, forKey: key(.dubLanguage))
        for (field, path) in Self.booleanFields where field != .interviewCuts && field != .interviewZoomMoves {
            set(self[keyPath: path], forKey: key(field))
        }
        return changed
    }

    private static var booleanFields: [(MiniWizardMemory.Field, WritableKeyPath<Self, Bool>)] {
        [(.captions, \.captions), (.englishCaptions, \.englishCaptions), (.introVideo, \.introVideo),
         (.outroVideo, \.outroVideo), (.nameTags, \.nameTags), (.watermark, \.watermark), (.overlay, \.overlay),
         (.safeAreaOnly, \.safeAreaOnly), (.muteSourceAudio, \.muteSourceAudio), (.music, \.music), (.dub, \.dub),
         (.interviewZoomMoves, \.interviewZoomMoves), (.interviewCuts, \.resolvedInterviewCuts)]
    }
}
