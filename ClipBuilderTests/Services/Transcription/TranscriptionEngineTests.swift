import Foundation
import Testing
@testable import Clip_Builder

struct TranscriptionEngineTests {
    @Test func idsRoundTrip() {
        for engine in TranscriptionEngine.all { #expect(TranscriptionEngine(id: engine.id) == engine) }
        #expect(TranscriptionEngine(id: "whisper") == nil)
        #expect(TranscriptionEngine.elevenLabs(.v3).provider == "elevenlabs")
        #expect(TranscriptionEngine.apple(.precise).provider == "apple")
        #expect(TranscriptionEngine.elevenLabs(.v2).wordTiming == .recognizer)
    }

    @Test func withoutAKeyOrAnAlignerThereIsNothingToChoose() {
        #expect(TranscriptionEngineRules.options(timings: [.recognizer], elevenLabsKey: false, preferred: .apple(.recognizer))
                == [.apple(.recognizer)])
        // A default that cannot run here is not offered.
        #expect(TranscriptionEngineRules.options(timings: [.recognizer], elevenLabsKey: false, preferred: .elevenLabs(.v3))
                == [.apple(.recognizer)])
    }

    @Test func aKeyAddsTheNewestScribeAndThePreferredComesFirst() {
        #expect(TranscriptionEngineRules.options(timings: [.precise, .recognizer], elevenLabsKey: true, preferred: .apple(.precise))
                == [.apple(.precise), .apple(.recognizer), .elevenLabs(.v3)])
        #expect(TranscriptionEngineRules.options(timings: [.recognizer], elevenLabsKey: true, preferred: .elevenLabs(.v2))
                == [.elevenLabs(.v2), .apple(.recognizer), .elevenLabs(.v3)])
        #expect(TranscriptionEngineRules.available(timings: [.recognizer], elevenLabsKey: true)
                == [.apple(.recognizer), .elevenLabs(.v3), .elevenLabs(.v2)])
    }

    @Test func aScribeDefaultWithoutItsKeyRunsOnApple() {
        #expect(TranscriptionEngineRules.usable(.elevenLabs(.v3), elevenLabsKey: false) == .apple(.recognizer))
        #expect(TranscriptionEngineRules.usable(.elevenLabs(.v3), elevenLabsKey: true) == .elevenLabs(.v3))
        #expect(TranscriptionEngineRules.usable(.apple(.precise), elevenLabsKey: false) == .apple(.precise))
    }

    @Test func theChooserOpensOnTheLastModelUsedWhenItCanStillRun() {
        let all = TranscriptionEngineRules.available(timings: [.recognizer], elevenLabsKey: true)
        #expect(TranscriptionEngineRules.initial(available: all, last: "elevenlabs.scribe_v3", preferred: .apple(.recognizer)) == .elevenLabs(.v3))
        let appleOnly = TranscriptionEngineRules.available(timings: [.recognizer], elevenLabsKey: false)
        #expect(TranscriptionEngineRules.initial(available: appleOnly, last: "elevenlabs.scribe_v3", preferred: .elevenLabs(.v3)) == .apple(.recognizer))
        #expect(TranscriptionEngineRules.initial(available: all, last: nil, preferred: .elevenLabs(.v2)) == .elevenLabs(.v2))
    }

    @Test func settingsKeepTheWordTimingWhenTheDefaultMovesToElevenLabsAndBack() throws {
        var settings = AppSettings()
        settings.wordTimingChoice = .precise
        #expect(settings.transcriptionEngine == .apple(.precise))
        settings.transcriptionEngine = .elevenLabs(.v2)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.transcriptionEngine == .elevenLabs(.v2))
        #expect(decoded.wordTimingChoice == .precise)
        settings.transcriptionEngine = .apple(settings.wordTimingChoice)
        #expect(settings.transcribeProvider == "apple" && settings.transcribeModel.isEmpty)
    }
}
