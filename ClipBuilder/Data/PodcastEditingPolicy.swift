import Foundation

nonisolated struct PodcastEditingPolicy: Codable, Sendable, Hashable {
    var deadAirSeconds = 1.5
    var fillerRunSeconds = 2.0
    var highlightThreshold = 7.0
    var highlightMaxSeconds = 30.0 {
        didSet { highlightMaxSeconds = PodcastSettings.clampHighlightSeconds(highlightMaxSeconds) }
    }
    var speakerHoldSeconds = 1.5
    var cleanupCutPolicy = CleanupCutPolicy.acceptDeadAir
    var autoTranslateLanguage = ""

    enum CodingKeys: String, CodingKey {
        case deadAirSeconds = "dead_air_seconds"
        case fillerRunSeconds = "filler_run_seconds"
        case highlightThreshold = "highlight_threshold"
        case highlightMaxSeconds = "highlight_max_seconds"
        case speakerHoldSeconds = "speaker_hold_seconds"
        case cleanupCutPolicy = "cleanup_cut_policy"
        case autoTranslateLanguage = "auto_translate_language"
    }

    init() {}

    init(_ settings: PodcastSettings) {
        deadAirSeconds = settings.deadAirSeconds
        fillerRunSeconds = settings.fillerRunSeconds
        highlightThreshold = settings.highlightThreshold
        highlightMaxSeconds = PodcastSettings.clampHighlightSeconds(settings.highlightMaxSeconds)
        speakerHoldSeconds = settings.speakerHoldSeconds
        cleanupCutPolicy = settings.cleanupCutPolicy
        autoTranslateLanguage = settings.autoTranslateLanguage
    }

    /// Keep service APIs unchanged while retaining this Mac's review preference.
    func settings(reviewCutsByDefault: Bool = true) -> PodcastSettings {
        var settings = PodcastSettings()
        settings.deadAirSeconds = deadAirSeconds
        settings.fillerRunSeconds = fillerRunSeconds
        settings.highlightThreshold = highlightThreshold
        settings.highlightMaxSeconds = highlightMaxSeconds
        settings.speakerHoldSeconds = speakerHoldSeconds
        settings.cleanupCutPolicy = cleanupCutPolicy
        settings.autoTranslateLanguage = autoTranslateLanguage
        settings.reviewCutsByDefault = reviewCutsByDefault
        return settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deadAirSeconds = min(10, max(0.5, try container.decodeIfPresent(Double.self, forKey: .deadAirSeconds) ?? 1.5))
        fillerRunSeconds = min(10, max(0.5, try container.decodeIfPresent(Double.self, forKey: .fillerRunSeconds) ?? 2))
        highlightThreshold = min(10, max(0, try container.decodeIfPresent(Double.self, forKey: .highlightThreshold) ?? 7))
        highlightMaxSeconds = PodcastSettings.clampHighlightSeconds(try container.decodeIfPresent(Double.self, forKey: .highlightMaxSeconds) ?? 30)
        speakerHoldSeconds = min(5, max(0.5, try container.decodeIfPresent(Double.self, forKey: .speakerHoldSeconds) ?? 1.5))
        cleanupCutPolicy = try container.decodeIfPresent(CleanupCutPolicy.self, forKey: .cleanupCutPolicy) ?? .acceptDeadAir
        autoTranslateLanguage = try container.decodeIfPresent(String.self, forKey: .autoTranslateLanguage) ?? ""
    }
}
