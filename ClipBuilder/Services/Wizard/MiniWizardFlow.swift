import Foundation

/// Pure visibility and navigation rules for the Mini Wizard's three cards.
nonisolated struct MiniWizardFlow: Sendable {
    enum Card: String, CaseIterable, Sendable {
        case source, footage, settings
    }

    enum FootageKind: String, CaseIterable, Sendable {
        case qa, highlights, transcript

        var label: String {
            switch self {
            case .qa: "Q&A"
            case .highlights: "Highlights"
            case .transcript: "Transcript"
            }
        }
    }

    enum Length: String, CaseIterable, Sendable {
        case ten = "10", fifteen = "15", thirty = "30", automatic = "auto"

        var seconds: Int? { Int(rawValue) }
        var label: String { seconds.map { "\($0) s" } ?? "Auto" }
    }

    enum OutputMode: String, CaseIterable, Sendable {
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

    var footageKinds: [FootageKind] {
        (isPodcastOrInterview ? [.qa, .highlights] : [.highlights]) + (hasTranscript ? [.transcript] : [])
    }
    var showsFootageKind: Bool { footageKinds.count > 1 }
    /// A remembered Q&A or Transcript choice must never apply to footage that cannot offer it.
    var effectiveFootageKind: FootageKind { footageKinds.contains(footageKind) ? footageKind : .highlights }
    var showsLength: Bool { effectiveFootageKind == .highlights }
    var lengthOptions: [Length] { Length.allCases }
    var showsCameraFocus: Bool { isPodcastOrInterview }
    var showsNameTags: Bool { isPodcastOrInterview }

    var showsCaptionLanguage: Bool {
        guard captionsEnabled, let transcriptLanguage else { return false }
        let language = transcriptLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !language.isEmpty, language != "und", language != "unknown" else { return false }
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return base != "en" && base != "eng" && language != "english"
    }

    func canExpand(_ card: Card) -> Bool {
        switch card {
        case .source: true
        // Footage is chosen (kind, length, instructions) and generated on its own card.
        case .footage: video != nil
        case .settings: video != nil && hasFootage && hasKeptFootage
        }
    }

    /// Clamp a stale navigation request when its source or kept footage disappears.
    var openCard: Card {
        if canExpand(requestedCard) { return requestedCard }
        return requestedCard == .settings && canExpand(.footage) ? .footage : .source
    }

    /// What the page shows open: the open card unless the user collapsed it.
    var visibleCard: Card? { collapsedCard == openCard ? nil : openCard }

    func isCollapsed(_ card: Card) -> Bool { card != visibleCard }

    /// A header click: an expandable collapsed card opens; the open card collapses.
    func headerClick(_ card: Card) -> (requested: Card, collapsed: Card?)? {
        guard canExpand(card) else { return nil }
        if visibleCard == card { return (requestedCard, card) }
        return (card, nil)
    }

    static func footageSummary(kind: FootageKind, count: Int, keptCount: Int) -> String {
        switch kind {
        case .qa: "\(count) exchanges · \(keptCount) kept"
        case .highlights: "\(count) candidates · \(keptCount) kept"
        case .transcript: count == 1 ? "1 pick" : "\(count) picks"
        }
    }

    func outputCount(keptCount: Int) -> Int {
        keptCount > 0 && outputMode == .oneReel ? 1 : max(0, keptCount)
    }

    func generateButtonTitle(keptCount: Int) -> String {
        outputMode == .oneReel || keptCount == 1 ? "Generate Video" : "Generate Videos"
    }

    func settingsSummary(_ settings: MiniWizardSettings) -> String {
        (presentationSummary(settings) + [settings.outputMode.label.lowercased()]).joined(separator: " · ")
    }

    /// A short preview of the next render, based on the currently kept items and visible settings.
    func runSummary(candidates: [MiniWizardCandidate], exchangeCount: Int, settings: MiniWizardSettings) -> String {
        let kept = candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }
        let qa = effectiveFootageKind == .qa
        let count = qa ? exchangeCount : kept.count
        guard count > 0 else { return "No kept footage" }
        let output = settings.outputMode == .oneReel ? "One reel" : count == 1 ? "1 reel" : "\(count) reels"
        let source: String
        if qa {
            source = "\(count) \(count == 1 ? "exchange" : "exchanges")"
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

    private func presentationSummary(_ settings: MiniWizardSettings) -> [String] {
        var parts = [settings.quality.label, settings.preset.label]
        if settings.captions { parts.append("captions") }
        if settings.introVideo { parts.append("intro video") }
        if settings.outroVideo { parts.append("outro video") }
        if settings.nameTags && showsNameTags { parts.append("name tags") }
        if settings.watermark { parts.append("watermark") }
        return parts
    }

    func summary(for card: Card) -> String {
        switch card {
        case .source: video?.filename ?? "Pick a source first"
        case .footage: video == nil ? "Pick a source first" : hasFootage ? "Review footage" : "Choose footage"
        case .settings: canExpand(.settings) ? "Ready to generate" : "Choose footage first"
        }
    }
}
