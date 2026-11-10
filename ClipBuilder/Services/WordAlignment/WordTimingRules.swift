import Foundation

/// When precise word timing is offered for a transcription, and when its
/// model is fetched unasked. Pure: the caller says what is on disk.
nonisolated enum WordTimingRules {
    /// Whether any of `languages` is one the aligner re-times.
    static func speaksAlignerLanguage(_ languages: [String]) -> Bool {
        languages.contains { Locale(identifier: $0).language.languageCode?.identifier == WordAlignerModel.language }
    }

    /// The word timings a transcription that may run in `languages` can
    /// use, `preferred` first. One entry means there is nothing to choose:
    /// no aligner covers the languages, or its model is not on this Mac.
    static func options(languages: [String], modelInstalled: Bool, preferred: WordTiming) -> [WordTiming] {
        guard modelInstalled, speaksAlignerLanguage(languages) else { return [.recognizer] }
        return [preferred] + WordTiming.allCases.filter { $0 != preferred }
    }

    /// Whether the model should be downloaded without being asked for: the
    /// project speaks the aligner's language and nothing says otherwise.
    /// `declined` is the user having removed it; `attempted` keeps a failed
    /// or stopped download from starting again on every refresh.
    static func shouldAutoInstall(spoken: [String], installed: Bool, declined: Bool,
                                  running: Bool, attempted: Bool) -> Bool {
        !installed && !declined && !running && !attempted && speaksAlignerLanguage(spoken)
    }
}
