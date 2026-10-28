import Foundation

/// The settings Express added ahead of the Wizard (transition at every cut,
/// look, fixed overlay, watermark design and strength, per-slot bumpers),
/// read from the Wizard's `wizard.*` defaults into the options the engine
/// takes. One reader serves the Wizard page, the pipeline and Outputs.
nonisolated enum WizardExpressExtras {
    static let framingKey = "wizard.framing"
    static let transitionChoiceKey = "wizard.transitionChoice"
    static let lookPresetKey = "wizard.lookPreset"
    static let lookIntensityKey = "wizard.lookIntensity"
    static let overlayEnabledKey = "wizard.fixedOverlayOn"
    static let overlayTemplateKey = "wizard.fixedOverlayTemplate"
    static let overlayStartKey = "wizard.fixedOverlayStart"
    static let overlayDurationKey = "wizard.fixedOverlayDuration"
    /// The template's replaceable texts, newline-joined (a preset-friendly scalar).
    static let overlayTextsKey = "wizard.fixedOverlayTexts"
    /// Where the design was dragged in the preview (`custom:x,y`); empty = as designed.
    static let overlayPositionKey = "wizard.fixedOverlayPosition"
    /// Hand placements of the design's components as one JSON string (`OverlayEdits.joined`).
    static let overlayEditsKey = "wizard.fixedOverlayEdits"
    static let watermarkOverlayKey = "wizard.watermarkOverlay"
    static let watermarkOpacityKey = "wizard.watermarkOpacity"
    static let introBumperKey = "wizard.introBumper"
    static let outroBumperKey = "wizard.outroBumper"

    /// Texts can hold typed line breaks, so they are joined on a record
    /// separator; values saved before that were joined on newlines.
    static let textSeparator = "\u{1E}"
    static func joinedTexts(_ texts: [String]) -> String { texts.joined(separator: textSeparator) }
    static func splitTexts(_ joined: String?) -> [String] {
        guard let joined, !joined.isEmpty else { return [] }
        return joined.components(separatedBy: joined.contains(textSeparator) ? textSeparator : "\n")
    }

    static func storedFraming(type: VideoType, defaults: UserDefaults = .standard) -> Framing {
        if let saved = Framing.split(defaults.string(forKey: framingKey)) { return saved }
        let keys = ["highlightFraming", "podcastFraming", "interviewZoom", "interviewCuts", "interviewZoomMoves", "interviewPunchIn", "framingCamera"]
        guard keys.contains(where: { defaults.object(forKey: "wizard." + $0) != nil }) else {
            return FramingMenu.default(type: type)
        }
        var old = WizardOptions()
        old.highlightFraming = defaults.string(forKey: "wizard.highlightFraming").flatMap(CropRecipe.Kind.init(rawValue:))
        old.podcastFraming = defaults.string(forKey: "wizard.podcastFraming").flatMap(PodcastFramingMode.init(rawValue:)) ?? .followSpeaker
        old.interviewZoom = defaults.double(forKey: "wizard.interviewZoom")
        old.interviewCuts = defaults.bool(forKey: "wizard.interviewCuts")
        return Framing.legacy(from: old)
    }

    /// Apply the stored extras to `options`. `bumperPath` resolves a bumper's
    /// library path for a placement to this Mac's file, as Express does.
    static func apply(to options: inout WizardOptions, defaults: UserDefaults = .standard,
                      bumperPath: (String, BumperPlacement) -> String? = { _, _ in nil }) {
        // The request on the options wins; otherwise the stored one, converted
        // once from the retained old controls. Either way it is what Express remembers.
        options.framing = options.framing ?? Framing.split(defaults.string(forKey: framingKey)) ?? Framing.legacy(from: options)
        defaults.setIfChanged(options.framing?.joined, forKey: framingKey)
        let transition = (defaults.string(forKey: transitionChoiceKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        options.transitionChoice = transition.isEmpty ? nil : transition
        let look = (defaults.string(forKey: lookPresetKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        options.lookPreset = look.isEmpty || look == "none" ? nil : look
        if options.lookPreset != nil, defaults.object(forKey: lookIntensityKey) != nil {
            options.lookIntensity = min(1, max(0.05, defaults.double(forKey: lookIntensityKey)))
        } else {
            options.lookIntensity = nil
        }
        let overlayName = (defaults.string(forKey: overlayTemplateKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if defaults.bool(forKey: overlayEnabledKey), !overlayName.isEmpty {
            options.fixedOverlayTemplate = overlayName
            options.fixedOverlayStart = max(0, defaults.double(forKey: overlayStartKey))
            let duration = defaults.double(forKey: overlayDurationKey)
            options.fixedOverlayDuration = duration > 0 ? duration : nil
            let texts = splitTexts(defaults.string(forKey: overlayTextsKey))
            options.fixedOverlayTexts = texts.isEmpty ? nil : texts
            options.fixedOverlayPosition = defaults.string(forKey: overlayPositionKey).flatMap { CustomPosition.isCustom($0) ? $0 : nil }
            options.fixedOverlayEdits = OverlayEdits.split(defaults.string(forKey: overlayEditsKey)).trimmed
        } else {
            options.fixedOverlayTemplate = nil
            options.fixedOverlayStart = nil
            options.fixedOverlayDuration = nil
            options.fixedOverlayTexts = nil
            options.fixedOverlayPosition = nil
            options.fixedOverlayEdits = nil
        }
        let watermark = (defaults.string(forKey: watermarkOverlayKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        options.watermarkOverlayTemplate = options.includeWatermark && !watermark.isEmpty ? watermark : nil
        let opacity = defaults.double(forKey: watermarkOpacityKey)
        options.watermarkOpacity = options.includeWatermark && opacity > 0 ? min(1, opacity) : nil
        options.introBumperPath = options.includeIntroBumper
            ? defaults.string(forKey: introBumperKey).flatMap { bumperPath($0, .intro) } : nil
        options.outroBumperPath = options.includeOutroBumper
            ? defaults.string(forKey: outroBumperKey).flatMap { bumperPath($0, .outro) } : nil
    }
}
