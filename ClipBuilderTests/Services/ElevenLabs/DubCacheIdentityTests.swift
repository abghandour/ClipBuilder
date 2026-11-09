import Foundation
import Testing
@testable import Clip_Builder

struct DubCacheIdentityTests {
    @Test func canonicalUnicodeAndSpacingShareAudio() throws {
        let a = try DubSynthesizer.cacheName(language: "pt", voice: "voice", rate: 1, text: "  Café\n  aqui\t")
        let b = try DubSynthesizer.cacheName(language: "pt", voice: "voice", rate: 1, text: "Cafe\u{301} aqui")
        #expect(a == b)
        #expect(a != (try DubSynthesizer.cacheName(language: "pt", voice: "voice", rate: 1, text: "Café aqui!")))
    }

    @Test func everySpeechSettingChangesTheIdentity() throws {
        let original = ElevenLabsSettings()
        func name(_ settings: ElevenLabsSettings) throws -> String {
            try DubSynthesizer.cacheName(language: "elevenlabs", voice: DubTake.cacheVoice("elevenlabs:v", settings: settings),
                                         rate: 1, text: "hello")
        }
        var changed = original; changed.stability = 0.6
        #expect(try name(original) != name(changed))
        changed = original; changed.similarity = 0.6
        #expect(try name(original) != name(changed))
        changed = original; changed.model = "other"
        #expect(try name(original) != name(changed))
        changed = original; changed.concurrency = 3
        #expect(try name(original) == name(changed))
    }

    @Test func naturalKeyUsesVideoHashInsteadOfLocalDatabaseID() {
        let a = DubTakeSource(videoID: 1, transcriptionKey: "transcript", rowStart: 1, rowEnd: 5, language: "pt", text: "hello")
        var b = a; b.videoID = 999
        let settings = ElevenLabsSettings()
        #expect(DubTake.key(videoHash: "shared-hash", source: a, voice: "v", settings: settings)
            == DubTake.key(videoHash: "shared-hash", source: b, voice: "v", settings: settings))
        b.rowStart = 2
        #expect(DubTake.key(videoHash: "shared-hash", source: a, voice: "v", settings: settings)
            != DubTake.key(videoHash: "shared-hash", source: b, voice: "v", settings: settings))
    }
}
