import Foundation

nonisolated struct DubSettings: Codable, Sendable, Equatable {
    var language: String
    var voices: [String: String] = [:]
    var originalLevel: Double = 0.15
    var replaceOriginal = false
    var enabled = true
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
