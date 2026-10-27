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
        let focus = settings.cameraFocus.trimmingCharacters(in: .whitespacesAndNewlines)
        fields["interviewZoom"] = .number(settings.interviewZoom)
        fields["interviewZoomMoves"] = .bool(settings.interviewZoomMoves)
        fields["interviewCuts"] = .bool(settings.resolvedInterviewCuts)
        fields["interviewPunchIn"] = settings.interviewPunchIn.map(JSONSetting.string) ?? .null
        if focus == WizardCameraFocus.original {
            fields["podcastFraming"] = .string(PodcastFramingMode.original.rawValue)
            fields["highlightFraming"] = .null
        } else if !focus.isEmpty {
            fields["podcastFraming"] = .string(PodcastFramingMode.followSpeaker.rawValue)
            fields["highlightFraming"] = .string(focus)
        }
        fields["dubLanguage"] = settings.dub ? .string(settings.dubLanguage ?? DubLanguageChoices.defaultLanguage) : .string("")
        // Keep the remembered choice even when the toggle is off in an Express preset.
        fields["dub"] = .bool(settings.dub)
        fields["miniDubLanguage"] = settings.dubLanguage.map(JSONSetting.string) ?? .null
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
        } else if let framing = fields["highlightFraming"]?.string, CropRecipe.Kind(rawValue: framing) != nil {
            settings.cameraFocus = framing
        }
        if let zoom = fields["interviewZoom"]?.number { settings.interviewZoom = min(1, max(0, zoom)) }
        if let moves = fields["interviewZoomMoves"]?.bool { settings.interviewZoomMoves = moves }
        if let cuts = fields["interviewCuts"]?.bool { settings.interviewCuts = cuts }
        if let value = fields["interviewPunchIn"] { settings.interviewPunchIn = value.string }
        if let value = fields["dubLanguage"] {
            settings.dubLanguage = value.string.flatMap { $0.isEmpty ? nil : $0 }
            settings.dub = value.string?.isEmpty == false
        }
        if let value = fields["miniDubLanguage"] { settings.dubLanguage = value.string }
        if let value = fields["dub"]?.bool { settings.dub = value }
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
