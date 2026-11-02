import Foundation

/// The language a video is spoken in: pure helpers for the badge, the
/// picker list and the display name. Stored as a BCP-47 locale id ("pt-BR").
nonisolated enum VideoLanguage {
    /// Where a video's language came from; the user's choice is never
    /// overwritten by a transcript or a detection pass.
    enum Source: String, Sendable {
        case user, transcript, detected

        var caption: String {
            switch self {
            case .user: "Set by you"
            case .transcript: "From the transcript"
            case .detected: "Detected from the first minute"
            }
        }
    }

    /// Below this a detection sample stores nothing: crowd noise and music
    /// make every recognizer guess.
    static let minimumDetectionConfidence = 0.4

    /// True when detection listened and found no clear speech: the row
    /// says so instead of staying blank, and the user is asked to choose.
    static func detectionFailed(language: String?, source: String?) -> Bool {
        (language ?? "").isEmpty && source == Source.detected.rawValue
    }

    static let detectionFailedText = "Language not detected: no clear speech in the first minute. Choose it here."

    /// The picker's title for a language, with its recognizer state when
    /// it is not ready on this Mac.
    static func choiceTitle(_ locale: String, state: LanguageAsset.State?) -> String {
        switch state {
        case .downloadable: "\(name(locale)) — not installed"
        case .unsupported: "\(name(locale)) — not supported"
        case .missing: "\(name(locale)) — not available"
        case .installed, nil: name(locale)
        }
    }

    static let common = ["en-US", "pt-BR", "es-ES", "es-MX", "fr-FR", "de-DE", "it-IT", "ja-JP", "ko-KR",
                         "zh-CN", "ar-SA", "ru-RU", "hi-IN", "nl-NL", "tr-TR", "pl-PL"]

    /// English and Brazilian Portuguese first, then the rest by name. The
    /// project's spoken languages and the current value are always offered.
    static func choices(including current: String? = nil, project: [String] = []) -> [String] {
        let first = ["en-US", "pt-BR"]
        var seen = Set(first.map { $0.lowercased() })
        let rest = (common + project + [current ?? ""])
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        return first + rest
    }

    /// "EN" for en-US, "PT" for pt-BR; nil when no language is known.
    static func badge(_ locale: String?) -> String? {
        guard let locale, !locale.isEmpty else { return nil }
        let code = Locale(identifier: locale).language.languageCode?.identifier ?? String(locale.prefix(2))
        return code.uppercased()
    }

    static func name(_ locale: String) -> String {
        Locale.current.localizedString(forIdentifier: locale) ?? locale
    }
}
