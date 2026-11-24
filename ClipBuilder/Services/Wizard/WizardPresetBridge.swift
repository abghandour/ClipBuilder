import Foundation

/// Express settings are a projection of the Wizard's answers. This bridge
/// maps between the two shapes so a preset saved on either page loads on the
/// other: fields Express does not show keep the Wizard's defaults, and Wizard
/// fields with no Express control are left untouched.
nonisolated enum WizardPresetBridge {
    /// The Wizard-shaped dictionary for Express settings.
    static func wizardFields(from settings: MiniWizardSettings) -> [String: JSONSetting] {
        var fields: [String: JSONSetting] = [:]
        var render = RenderSettings()
        render.quality = settings.quality
        render.preset = settings.preset
        fields["renderSettings"] = JSONSetting.dictionaryValue(render)
        fields["framing"] = .string(settings.framing.joined)
        fields["dubLanguage"] = settings.dub ? .string(settings.dubLanguage ?? DubLanguageChoices.defaultLanguage) : .string("")
        // Keep the remembered choice even when the toggle is off in an Express preset.
        fields["dub"] = .bool(settings.dub)
        fields["miniDubLanguage"] = settings.dubLanguage.map(JSONSetting.string) ?? .null
        fields["drawnPauses"] = settings.drawnPauses.map(JSONSetting.bool) ?? .null
        fields["removeFillerWords"] = settings.removeFillerWords.map(JSONSetting.bool) ?? .null
        fields["strikeHighlightStyle"] = settings.strikeHighlightStyle.map(JSONSetting.string) ?? .null
        fields["strikeHighlights"] = settings.actionOverlays.map(JSONSetting.bool) ?? .null
        fields["strikeImpactFreeze"] = settings.pauseOnContact == true ? .number(settings.resolvedPauseOnContactSeconds) : .null
        // Off is sent too, so a preset saved with these untouched switches them off in the Wizard.
        fields["strikeSlowMotion"] = settings.slowIntoContact == true ? .string(settings.resolvedSlowIntoContactStrength) : .null
        fields["strikeFlash"] = settings.flashOnContact == true ? .bool(true) : .null
        if let value = settings.slowIntoContact { fields["slowIntoContact"] = .bool(value) }
        if let value = settings.slowIntoContactStrength { fields["slowIntoContactStrength"] = .string(value) }
        if let value = settings.flashOnContact { fields["flashOnContact"] = .bool(value) }
        fields["pauseOnContact"] = settings.pauseOnContact.map(JSONSetting.bool) ?? .null
        fields["pauseOnContactSeconds"] = settings.pauseOnContactSeconds.map(JSONSetting.number) ?? .null
        fields["addCaptions"] = .bool(settings.captions)
        fields["captionPosition"] = settings.captionPosition.map(JSONSetting.string) ?? .null
        fields["speakerCaptionPositions"] = settings.speakerCaptionPositions.map(JSONSetting.dictionaryValue) ?? .null
        fields["captionStyleID"] = settings.captionStyleID.map(JSONSetting.string) ?? .null
        fields["captionLanguage"] = settings.englishCaptions ? .string("en") : .null
        fields["includeIntroBumper"] = .bool(settings.introVideo)
        fields["includeOutroBumper"] = .bool(settings.outroVideo)
        fields["introBumperLibraryPath"] = settings.introBumper.map(JSONSetting.string) ?? .null
        fields["outroBumperLibraryPath"] = settings.outroBumper.map(JSONSetting.string) ?? .null
        fields["nameTags"] = .bool(settings.nameTags)
        fields["nameTagContent"] = settings.nameTagContent.map(JSONSetting.string) ?? .null
        fields["nameTagStyle"] = settings.nameTagStyle.map(JSONSetting.string) ?? .null
        fields["nameTagStyleID"] = settings.nameTagStyleID.map(JSONSetting.string) ?? .null
        fields["nameTagPosition"] = settings.nameTagPosition.map(JSONSetting.string) ?? .null
        fields["safe_area_only"] = .bool(settings.safeAreaOnly)
        fields["safe_area_platforms"] = settings.safeAreaPlatforms.map { .array($0.map(JSONSetting.string)) } ?? .null
        fields["includeWatermark"] = .bool(settings.watermark)
        fields["includeHeadline"] = .bool(false)
        fields["includeOutro"] = .bool(false)
        fields["watermarkOverlayTemplate"] = settings.watermarkOverlay.flatMap { $0.isEmpty ? nil : .string($0) } ?? .null
        fields["watermarkOpacity"] = settings.watermarkOpacity.map { .number($0) } ?? .null
        fields["fixedOverlayEnabled"] = .bool(settings.overlay)
        fields["fixedOverlayTemplate"] = settings.overlayTemplate.flatMap { $0.isEmpty ? nil : .string($0) } ?? .null
        fields["fixedOverlayStart"] = .number(settings.overlayStart)
        fields["fixedOverlayDuration"] = settings.overlayDuration.map { .number($0) } ?? .null
        fields["fixedOverlayTextsJoined"] = settings.overlayTexts.isEmpty ? .null : .string(WizardExpressExtras.joinedTexts(settings.overlayTexts))
        fields["fixedOverlayPosition"] = settings.overlayPosition.flatMap { CustomPosition.isCustom($0) ? .string($0) : nil } ?? .null
        fields["fixedOverlayEdits"] = settings.overlayEdits.trimmed.map { .string($0.joined) } ?? .null
        fields["transitionChoice"] = .string(settings.transition)
        fields["lookPreset"] = settings.lookName.map(JSONSetting.string) ?? .null
        fields["outputMode"] = .string(settings.outputMode.rawValue)
        fields["useMusic"] = .bool(settings.music)
        // Unset means off in Express, but a missing key means on in the
        // Wizard: the choice always travels as what Express would do.
        fields["useBRoll"] = .bool(settings.includesBRoll)
        fields["muteSource"] = .bool(settings.muteSourceAudio)
        fields["musicTrack"] = settings.musicTrackName.map(JSONSetting.string) ?? .null
        return fields
    }

    /// Express settings read from a Wizard-shaped dictionary; anything the
    /// dictionary lacks keeps Express's defaults.
    static func miniSettings(from fields: [String: JSONSetting], base: MiniWizardSettings = MiniWizardSettings()) -> MiniWizardSettings {
        var settings = base
        if let render: RenderSettings = fields["renderSettings"]?.decodeValue() {
            settings.quality = render.quality == .custom ? .balanced : render.quality
            settings.preset = render.preset == .custom ? .portrait1080 : render.preset
        }
        if fields["podcastFraming"]?.string == PodcastFramingMode.original.rawValue {
            settings.cameraFocus = WizardCameraFocus.original
        } else if fields["podcastFraming"]?.string == PodcastFramingMode.splitZoom.rawValue {
            settings.cameraFocus = CropRecipe.Kind.grid.rawValue
        } else if let framing = fields["highlightFraming"]?.string, CropRecipe.Kind(rawValue: framing) != nil {
            settings.cameraFocus = framing
        } else if let focus = fields["cameraFocus"]?.string {
            settings.cameraFocus = focus
        }
        if let zoom = fields["interviewZoom"]?.number { settings.interviewZoom = min(1, max(0, zoom)) }
        if let moves = fields["interviewZoomMoves"]?.bool { settings.interviewZoomMoves = moves }
        if let cuts = fields["interviewCuts"]?.bool { settings.interviewCuts = cuts }
        if let value = fields["interviewPunchIn"] { settings.interviewPunchIn = value.string }
        if let value = fields["framing"] {
            settings.framing = Framing.split(value.string) ?? value.decodeValue() ?? Framing()
        } else if ["podcastFraming", "highlightFraming", "cameraFocus", "interviewZoom", "interviewZoomMoves", "interviewCuts", "interviewPunchIn", "framingCamera"].contains(where: { fields[$0] != nil }) {
            settings.framing = settings.legacyFraming
        }
        if let value = fields["dubLanguage"] {
            settings.dubLanguage = value.string.flatMap { $0.isEmpty ? nil : $0 }
            settings.dub = value.string?.isEmpty == false
        }
        if let value = fields["miniDubLanguage"] { settings.dubLanguage = value.string }
        if let value = fields["dub"]?.bool { settings.dub = value }
        if let value = fields["drawnPauses"] { settings.drawnPauses = value.bool }
        if let value = fields["removeFillerWords"] { settings.removeFillerWords = value.bool }
        if let value = fields["strikeHighlightStyle"] { settings.strikeHighlightStyle = value.string }
        if let value = fields["strikeHighlights"] { settings.actionOverlays = value.bool }
        if let value = fields["strikeImpactFreeze"] {
            settings.pauseOnContact = (value.number ?? 0) > 0
            settings.pauseOnContactSeconds = value.number
        }
        if let value = fields["strikeSlowMotion"] {
            // Off from the Wizard reads as untouched; Express's own keys below say off explicitly.
            settings.slowIntoContact = value.string?.isEmpty == false ? true : nil
            settings.slowIntoContactStrength = value.string
        }
        if let value = fields["strikeFlash"] { settings.flashOnContact = value.bool }
        if let value = fields["slowIntoContact"] { settings.slowIntoContact = value.bool }
        if let value = fields["slowIntoContactStrength"] { settings.slowIntoContactStrength = value.string }
        if let value = fields["flashOnContact"] { settings.flashOnContact = value.bool }
        if let value = fields["pauseOnContact"] { settings.pauseOnContact = value.bool }
        if let value = fields["pauseOnContactSeconds"] { settings.pauseOnContactSeconds = value.number }
        if let captions = fields["addCaptions"]?.bool { settings.captions = captions }
        if let value = fields["captionPosition"] { settings.captionPosition = value.string }
        if let value = fields["speakerCaptionPositions"] { settings.speakerCaptionPositions = value.decodeValue() }
        if let value = fields["captionStyleID"] { settings.captionStyleID = value.string }
        if let language = fields["captionLanguage"] { settings.englishCaptions = language.string?.lowercased().hasPrefix("en") == true }
        if let intro = fields["includeIntroBumper"]?.bool { settings.introVideo = intro }
        if let outro = fields["includeOutroBumper"]?.bool { settings.outroVideo = outro }
        if let value = fields["introBumperLibraryPath"] { settings.introBumper = value.string }
        if let value = fields["outroBumperLibraryPath"] { settings.outroBumper = value.string }
        if let tags = fields["nameTags"]?.bool { settings.nameTags = tags }
        if let value = fields["nameTagContent"] { settings.nameTagContent = value.string }
        if let value = fields["nameTagStyle"] { settings.nameTagStyle = value.string }
        if let value = fields["nameTagStyleID"] { settings.nameTagStyleID = value.string }
        if let value = fields["nameTagPosition"] { settings.nameTagPosition = value.string }
        if let value = fields["safe_area_only"]?.bool { settings.safeAreaOnly = value }
        if let value = fields["safe_area_platforms"] {
            settings.safeAreaPlatforms = value.decodeValue()
        }
        if let watermark = fields["includeWatermark"]?.bool { settings.watermark = watermark }
        if let value = fields["watermarkOverlayTemplate"] { settings.watermarkOverlay = value.string }
        if let value = fields["watermarkOpacity"] { settings.watermarkOpacity = value.number }
        if let enabled = fields["fixedOverlayEnabled"]?.bool { settings.overlay = enabled }
        if let value = fields["fixedOverlayTemplate"] { settings.overlayTemplate = value.string }
        if let start = fields["fixedOverlayStart"]?.number { settings.overlayStart = max(0, start) }
        if let value = fields["fixedOverlayDuration"] { settings.overlayDuration = value.number.map { max(0, $0) } }
        if let value = fields["fixedOverlayTextsJoined"] { settings.overlayTexts = WizardExpressExtras.splitTexts(value.string) }
        if let value = fields["fixedOverlayPosition"] { settings.overlayPosition = value.string.flatMap { CustomPosition.isCustom($0) ? $0 : nil } }
        if let value = fields["fixedOverlayEdits"] { settings.overlayEdits = OverlayEdits.split(value.string) }
        if let transition = fields["transitionChoice"]?.string, !transition.isEmpty { settings.transition = transition }
        if let value = fields["lookPreset"] { settings.look = value.string ?? "" }
        if let mode = fields["outputMode"]?.string.flatMap(MiniWizardFlow.OutputMode.init(rawValue:)) { settings.outputMode = mode }
        if let music = fields["useMusic"]?.bool { settings.music = music }
        // An untouched choice stays untouched when the dictionary agrees with it.
        if let value = fields["useBRoll"], (value.bool ?? false) != settings.includesBRoll {
            settings.includesBRoll = value.bool ?? false
        }
        if let mute = fields["muteSource"]?.bool { settings.muteSourceAudio = mute }
        if let value = fields["musicTrack"] { settings.musicTrack = value.string }
        return settings
    }

    /// Express presets as Wizard presets, for the Wizard's Load sheet.
    static func wizardPresets(from presets: [MiniWizardPreset]) -> [WizardPreset] {
        presets.map { WizardPreset(name: $0.name, savedAt: $0.savedAt, settings: wizardFields(from: $0.settings)) }
    }

    /// Wizard presets as Express presets, for the Express Load sheet.
    static func miniPresets(from presets: [WizardPreset]) -> [MiniWizardPreset] {
        presets.map { MiniWizardPreset(name: $0.name, savedAt: $0.savedAt, settings: miniSettings(from: $0.settings)) }
    }
}
