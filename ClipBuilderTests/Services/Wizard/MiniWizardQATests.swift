import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Wizard Q&A")
struct MiniWizardQATests {
    private func row(_ id: Int64, _ start: Double, _ end: Double, _ text: String) -> TranscriptRow {
        TranscriptRow(id: id, videoID: 1, language: "en", isTranslation: false,
                      startTime: start, endTime: end, text: text, originalText: nil,
                      wordsJSON: nil, provider: nil, model: nil)
    }

    private func scene(_ id: Int64, _ start: Double, _ end: Double) -> SceneRecord {
        var scene = Fixtures.scene(id: id, start: start, end: end)
        scene.tags = ["q&a", "podcast-exchange"]
        scene.videoDuration = 200
        return scene
    }

    @Test func keptExchangesUseVideoOrderAndWholeEditedRanges() {
        var edited = scene(1, 10, 50)
        edited.startTime = 12
        edited.endTime = 48
        let scenes = [scene(3, 80, 95), scene(2, 60, 75), edited]
        let rows = [row(1, 12, 16, "Why did you choose this?\nExtra context"),
                    row(2, 16, 48, "A complete long answer."), row(3, 80, 85, "What happened next?")]
        let sections = TranscriptQASections.sections(scenes: scenes, rows: rows, labels: [1: "Host", 2: "Guest"])
        let turns = [SpeakerTurn(videoID: 1, start: 12, end: 16, cluster: 0, confidence: 1),
                     SpeakerTurn(videoID: 1, start: 16, end: 48, cluster: 1, confidence: 1)]
        let plans = MiniWizardQARules.plans(sections: Array(sections.reversed()), kept: [1, 3, 999], rows: rows, turns: turns)
        #expect(plans.map { $0.clips.first?.sceneID } == [1, 3])
        #expect(plans.map(\.headline) == ["Why did you choose this?", "What happened next?"])
        #expect(plans.map { $0.clips.first?.start } == [12, 80])
        #expect(plans.map { $0.clips.first?.end } == [48, 95])
        #expect(plans.map(\.targetDuration) == [36, 15])
        #expect(plans.allSatisfy { $0.clips.count == 1 && $0.provenance == nil })
        #expect(plans.first?.footage?.first?.start == 12)
        #expect(MiniWizardQARules.plans(sections: sections, kept: [], rows: rows, turns: turns).isEmpty)
    }

