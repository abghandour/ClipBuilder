import Foundation
import Testing
@testable import Clip_Builder

struct DubbingTests {
    @Test func oldDocumentWithoutDubFieldsDecodesAndReencodesWithoutThem() throws {
        let old = Data(#"{"video_track":[],"sound_track":[],"track_count":1}"#.utf8)
        let document = try JSONDecoder().decode(TimelineDocument.self, from: old)
        #expect(document.dub == nil && document.dubLines == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        #expect(encoded["dub"] == nil && encoded["dub_lines"] == nil)
    }

    @Test func settingsLinesAndDocumentRoundTrip() throws {
        let settings = DubSettings(language: "pt-BR", voices: ["host": "voice"],
                                   originalLevel: 0.2, replaceOriginal: true, enabled: false)
        let line = DubLine(clipUID: UUID(), speakerKey: "host", voice: "voice", text: "Olá mundo",
            sourceStart: 2, sourceEnd: 4, start: 0, duration: 2.1, rate: 1.25, stretch: 1.15, tight: true, audio: "cached.caf")
        #expect(try JSONDecoder().decode(DubSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(try JSONDecoder().decode(DubLine.self, from: JSONEncoder().encode(line)) == line)
        var document = TimelineDocument()
        document.dub = settings; document.dubLines = [line]
        #expect(try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(document)) == document)
        #expect(DubSettings(language: "en-US").originalLevel == 0.15)
    }

    @Test func optionalDefaultsDecodeOldPayloadsAndPersistChoices() throws {
        #expect(try JSONDecoder().decode(FootageDefaults.self, from: Data("{}".utf8)).dubLanguage == nil)
        #expect(try JSONDecoder().decode(ProfileEditingDefaults.self, from: Data("{}".utf8)).dubVoices == nil)
        var profile = ProfileEditingDefaults()
        profile.footage.dubLanguage = "pt-BR"; profile.dubVoices = ["host": "voice"]
        #expect(try JSONDecoder().decode(ProfileEditingDefaults.self, from: JSONEncoder().encode(profile)) == profile)
        var options = WizardOptions()
        // Construct a complete legacy payload, removing only the new field.
        let old = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(WizardOptions.self, from: old).dubLanguage == nil)
        options.dubLanguage = "en-US"
        #expect(try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options)).dubLanguage == "en-US")
        #expect(AppJobKind.dub.shortTitle == "Dub" && AppJobKind.dub.channel == "builder")
    }
}
