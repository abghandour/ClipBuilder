import Foundation

nonisolated struct DubSettings: Codable, Sendable, Equatable {
    var language: String
    var voices: [String: String] = [:]
    var originalLevel: Double = 0.15
    /// Default: the original audio is silent under the dub, not ducked.
    var replaceOriginal = true
    var enabled = true
    /// nil = Mac voices (AVSpeechSynthesizer); `.siri` speaks through Shortcuts.
    var engine: DubVoiceEngine? = nil
}

/// A speaker's or a voice's gender, so a man is never dubbed by a woman's voice or the reverse.
nonisolated enum DubVoiceGender: Int, Codable, Sendable, Equatable {
    case unknown = 0, male = 1, female = 2

    /// Read from a person's descriptor ("Male host with…", "Woman in a red…").
    static func inferred(from descriptor: String) -> DubVoiceGender {
        let words = Set(descriptor.lowercased().split { !$0.isLetter }.map(String.init))
        let female = ["female", "woman", "women", "girl", "lady", "she", "her", "mother", "wife", "daughter", "sister", "actress"]
        let male = ["male", "man", "men", "boy", "guy", "gentleman", "he", "his", "him", "father", "husband", "son", "brother", "actor"]
        let isFemale = female.contains { words.contains($0) }, isMale = male.contains { words.contains($0) }
        if isFemale && !isMale { return .female }
        if isMale && !isFemale { return .male }
        return .unknown
    }

    /// Mac voices without gender metadata (the Eloquence set) are known by name.
    static func inferred(voiceName name: String) -> DubVoiceGender {
        let first = name.split { !$0.isLetter }.first.map { $0.lowercased() } ?? ""
        if ["flo", "sandy", "shelley", "grandma", "luciana", "fernanda", "samantha", "kathy", "francisca", "joana", "catarina"].contains(first) { return .female }
        if ["eddy", "reed", "rocko", "grandpa", "felipe", "fred", "aaron", "joaquim", "daniel", "ralph"].contains(first) { return .male }
        return .unknown
    }
}

nonisolated struct DubLine: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var clipUID: UUID
    var speakerKey: String
    var voice: String
    var text: String
    var sourceStart: Double
    var sourceEnd: Double
    var start: Double
    /// Planned source span on the timeline; after synthesis, audible duration
    /// including the rate and stretch. Tight lines are never truncated to fit.
    var duration: Double
    var rate: Double = 1
    /// FFmpeg atempo multiplier, not a duration multiplier.
    var stretch: Double = 1
    var tight = false
    /// A leaf filename under SettingsStore.cacheDirectory/dubs.
    var audio: String?
}