    @Test func overlappingKeptExchangesProduceIndependentExactPlans() throws {
        var first = scene(1, 10, 20)
        first.endTime = 35
        var second = scene(2, 30, 45)
        second.startTime = 20
        let scenes = [first, second]
        let sections = TranscriptQASections.sections(scenes: scenes, rows: [], labels: [:])
        let plans = MiniWizardQARules.plans(sections: sections, kept: [1, 2], rows: [], turns: [])
        #expect(plans.count == 2)
        #expect(plans.map { $0.clips.first?.sceneID } == [1, 2])
        #expect(plans.map { $0.clips.first?.start } == [10, 20])
        #expect(plans.map { $0.clips.first?.end } == [35, 45])
        #expect(plans.map(\.targetDuration) == [25, 25])
        for plan in plans {
            // Mini previews and renders resolve each saved Selection independently.
            let resolved = try #require(WizardSelectionRules.resolvedPlan(plan, scenes: scenes))
            #expect(resolved.clips.first?.start == plan.clips.first?.start)
            #expect(resolved.clips.first?.end == plan.clips.first?.end)
        }
        let takes = plans.enumerated().map { index, plan in
            WizardSelectionTake(id: Int64(index + 1), selectionID: Int64(index + 1),
                ordinal: 1, plan: plan, sceneIDs: plan.clips.map(\.sceneID))
        }
        let combined = try #require(WizardSelectionRules.resolvedPlan(
            WizardPlanRules.combinedPlan(takes), scenes: scenes))
        #expect(combined.clips.map(\.start) == [10, 20])
        #expect(combined.clips.map(\.end) == [35, 45])
        #expect(combined.targetDuration == 50)
    }

    @Test func titlesUseOriginalFirstLineOrExchangeNumberAndTruncateByCharacters() {
        #expect(MiniWizardQARules.title(question: nil, number: 4) == "Exchange 4")
        #expect(MiniWizardQARules.title(question: "  \n  ", number: 2) == "Exchange 2")
        #expect(MiniWizardQARules.title(question: "  Why   now? \nDo not include this", number: 1) == "Why now?")
        let sixty = String(repeating: "é", count: 60)
        #expect(MiniWizardQARules.title(question: sixty, number: 1) == sixty)
        let long = MiniWizardQARules.title(question: sixty + " more", number: 1)
        #expect(long.count == 60 && long == String(repeating: "é", count: 59) + "…")
        var translation = row(1, 10, 12, "Translation?")
        translation.isTranslation = true
        let rows = [translation, row(2, 10, 12, "Original?")]
        let sections = TranscriptQASections.sections(scenes: [scene(1, 10, 20), scene(2, 30, 40)], rows: rows, labels: [:])
        let plans = MiniWizardQARules.plans(sections: sections, kept: [1, 2], rows: rows, turns: [])
        #expect(plans.map(\.headline) == ["Original?", "Exchange 2"])
    }

    @Test func rerecordingReplacesOnlyThisProjectsQABatchWithCurrentSavedRanges() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let video = try await temp.seedVideo(sceneCount: 0)
        _ = try await db.saveAnalysis(videoID: video, runName: "Q&A", instructions: "", sampleInterval: nil,
            notesJSON: nil, tagRanges: ["q&a": [(start: 0, end: 4), (start: 5, end: 9)]],
            moments: [], analyzedTags: ["q&a"], provider: nil, model: nil, mode: "visual")
        let project = try await db.createProject(profileName: "Test", name: "Mini Q&A", videoIDs: [video])
        let other = try await db.createProject(profileName: "Test", name: "Other", videoIDs: [video])
        let scenes = try await db.fetchScenes(projectID: project).sorted { $0.startTime < $1.startTime }
        #expect(scenes.count == 2)
        let firstScene = try #require(scenes.first)
        let lastScene = try #require(scenes.last)
        var firstRow = row(1, 0, 2, "First question?")
        var lastRow = row(2, 5, 7, "Second question?")
        firstRow.videoID = video
        lastRow.videoID = video
        let rows = [firstRow, lastRow]
        var options = WizardOptions().step1
        options.formatPreset = "podcast"
        options.targetDurationSeconds = 10
        let unrelated = try await db.recordWizardTake(projectID: project, options: options,
            plan: Fixtures.plan(), miniBatch: "other-batch")
        let otherProject = try await db.recordWizardTake(projectID: other, options: options,
            plan: Fixtures.plan(), miniBatch: "qa-batch")
        let highlight = try await db.recordWizardTake(projectID: project, options: WizardOptions().step1,
            plan: Fixtures.plan(), miniBatch: "qa-batch")
        let initial = try await db.replaceMiniQASelections(projectID: project, videoID: video, miniBatch: "qa-batch",
            kept: Set(scenes.map(\.id)), rows: rows, labels: [:], turns: [], options: options)
        #expect(initial.map { $0.selection.name } == ["First question?", "Second question?"])
        #expect(initial.allSatisfy {
            $0.kept && $0.take.ordinal == 1 && $0.take.note == nil && $0.take.provenance == nil
                && $0.take.plan.provenance == nil && $0.selection.recipe == "podcast"
                && $0.selection.miniBatch == "qa-batch" && $0.selection.step1Options.targetDurationSeconds == nil
        })
        try await db.setSceneEditRange(lastScene.id, start: 6, end: 8.5)
        let replaced = try await db.replaceMiniQASelections(projectID: project, videoID: video, miniBatch: "qa-batch",
            kept: [lastScene.id], rows: rows, labels: [:], turns: [], options: options)
        #expect(replaced.count == 1)
        let take = try #require(replaced.first?.take)
        #expect(take.ordinal == 1 && take.plan.clips.count == 1)
        #expect(take.plan.clips.first?.start == 6 && take.plan.clips.first?.end == 8.5)
        #expect(take.sceneIDs == [lastScene.id])
        let batch = try await db.fetchWizardSelections(projectID: project, miniBatch: "qa-batch")
        #expect(batch.filter { $0.recipe == "podcast" }.count == 1)
        #expect(try await db.wizardSelection(id: unrelated.selectionID) != nil)
        #expect(try await db.wizardSelection(id: otherProject.selectionID) != nil)
        #expect(try await db.wizardSelection(id: highlight.selectionID) != nil)
        let repeated = try await db.replaceMiniQASelections(projectID: project, videoID: video, miniBatch: "qa-batch",
            kept: [lastScene.id], rows: rows, labels: [:], turns: [], options: options)
        #expect(repeated.count == 1 && repeated.first?.take.ordinal == 1)
        #expect(try await db.fetchWizardSelectionTakes(selectionID: repeated[0].id).count == 1)
        let none = try await db.replaceMiniQASelections(projectID: project, videoID: video, miniBatch: "qa-batch",
            kept: [], rows: rows, labels: [:], turns: [], options: options)
        #expect(none.isEmpty)
        #expect(try await db.fetchWizardSelections(projectID: project, miniBatch: "qa-batch").map(\.id) == [highlight.selectionID])
        #expect(firstScene.id != lastScene.id)
    }

    @Test func failedReplacementRollsBackTheExistingBatch() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let video = try await temp.seedVideo(sceneCount: 0)
        _ = try await db.saveAnalysis(videoID: video, runName: "Q&A", instructions: "", sampleInterval: nil,
            notesJSON: nil, tagRanges: ["q&a": [(start: 0, end: 8)]], moments: [], analyzedTags: ["q&a"],
            provider: nil, model: nil, mode: "visual")
        let project = try await db.createProject(profileName: "Test", name: "Mini", videoIDs: [video])
        let scene = try #require(try await db.fetchScenes(projectID: project).first)
        var options = WizardOptions().step1
        let initial = try await db.replaceMiniQASelections(projectID: project, videoID: video, miniBatch: "batch",
            kept: [scene.id], rows: [], labels: [:], turns: [], options: options)
        let take = try #require(initial.first?.take)
        options.highlightMaxSeconds = .nan
        await #expect(throws: EncodingError.self) {
            _ = try await db.replaceMiniQASelections(projectID: project, videoID: video, miniBatch: "batch",
                kept: [scene.id], rows: [], labels: [:], turns: [], options: options)
        }
        #expect(try await db.fetchWizardSelections(projectID: project, miniBatch: "batch").count == 1)
        #expect(try await db.wizardSelectionTake(id: take.id)?.plan.headline == "Exchange 1")
    }

    @Test func qaColumnsFitTheirContainer() {
        for width: CGFloat in [640, 700, 819, 820, 1000, 1160, 1600] {
            for preferred: (CGFloat, CGFloat) in [(220, 360), (420, 640), (420, 820), (160, 260)] {
                let columns = TranscriptQAView.columnWidths(available: width,
                    list: preferred.0, transcript: preferred.1)
                let player = width - columns.list - columns.transcript - 16 // Two 8 pt hit areas.
                #expect(columns.list >= 0 && columns.list <= preferred.0)
                #expect(columns.transcript >= 0 && columns.transcript <= preferred.1)
                #expect(player >= 320 - 0.001)
                #expect(abs(columns.list / columns.transcript - preferred.0 / preferred.1) < 0.001)
                #expect(abs(columns.list + player + columns.transcript + 16 - width) < 0.001)
            }
        }
        let defaults = TranscriptQAView.columnWidths(available: 1000)
        #expect(defaults.list == 220 && defaults.transcript == 360)
        let narrow = TranscriptQAView.columnWidths(available: 640)
        #expect(abs(narrow.list - 220 * (304.0 / 580)) < 0.001)
        #expect(abs(narrow.transcript - 360 * (304.0 / 580)) < 0.001)
        // Display compression leaves the same preferences available on expansion.
        let restored = TranscriptQAView.columnWidths(available: 1600, list: 420, transcript: 820)
        #expect(restored.list == 420 && restored.transcript == 820)
    }

    @Test func qaColumnPreferencesAndDragsAreClamped() {
        let small = TranscriptQAView.columnWidths(available: 1600, list: 1, transcript: 1)
        #expect(small.list == 160 && small.transcript == 260)
        let large = TranscriptQAView.columnWidths(available: 1600, list: 900, transcript: 900)
        #expect(large.list == 420 && large.transcript == 820)
        #expect(TranscriptQAColumns.resizedWidth(1, column: .list, available: 1600, otherWidth: 360) == 160)
        #expect(TranscriptQAColumns.resizedWidth(900, column: .list, available: 1600, otherWidth: 360) == 420)
        #expect(TranscriptQAColumns.resizedWidth(1, column: .transcript, available: 1600, otherWidth: 220) == 260)
        #expect(TranscriptQAColumns.resizedWidth(900, column: .transcript, available: 1600, otherWidth: 220) == 820)
        // Reserve 320 pt for the player and 16 pt for both separators.
        #expect(TranscriptQAColumns.resizedWidth(420, column: .list, available: 1000, otherWidth: 360) == 304)
        #expect(TranscriptQAColumns.resizedWidth(820, column: .transcript, available: 1000, otherWidth: 220) == 444)
        #expect(TranscriptQAColumns.resizedWidth(220, column: .list, available: 640, otherWidth: 200) == nil)
        #expect(TranscriptQAColumns.resizedWidth(360, column: .transcript, available: 640, otherWidth: 120) == nil)
        #expect(TranscriptQAColumns.Column.list.defaultWidth == 220)
        #expect(TranscriptQAColumns.Column.transcript.defaultWidth == 360)
    }
}
