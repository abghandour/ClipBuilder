import Foundation

nonisolated struct WizardCaptionChoices: Equatable, Sendable {
    var captionPosition: String?
    var captionStyleID: String?

    /// Ranges use original video time, before any framing or speed changes.
    /// The caller supplies only translations in the requested target language.
    static func rowsNeedingTranslation(originals: [TranscriptRow], translations: [TranscriptRow],
                                       ranges: [(start: Double, end: Double)], padding: Double = 1) -> [TranscriptRow] {
        originals.filter { row in
            ranges.contains { range in
                range.end > range.start && row.endTime > range.start - padding
                    && row.startTime < range.end + padding
            } && !translations.contains {
                $0.isTranslation && $0.videoID == row.videoID
                    && $0.startTime == row.startTime && $0.endTime == row.endTime
            }
        }
    }

    static func load(profileName: String, defaults: UserDefaults = .standard) -> Self {
        Self(captionPosition: defaults.string(forKey: "wizard.\(profileName).captionPosition"),
             captionStyleID: defaults.string(forKey: "wizard.\(profileName).captionStyleID"))
    }

    func save(profileName: String, defaults: UserDefaults = .standard) {
        defaults.set(captionPosition, forKey: "wizard.\(profileName).captionPosition")
        defaults.set(captionStyleID, forKey: "wizard.\(profileName).captionStyleID")
    }
}
