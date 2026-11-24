import Foundation
import Testing
import Synchronization
@testable import Clip_Builder

@Suite("Filler cut rendering")
struct FillerCutEngineTests {
    @Test("Final and rough render hooks see the cut for podcast and ordinary recipes",
          arguments: [false, true], ["podcast", "custom"])
    func renderPlan(enabled: Bool, recipe: String) async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        let projectID = try await database.createProject(profileName: "Fillers", name: "Fillers", videoIDs: [videoID])
        let scene = try #require(try await database.fetchScenes(projectID: projectID).first)
        let words: [TranscriptWord] = [.init(word: "We", start: 0.5, end: 1),
            .init(word: "um", start: 2, end: 2.3), .init(word: "agree", start: 3, end: 4)]
        try await database.replaceTranscripts(videoID: videoID, transcriptionKey: "fillers", language: "en", isTranslation: false,
            segments: [.init(start: 0, end: 6, text: "We um agree", words: words)], provider: "test", model: nil)
        var options = WizardOptions()
        options.projectID = projectID
        options.formatPreset = recipe
        options.removeFillerWords = enabled
        options.useMusic = false
        options.addCaptions = true
        options.useFightResearch = false
        options.framing = Framing(subject: .original)
        options.allowedTransitions = ["fade"]
        options.transitionChoice = "fade"
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 6),
            Fixtures.planClip(sceneID: scene.id, start: 6, end: 8)], transitions: ["fade"])
        let take = try await database.recordWizardTake(projectID: projectID, options: options.step1, plan: plan)
        let ai = AIService(config: AIConfig()) { _, _, _, _, _, _ in
            Issue.record("The filler render must not call AI")
            throw CancellationError()
        }
        let engine = WizardEngine(ai: ai, render: RenderEngine())
        let savedRender = Mutex<WizardPlan?>(nil)
        for rough in [false, true] {
            var renderOptions = rough ? WizardRoughCut.options(options) : options
            // Exercise the separate rough-transition expansion as well.
            if rough { renderOptions.strikeImpactFreeze = 0.8 }
            let logs = Mutex<[String]>([])
            try await engine.makeReel(take: take, options: renderOptions, profile: Fixtures.brand(), database: database,
                pauseEligibilityOptions: rough ? options : nil, emit: { line in logs.withLock { $0.append(line) } }, renderPlan: { rendered, _ in
                    savedRender.withLock { $0 = rendered }
                    #expect(rendered.clips.count == (enabled ? 3 : 2))
                    if enabled {
                        #expect(rendered.clips.map(\.start) == [0, 2.75, 6])
                        #expect(rendered.clips.map(\.end) == [1.25, 6, 8])
                        #expect(rendered.transitions == ["cut", rough ? "cut" : "fade"])
                        #expect(rendered.clips[1].continuesPrevious == true)
                        #expect(rendered.appliedFillerSpans?[videoID] == [1.25...2.75])
                        let segments = try await engine.captionSegments(videoID: videoID, filename: scene.videoFilename,
                            start: 2.75, end: 6, language: nil, database: database, fallbacks: WizardCaptionFallbackLog(),
                            fillerSpans: rendered.appliedFillerSpans?[videoID] ?? [], emit: { _ in })
                        #expect(segments.first?.text == "We agree")
                    } else {
                        #expect(rendered.clips.map(\.start) == [0, 6])
                        #expect(rendered.appliedFillerSpans == nil)
                    }
                })
            if enabled { #expect(logs.withLock { $0.contains("Filler words: cut 1 (−1.5 s)") }) }
            else { #expect(logs.withLock { !$0.contains { $0.hasPrefix("Filler words:") } }) }
        }
        if enabled {
            let saved = try #require(savedRender.withLock { $0 })
            try await database.updateWizardSelectionTakePlan(id: take.id, plan: saved)
            let logs = Mutex<[String]>([])
            try await engine.makeReel(take: take, options: options, profile: Fixtures.brand(), database: database,
                emit: { line in logs.withLock { $0.append(line) } }, renderPlan: { rendered, _ in
                    #expect(rendered.clips.map(\.start) == saved.clips.map(\.start))
                    #expect(rendered.clips.map(\.end) == saved.clips.map(\.end))
                    #expect(rendered.transitions == ["cut", "fade"])
                    #expect(rendered.appliedFillerSpans == saved.appliedFillerSpans)
                })
            #expect(logs.withLock { $0.contains("Filler words: none found") })
        }
    }
}
