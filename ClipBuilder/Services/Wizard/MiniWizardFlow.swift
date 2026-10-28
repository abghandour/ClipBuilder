import Foundation

/// Pure visibility and navigation rules for Express's cards.
nonisolated struct MiniWizardFlow: Sendable {
    enum Card: String, CaseIterable, Sendable {
        case source, footage, broll, settings
    }

    enum FootageKind: String, CaseIterable, Sendable {
        case qa, highlights, transcript, fightMetrics

        var label: String {
            switch self {
            case .qa: "Q&A"
            case .highlights: "Highlights"
            case .transcript: "Transcript"
            case .fightMetrics: "Fight metrics"
            }
        }
    }

    enum Length: String, CaseIterable, Sendable {
        case ten = "10", fifteen = "15", thirty = "30", automatic = "auto"

        var seconds: Int? { Int(rawValue) }
        var label: String { seconds.map { "\($0) s" } ?? "Auto" }
    }

    typealias SettingsTab = WizardSettingsTab

    enum OutputMode: String, CaseIterable, Codable, Sendable {
        case separateVideos, oneReel

        var label: String { self == .oneReel ? "One reel" : "Separate videos" }
    }

    var video: VideoRecord?
    var hasPodcastExchangeScenes = false
    /// The video has an original transcript, so passages can be picked from it.
    var hasTranscript = false
    var footageKind: FootageKind = .highlights
    var length: Length = .automatic
    var captionsEnabled = false
    var transcriptLanguage: String?
    var hasFootage = false
    var hasKeptFootage = false
    var requestedCard: Card = .source
    /// The open card the user collapsed by clicking its header; cleared by
    /// the next header click or navigation.
    var collapsedCard: Card?
    var outputMode: OutputMode = .separateVideos

    var isPodcastOrInterview: Bool {
        guard let video else { return false }
        return video.type == .podcast || video.type == .interview || hasPodcastExchangeScenes
    }

    /// Fight and training footage: scored actions to pick from, and audio
    /// choices (mute the source, music) that make no sense for talk.
    var isFightOrTraining: Bool {
        guard let video else { return false }
        return video.type == .fight || video.type == .training
    }

    /// Order: Q&A, Transcript, Fight metrics, Highlights. The kinds that need no AI come first.
    var footageKinds: [FootageKind] {
        (isPodcastOrInterview ? [.qa] : []) + (hasTranscript ? [.transcript] : [])
            + (isFightOrTraining ? [.fightMetrics] : []) + [.highlights]
    }
    var showsFootageKind: Bool { footageKinds.count > 1 }
    /// A remembered Q&A or Transcript choice must never apply to footage that cannot offer it.
    var effectiveFootageKind: FootageKind { footageKinds.contains(footageKind) ? footageKind : .highlights }
    var showsLength: Bool { effectiveFootageKind == .highlights }
    var lengthOptions: [Length] { Length.allCases }
    var showsCameraFocus: Bool { isPodcastOrInterview }
    var showsAudioOptions: Bool { isFightOrTraining }

    /// Every source can be dubbed; Music and mute retain their own footage rules.
    var settingsTabs: [SettingsTab] { SettingsTab.available(audio: true) }
    /// A remembered tab that this footage does not offer opens Picture.
    func effectiveSettingsTab(_ tab: SettingsTab) -> SettingsTab { tab.effective(in: settingsTabs) }
    var showsNameTags: Bool { isPodcastOrInterview }

    var showsCaptionLanguage: Bool {
        guard captionsEnabled, let transcriptLanguage else { return false }
        let language = transcriptLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !language.isEmpty, language != "und", language != "unknown" else { return false }
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return base != "en" && base != "eng" && language != "english"
    }

    /// Whether the card has what it needs; headers open regardless, the
    /// card body explains the missing step when this is false.
    func canExpand(_ card: Card) -> Bool {
        switch card {
        case .source: true
        // Footage is chosen (kind, length, instructions) and generated on its own card.
        case .footage: video != nil
        case .settings: video != nil && hasFootage && hasKeptFootage
        case .broll: isPodcastOrInterview && hasKeptFootage
        }
    }

    /// The user may jump to any card at any time; a card without its inputs
    /// explains what to do first instead of refusing to open.
    var openCard: Card { requestedCard }

    /// What the page shows open: the open card unless the user collapsed it.
    var visibleCard: Card? { collapsedCard == openCard ? nil : openCard }

    func isCollapsed(_ card: Card) -> Bool { card != visibleCard }

    /// A header click: a collapsed card opens; the open card collapses.
    func headerClick(_ card: Card) -> (requested: Card, collapsed: Card?)? {
        if visibleCard == card { return (requestedCard, card) }
        return (card, nil)
    }

    static func footageSummary(kind: FootageKind, count: Int, keptCount: Int) -> String {
        switch kind {
        case .qa: "\(count) exchanges · \(keptCount) kept"
        case .highlights: "\(count) candidates · \(keptCount) kept"
        case .transcript, .fightMetrics: count == 1 ? "1 pick" : "\(count) picks"
        }
    }

    func outputCount(keptCount: Int) -> Int {
        keptCount > 0 ? 1 : 0
    }

    func generateButtonTitle(keptCount: Int) -> String {
        "Generate Video"
    }

    func settingsSummary(_ settings: MiniWizardSettings) -> String {
        presentationSummary(settings).joined(separator: " · ")
    }

    /// A short preview of the next render, based on the currently kept items and visible settings.
    func runSummary(candidates: [MiniWizardCandidate], exchangeCount: Int, settings: MiniWizardSettings) -> String {
        let kept = candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }
        let qa = effectiveFootageKind == .qa
        let picks = (effectiveFootageKind == .transcript || effectiveFootageKind == .fightMetrics) && kept.isEmpty
        let count = qa || picks ? exchangeCount : kept.count
        guard count > 0 else { return "No kept footage" }
        let output = "One reel"
        let source: String
        if qa {
            source = "\(count) \(count == 1 ? "exchange" : "exchanges")"
        } else if picks {
            source = "\(count) \(count == 1 ? "pick" : "picks")"
        } else if let first = kept.first {
            source = "\(first.selection.name), Take \(first.take.ordinal)"
                + (count > 1 ? " + \(count - 1) more" : "")
        } else {
            return "No kept footage"
        }
        var parts = ["\(output) from \(source)"]
        if !qa { parts.append(length.seconds.map { "\($0) s" } ?? "Auto length") }
        parts += presentationSummary(settings)
        return parts.joined(separator: " · ")
    }

    typealias RunSummary = WizardRunSummary

    func runSummaryCard(candidates: [MiniWizardCandidate], exchangeCount: Int, settings: MiniWizardSettings,
                        profilePlatforms: [SocialPlatform] = SocialPlatform.allCases, brollCount: Int? = nil) -> RunSummary {
        let kept = candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }
        let qa = effectiveFootageKind == .qa
        // Picks become selections when Settings opens; until then the kept
        // count is the picks themselves.
        let picks = (effectiveFootageKind == .transcript || effectiveFootageKind == .fightMetrics) && kept.isEmpty
        let count = qa || picks ? exchangeCount : kept.count
        guard count > 0 else {
            return RunSummary(headline: "No kept footage", length: nil, sections: [], hasFootage: false)
        }
        let output = "One reel"
        let source = qa ? "\(count) \(count == 1 ? "exchange" : "exchanges")"
            : picks ? "\(count) \(count == 1 ? "pick" : "picks")"
            : "\(kept[0].selection.name), Take \(kept[0].take.ordinal)" + (count > 1 ? " + \(count - 1) more" : "")
        var picture = [settings.quality.label, settings.preset.label]
        picture.append(settings.framing.subject.label(type: video?.type ?? .other))
        if let look = settings.lookName {
            picture.append(EffectCatalog.preset(for: look)?.name ?? look.replacingOccurrences(of: "lut:", with: ""))
        }
        picture.append(settings.transition == WizardPlanRules.randomTransitionChoice ? "Random transitions"
            : (TransitionCatalog.all.first { $0.name == settings.transition }?.title ?? settings.transition) + " transitions")
        var audio: [String] = []
        if showsAudioOptions {
            audio.append(settings.muteSourceAudio ? "Source muted" : "Source audio")
            if settings.music { audio.append(settings.musicTrackName.map { "Music: \($0)" } ?? "Random music") }
        }
        if settings.dub { audio.append(DubLanguageChoices.summary(settings.dubLanguage ?? DubLanguageChoices.defaultLanguage)) }
        var overlays: [String] = []
        if settings.safeAreaOnly {
            let selected = settings.safeAreaPlatforms?.compactMap(SocialPlatform.init(rawValue:)) ?? []
            let platforms = selected.isEmpty ? profilePlatforms : selected
            overlays.append("Safe area: " + platforms.map(\.shortLabel).joined(separator: ", "))
        }
        if let name = settings.overlayName { overlays.append("Overlay \(name)") }
        if settings.captions {
            overlays.append(settings.dub ? DubLanguageChoices.captionSummary(settings.dubLanguage ?? DubLanguageChoices.defaultLanguage)
                : settings.englishCaptions && showsCaptionLanguage ? "English captions" : "Captions")
        }
        if settings.nameTags && showsNameTags { overlays.append("Name tags") }
        if settings.watermark {
            let name = settings.watermarkOverlay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            overlays.append(name.isEmpty ? "Watermark" : "Watermark \(name)")
        }
        var package: [String] = []
        if settings.introVideo { package.append("Intro video") }
        if settings.outroVideo { package.append("Outro video") }
        let brollCount = brollCount ?? kept.flatMap { $0.take.plan.clips }.reduce(0) { $0 + ($1.brollCuts?.count ?? 0) }
        if isPodcastOrInterview, settings.includesBRoll, brollCount > 0 {
            package.append("B-roll (\(brollCount))")
        }
        var sections = [RunSummary.Section(title: "Picture", items: picture)]
        if !audio.isEmpty { sections.append(.init(title: "Audio", items: audio)) }
        sections.append(.init(title: "Overlays", items: overlays.isEmpty ? ["None"] : overlays))
        sections.append(.init(title: "Package", items: package))
        return RunSummary(headline: "\(output) from \(source)",
                          length: qa ? nil : length.seconds.map { "\($0) s" } ?? "Auto length",
                          sections: sections, hasFootage: true)
    }

    private func presentationSummary(_ settings: MiniWizardSettings) -> [String] {
        var parts = [settings.quality.label, settings.preset.label]
        if settings.captions { parts.append("captions") }
        if settings.dub { parts.append(DubLanguageChoices.summary(settings.dubLanguage ?? DubLanguageChoices.defaultLanguage)) }
        if let name = settings.overlayName { parts.append("overlay \(name)") }
        if settings.introVideo { parts.append("intro video") }
        if settings.outroVideo { parts.append("outro video") }
        if settings.nameTags && showsNameTags { parts.append("name tags") }
        if settings.watermark {
            let name = settings.watermarkOverlay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            parts.append(name.isEmpty ? "watermark" : "watermark \(name)")
        }
        if showsAudioOptions {
            if settings.muteSourceAudio { parts.append("source muted") }
            if settings.music { parts.append(settings.musicTrackName.map { "music \($0)" } ?? "random music") }
        }
        return parts
    }

    func summary(for card: Card) -> String {
        switch card {
        case .source: video?.filename ?? "Pick a source first"
        case .footage: video == nil ? "Pick a source first" : hasFootage ? "Review footage" : "Choose footage"
        case .broll: hasKeptFootage ? "Select words and pick a scene" : "Keep footage in 2 Footage first."
        case .settings: canExpand(.settings) ? "Ready to generate" : "Choose footage first"
        }
    }
}
