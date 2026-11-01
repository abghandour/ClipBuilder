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
}
