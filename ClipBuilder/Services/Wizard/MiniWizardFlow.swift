import Foundation

/// Pure visibility and navigation rules for the Mini Wizard's three cards.
nonisolated struct MiniWizardFlow: Sendable {
    enum Card: String, CaseIterable, Sendable {
        case source, footage, settings
    }

    enum FootageKind: String, CaseIterable, Sendable {
        case qa, highlights

        var label: String { self == .qa ? "Q&A" : "Highlights" }
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
    var footageKind: FootageKind = .highlights
    var length: Length = .automatic
    var captionsEnabled = false
    var transcriptLanguage: String?
    var hasFootage = false
    var hasKeptFootage = false
    var requestedCard: Card = .source
    var outputMode: OutputMode = .separateVideos

    var isPodcastOrInterview: Bool {
        guard let video else { return false }
        return video.type == .podcast || video.type == .interview || hasPodcastExchangeScenes
    }

    var footageKinds: [FootageKind] { isPodcastOrInterview ? [.qa, .highlights] : [.highlights] }
    var showsFootageKind: Bool { isPodcastOrInterview }
    /// A remembered Q&A choice must never apply to ordinary footage.
    var effectiveFootageKind: FootageKind { isPodcastOrInterview ? footageKind : .highlights }
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
        case .footage: video != nil && hasFootage
        case .settings: video != nil && hasFootage && hasKeptFootage
        }
    }

    /// Clamp a stale navigation request when its source or kept footage disappears.
    var openCard: Card {
        if canExpand(requestedCard) { return requestedCard }
        return requestedCard == .settings && canExpand(.footage) ? .footage : .source
    }

    func isCollapsed(_ card: Card) -> Bool { card != openCard }

    static func footageSummary(kind: FootageKind, count: Int, keptCount: Int) -> String {
        "\(count) \(kind == .qa ? "exchanges" : "candidates") · \(keptCount) kept"
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
        case .footage: canExpand(.footage) ? "Review footage" : "Pick a source first"
        case .settings: canExpand(.settings) ? "Ready to generate" : "Choose footage first"
        }
    }
}
