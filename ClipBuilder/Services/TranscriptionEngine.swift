import Foundation

/// What makes a transcript: Apple's on-device recognizer (with the word
/// timing it gets) or ElevenLabs Scribe in the cloud.
nonisolated enum TranscriptionEngine: Hashable, Sendable, Identifiable {
    case apple(WordTiming)
    case elevenLabs(ElevenLabsScribe.Model)

    /// Every engine, in the order a chooser lists them.
    static let all: [TranscriptionEngine] =
        WordTiming.allCases.map(TranscriptionEngine.apple) + ElevenLabsScribe.Model.allCases.map(TranscriptionEngine.elevenLabs)

    /// Stable across launches: the remembered choice is stored by it.
    var id: String {
        switch self {
        case .apple(let timing): "apple." + timing.rawValue
        case .elevenLabs(let model): "elevenlabs." + model.rawValue
        }
    }

    init?(id: String) {
        guard let match = Self.all.first(where: { $0.id == id }) else { return nil }
        self = match
    }

    var label: String {
        switch self {
        case .apple(let timing): timing.label
        case .elevenLabs(let model): "ElevenLabs " + model.label
        }
    }

    /// One line under a chooser: where it runs and what it costs.
    var detail: String {
        switch self {
        case .apple(.recognizer):
            "On this Mac, free. Apple's recognizer in the video's language."
        case .apple(.precise):
            "On this Mac, free. Apple's recognizer, then each Portuguese word is re-timed against the audio."
        case .elevenLabs:
            "In the cloud. Uploads the audio to ElevenLabs, which bills per hour of audio. "
                + "Detects the language itself; people's names and your corrections go along as spelling hints."
        }
    }

    var isCloud: Bool {
        if case .elevenLabs = self { return true }
        return false
    }

    /// The provenance a transcript made by this engine carries.
    var provider: String {
        switch self {
        case .apple: TranscriptionService.providerName
        case .elevenLabs: ElevenLabsScribe.provider
        }
    }

    var wordTiming: WordTiming {
        if case .apple(let timing) = self { return timing }
        return .recognizer
    }
}

/// Which engines a transcription can use here. Pure: the caller says what
/// is installed and whether an ElevenLabs key is saved.
nonisolated enum TranscriptionEngineRules {
    /// Every engine that can run: Apple always, precise timing when its
    /// model is installed and a language uses it, Scribe with a key.
    static func available(timings: [WordTiming], elevenLabsKey: Bool) -> [TranscriptionEngine] {
        var list = WordTiming.allCases.filter(timings.contains).map(TranscriptionEngine.apple)
        if elevenLabsKey { list += ElevenLabsScribe.Model.allCases.map(TranscriptionEngine.elevenLabs) }
        return list
    }

    /// The short list a confirming dialog offers, `preferred` first when it
    /// can run: of Scribe only the newest model, plus the preferred one.
    /// One entry means there is nothing to choose.
    static func options(timings: [WordTiming], elevenLabsKey: Bool, preferred: TranscriptionEngine) -> [TranscriptionEngine] {
        let newest = ElevenLabsScribe.Model.allCases.first
        var list = available(timings: timings, elevenLabsKey: elevenLabsKey).filter { engine in
            if case .elevenLabs(let model) = engine { return model == newest || engine == preferred }
            return true
        }
        if let index = list.firstIndex(of: preferred) { list.insert(list.remove(at: index), at: 0) }
        return list
    }

    /// The engine a run with no explicit choice uses: the Settings default,
    /// or Apple's recognizer when that default is Scribe and its key is gone.
    static func usable(_ preferred: TranscriptionEngine, elevenLabsKey: Bool) -> TranscriptionEngine {
        preferred.isCloud && !elevenLabsKey ? .apple(.recognizer) : preferred
    }

    /// The engine a chooser opens on: what was used last, else the default
    /// from Settings, else the first that can run.
    static func initial(available: [TranscriptionEngine], last: String?, preferred: TranscriptionEngine) -> TranscriptionEngine {
        if let last, let engine = TranscriptionEngine(id: last), available.contains(engine) { return engine }
        if available.contains(preferred) { return preferred }
        return available.first ?? .apple(.recognizer)
    }
}
