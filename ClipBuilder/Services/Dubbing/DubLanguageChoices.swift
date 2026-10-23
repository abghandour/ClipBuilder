import Foundation

nonisolated enum DubLanguageChoices {
    static let defaultLanguage = "pt-BR"

    static func languages(voices: [DubSynthesizer.Voice], selected: String? = nil) -> [String] {
        let first = ["pt-BR", "en-US"]
        var codes = Set(voices.map(\.language))
        if let selected, !selected.isEmpty { codes.insert(selected) }
        return first + codes.subtracting(first).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    static func matches(_ code: String, requested: String) -> Bool {
        let requested = requested.replacingOccurrences(of: "_", with: "-").lowercased()
        return code.lowercased() == requested || (!requested.contains("-") && code.lowercased().hasPrefix(requested + "-"))
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    static func summary(_ code: String) -> String { "\(languageName(code)) dub" }

    /// Dubbed reels are captioned in the dub language.
    static func captionSummary(_ code: String) -> String { "\(languageName(code)) captions" }

    static func languageName(_ code: String) -> String {
        let language = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return Locale.current.localizedString(forLanguageCode: language) ?? code
    }

    @concurrent static func voices(engine: DubVoiceEngine? = nil) async -> [DubSynthesizer.Voice] {
        engine == .siri ? await SiriDubVoices.readyVoices() : DubSynthesizer.installedVoices()
    }
}
