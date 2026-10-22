import Foundation
import Testing
@testable import Clip_Builder

struct WizardDubTests {
    @Test func captionsDefaultToDubLanguageAndExplicitChoiceWins() throws {
        var options = WizardOptions()
        #expect(options.effectiveCaptionLanguage == nil)
        options.dubLanguage = "pt-BR"
        #expect(options.effectiveCaptionLanguage == "pt-BR")
        options.captionLanguage = "en"
        #expect(options.effectiveCaptionLanguage == "en")
        let step = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(options.step2))
        #expect(step.dubLanguage == "pt-BR")
        #expect(WizardOptions.merge(step1: options.step1, step2: step).dubLanguage == "pt-BR")
        #expect(try JSONDecoder().decode(WizardStep2Options.self, from: Data("{}".utf8)).dubLanguage == nil)
    }

    @Test func preparedCompositorDocumentKeepsReviewedAbsoluteDubTimes() {
        var document = Fixtures.timelineDocument()
        document.dub = .init(language: "pt-BR")
        document.dubLines = [.init(clipUID: UUID(), speakerKey: "unknown", voice: "stub", text: "Olá",
                                  sourceStart: 2, sourceEnd: 3, start: 0.5, duration: 1)]
        let prepared = WizardEngine.preparedDocument(from: document,
            clipURLs: [URL(fileURLWithPath: "/tmp/extracted.mp4")], transitions: [])
        #expect(prepared.dub == document.dub && prepared.dubLines == document.dubLines)
    }

    @Test func languageChoicesPutBrazilianPortugueseAndEnglishFirst() {
        let codes = DubLanguageChoices.languages(voices: [.init(identifier: "fr", language: "fr-FR", name: "French")])
        #expect(codes == ["pt-BR", "en-US", "fr-FR"])
        #expect(DubLanguageChoices.languages(voices: []).prefix(2) == ["pt-BR", "en-US"])
    }
}

extension WizardDubTests {
    @Test func enginePreparesCaptionTranslationInDubLanguage() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let scene = try #require(try await temp.database.fetchScenes(includeExcluded: true).first)
        try await temp.database.replaceTranscripts(videoID: videoID, transcriptionKey: "caption-dub", language: "en",
            isTranslation: false, segments: [.init(start: 0, end: 2, text: "Hello", words: nil)], provider: "fixture", model: nil)
        let stub = CaptionTranslationStub()
        let engine = WizardEngine(ai: stub.service(), render: RenderEngine(), translateCaptions: { id, rows, target, database in
            #expect(target == "pt-BR")
            try await database.replaceTranscripts(videoID: id, transcriptionKey: "caption-dub", language: target,
                isTranslation: true, segments: rows.map { .init(start: $0.startTime, end: $0.endTime, text: "Olá", words: nil) },
                provider: "fixture", model: nil)
            return rows.count
        })
        var options = WizardOptions(); options.addCaptions = true; options.dubLanguage = "pt-BR"
        try await engine.prepareCaptionTranslations(plan: Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 2)]),
            options: options, sceneMap: [scene.id: scene], database: temp.database, emit: { _ in })
        #expect(try await temp.database.hasTranscriptTranslation(videoID: videoID, language: "pt-BR"))
        #expect(stub.calls().isEmpty)
    }
}
