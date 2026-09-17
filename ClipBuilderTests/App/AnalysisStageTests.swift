import Foundation
import Testing
@testable import Clip_Builder

@Suite("Analysis stages")
struct AnalysisStageTests {
    @Test("people detection and podcast exchanges route on their own tasks")
    func routing() {
        for task in ["people", "exchanges"] {
            #expect(AICatalog.tasks.contains(task), "\(task)")
            #expect(AICatalog.taskDefaults[task] == "claude", "\(task)")
        }
        #expect(AICatalog.taskLabels["people"] == "People detection")
        #expect(AICatalog.taskLabels["exchanges"] == "Podcast exchanges")
        #expect(AppStore.AnalysisStage.people.task == "people" && AppStore.AnalysisStage.exchanges.task == "exchanges")
        #expect(AppStore.AnalysisStage.analysis.task == "analysis" && AppStore.AnalysisStage.transcript.task == nil)
    }

    @Test("the AI details roles map to the stage that produced them")
    func roles() {
        typealias Stage = AppStore.AnalysisStage
        #expect(Stage.forRole("Video analysis", podcast: false) == .analysis)
        #expect(Stage.forRole("Tagging", podcast: false) == .analysis)
        // A podcast's tagging and its transcript row are one transcript-first pass.
        #expect(Stage.forRole("Video analysis", podcast: true) == .exchanges)
        #expect(Stage.forRole("Transcript", podcast: true) == .exchanges)
        #expect(Stage.forRole("Transcript", podcast: false) == .transcript)
        #expect(Stage.forRole("People", podcast: false) == .people)
        #expect(Stage.forRole("People detection", podcast: true) == .people)
        #expect(Stage.forRole("Soundbite finding", podcast: true) == nil)
        #expect(Stage.forRole("Favorite", podcast: false) == nil)
    }
}
