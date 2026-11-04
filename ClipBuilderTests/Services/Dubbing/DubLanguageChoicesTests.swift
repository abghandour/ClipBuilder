import Foundation
import Testing
@testable import Clip_Builder

struct DubLanguageChoicesTests {
    @Test func localEnginesKeepExistingLanguageOrderingAndSavedSelections() {
        let voices: [DubSynthesizer.Voice] = [.init(identifier: "fr", language: "fr-FR", name: "French")]
        for engine in [DubVoiceEngine.mac, .siri] {
            #expect(DubLanguageChoices.languages(voices: voices, engine: engine) == ["pt-BR", "en-US", "fr-FR"])
            let codes = DubLanguageChoices.languages(voices: voices, selected: "de-DE", engine: engine)
            #expect(codes.prefix(2) == ["pt-BR", "en-US"])
            #expect(codes.contains("de-DE"))
        }
    }

    @Test func elevenLabsOffersEverySupportedLanguageEvenBeforeTheKeyIsAdded() {
        let expected = ["en", "ja", "zh", "de", "hi", "fr", "ko", "pt", "it", "es", "id", "nl", "tr", "fil", "pl", "sv",
                        "bg", "ro", "ar", "cs", "el", "fi", "hr", "ms", "sk", "da", "ta", "uk", "ru", "hu", "no", "vi"]
        #expect(ElevenLabsVoices.supportedLanguages == expected)
        let choices = DubLanguageChoices.languages(voices: [], selected: "fr-CA", engine: .elevenLabs)
        #expect(choices.prefix(2) == ["pt-BR", "en-US"])
        #expect(Set(choices) == Set(expected + ["pt-BR", "en-US", "fr-CA"]))
        #expect(choices.count == Set(choices).count)
    }

    @Test func accountVoiceIdentifiersAlsoSelectTheMultilingualList() {
        let voices: [DubSynthesizer.Voice] = [.init(identifier: "elevenlabs:voice", language: "pt-BR", name: "Voice")]
        #expect(DubLanguageChoices.languages(voices: voices)
                == DubLanguageChoices.languages(voices: [], engine: .elevenLabs))
        let explicitMac = DubLanguageChoices.languages(voices: voices, engine: .mac)
        #expect(explicitMac == ["pt-BR", "en-US"])
    }

    @Test func elevenLabsEnginePersistsWithThePlannedRawValue() throws {
        #expect(DubVoiceEngine.elevenLabs.rawValue == "elevenLabs")
        #expect(DubVoiceEngine.elevenLabs.title == "ElevenLabs voices")
        #expect(DubVoiceEngine.allCases.contains(.elevenLabs))
        let settings = DubSettings(language: "pt-BR", engine: .elevenLabs)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(DubSettings.self, from: data).engine == .elevenLabs)
    }

    @Test func elevenLabsEngineUsesTheAccountCacheAndRequestedLanguage() async throws {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.voices)])
        let cache = ElevenLabsVoiceCache(key: { "key" }, client: { stub.client(key: $0) })
        let french = await DubLanguageChoices.voices(engine: .elevenLabs, language: "fr-CA", cache: cache)
        let japanese = await DubLanguageChoices.voices(engine: .elevenLabs, language: "ja", cache: cache)
        #expect(french.count == 5 && japanese.count == 5)
        #expect(french.allSatisfy { ElevenLabsVoices.isElevenLabs($0.identifier) && $0.language == "fr-CA" })
        #expect(japanese.allSatisfy { $0.language == "ja" })
        #expect(french.map(\.identifier) == japanese.map(\.identifier))
        #expect(await stub.requests.count == 1)
    }
}
