import Foundation
import Testing
@testable import Clip_Builder

struct LanguageReadinessTests {
    static let installed = LanguageProbe(recognizer: { _ in .installed }, translation: { _, _ in .installed }, dubVoice: { _, _ in .installed })

    @Test func allInstalledAndPairsSkipSameLanguage() async throws {
        let languages = ProjectLanguages(spoken: ["en-US", "en-GB", "pt-BR"], captions: ["en", "pt", "pt-BR"], dub: ["pt-BR"])
        let assets = await LanguageReadiness.assets(for: languages, dubEngine: nil, probe: Self.installed)
        #expect(LanguageReadiness.missing(assets).isEmpty)
        #expect(LanguageReadiness.summary(assets) == nil)
        #expect(assets.filter { $0.kind == .translation }.map(\.language) == ["en→pt", "pt→en"])
        try LanguageReadiness.requireRecognizers(assets)
    }

    @Test func onlyRecognizersBlock() async throws {
        let probe = LanguageProbe(recognizer: { _ in .installed }, translation: { _, _ in .downloadable }, dubVoice: { _, _ in .missing })
        let assets = await LanguageReadiness.assets(for: ProjectLanguages(spoken: ["en-US"], captions: ["pt"], dub: ["pt-BR"]), dubEngine: .mac, probe: probe)
        #expect(LanguageReadiness.missing(assets).count == 2)
        #expect(assets.filter(\.installable).map(\.kind) == [.translation])
        try LanguageReadiness.requireRecognizers(assets)
        for state in [LanguageAsset.State.downloadable, .unsupported, .missing] {
            let blocked = [LanguageAsset(kind: .recognizer, language: "pt-BR", state: state)]
            #expect(throws: ScriptError.self) { try LanguageReadiness.requireRecognizers(blocked) }
            #expect(LanguageReadiness.summary(blocked)?.contains("recognizer") == true)
        }
    }

    @Test func dubEngineIsForwarded() async {
        let probe = LanguageProbe(recognizer: { _ in .installed }, translation: { _, _ in .installed },
                                  dubVoice: { language, engine in language == "pt-BR" && engine == .siri ? .installed : .missing })
        let languages = ProjectLanguages(dub: ["pt-BR"])
        #expect(await LanguageReadiness.assets(for: languages, dubEngine: .siri, probe: probe).first?.state == .installed)
        #expect(await LanguageReadiness.assets(for: languages, dubEngine: .mac, probe: probe).first?.state == .missing)
    }

    @Test func elevenLabsMissingKeyNamesTheKeyWithoutFetchingVoices() async throws {
        let stub = ElevenLabsTransportStub([])
        let probe = Self.elevenLabsProbe(key: { nil }, stub: stub)
        // A missing key takes precedence even for an unsupported language.
        let languages = ProjectLanguages(dub: ["is-IS"])
        let assets = await LanguageReadiness.assets(for: languages, dubEngine: .elevenLabs, probe: probe)
        let asset = try #require(assets.first)
        #expect(asset.state == .missing)
        #expect(asset.title == "ElevenLabs key")
        #expect(asset.dubEngine == .elevenLabs)
        #expect(!asset.installable)
        #expect(await stub.requests.isEmpty)
    }

    @Test func elevenLabsUnsupportedLanguageDoesNotFetchVoices() async throws {
        let stub = ElevenLabsTransportStub([])
        let probe = Self.elevenLabsProbe(key: { "fixture-key" }, stub: stub)
        let languages = ProjectLanguages(dub: ["is-IS"])
        let assets = await LanguageReadiness.assets(for: languages, dubEngine: .elevenLabs, probe: probe)
        let asset = try #require(assets.first)
        #expect(asset.state == .unsupported)
        #expect(!asset.missingElevenLabsKey)
        #expect(LanguageReadiness.summary(assets)?.contains("(unsupported)") == true)
        #expect(await stub.requests.isEmpty)
    }

    @Test func elevenLabsEmptyAccountIsMissingAVoiceNotAKey() async throws {
        let empty = Data(#"{"voices":[]}"#.utf8)
        let stub = ElevenLabsTransportStub([(200, empty)])
        let probe = Self.elevenLabsProbe(key: { "fixture-key" }, stub: stub)
        let assets = await LanguageReadiness.assets(for: ProjectLanguages(dub: ["fr-FR"]), dubEngine: .elevenLabs, probe: probe)
        let asset = try #require(assets.first)
        #expect(asset.state == .missing)
        #expect(!asset.missingElevenLabsKey)
        #expect(asset.title.hasSuffix("dub voice"))
        #expect(asset.dubEngine == .elevenLabs)
        #expect(await stub.requests.count == 1)
    }

    @Test func elevenLabsFailedVoiceFetchIsMissing() async throws {
        let stub = ElevenLabsTransportStub([(503, Data())])
        let probe = Self.elevenLabsProbe(key: { "fixture-key" }, stub: stub)
        let assets = await LanguageReadiness.assets(for: ProjectLanguages(dub: ["en-US"]), dubEngine: .elevenLabs, probe: probe)
        let asset = try #require(assets.first)
        #expect(asset.state == .missing)
        #expect(!asset.missingElevenLabsKey)
        #expect(await stub.requests.count == 1)
    }

    @Test func elevenLabsInstalledUsesEveryRequestedLanguageNotTheDefault() async {
        let stub = ElevenLabsTransportStub([(200, ElevenLabsFixtures.voices)])
        let probe = Self.elevenLabsProbe(key: { "fixture-key" }, stub: stub)
        let languages = ProjectLanguages(dub: ["fr-FR", "en-US", "ja", "pt-BR"])
        let assets = await LanguageReadiness.assets(for: languages, dubEngine: .elevenLabs, probe: probe)
        #expect(assets.count == 4)
        #expect(assets.allSatisfy { $0.state == .installed && $0.dubEngine == .elevenLabs })
        #expect(LanguageReadiness.summary(assets) == nil)
        #expect(await stub.requests.count == 1)
    }

    private nonisolated static func elevenLabsProbe(key: @escaping @Sendable () throws -> String?,
                                                    stub: ElevenLabsTransportStub) -> LanguageProbe {
        let cache = ElevenLabsVoiceCache(key: key, client: { stub.client(key: $0) })
        return LanguageProbe(recognizer: { _ in .installed }, translation: { _, _ in .installed },
            dubVoice: { language, engine in
                await LanguageProbe.dubVoiceState(language: language, engine: engine, key: key, cache: cache)
            }, elevenLabsKey: key)
    }
}
