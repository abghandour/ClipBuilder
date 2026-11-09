import CryptoKit
import Foundation

/// Optional on DubLine so older timeline JSON continues to decode.
nonisolated struct DubTakeSource: Codable, Sendable, Equatable {
    var videoID: Int64
    var transcriptionKey: String
    var rowStart: Double
    var rowEnd: Double
    var language: String
    var text: String
    var wordsJSON: String?

    var words: [TranscriptWord]? {
        wordsJSON.flatMap { try? JSONDecoder().decode([TranscriptWord].self, from: Data($0.utf8)) }
    }
}

nonisolated struct DubTake: Sendable, Equatable {
    var id: String
    var source: DubTakeSource
    var speakerKey: String
    var text: String
    var voice: String
    var model: String
    var settingsHash: String
    var audioFile: String
    var alignment: DubTakeAlignment?
    var edited: Bool
    var driveFileID: String?

    static func digest(_ parts: [String]) -> String {
        // JSON array avoids delimiter collisions and is stable across devices.
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func settingsHash(_ settings: ElevenLabsSettings) -> String {
        digest([String(settings.stability), String(settings.similarity)])
    }

    static func cacheVoice(_ voice: String, settings: ElevenLabsSettings) -> String {
        voice + "#" + settings.model + "#" + settingsHash(settings)
    }

    static func key(videoHash: String, source: DubTakeSource, voice: String, settings: ElevenLabsSettings) -> String {
        digest([videoHash, source.transcriptionKey, String(source.rowStart), String(source.rowEnd),
                source.language, voice, settings.model, settingsHash(settings)])
    }
}
