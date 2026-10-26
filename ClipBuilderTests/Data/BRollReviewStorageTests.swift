import Foundation
import Testing
@testable import Clip_Builder

struct BRollReviewStorageTests {
    @Test func transcriptRecreationRetainsEditedCutsAfterTrimAndEmptyRemoval() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let video = try await temp.seedVideo(sceneCount: 2)
        let project = try await db.createProject(profileName: "Test", name: "B-roll picks", videoIDs: [video])
        let pick = try await db.addTranscriptPick(videoID: video, start: 0, end: 10)
        let options = WizardStep1Options()
        let initial = try await db.replaceMiniTranscriptSelections(projectID: project, videoID: video,
            miniBatch: "review", picks: [pick], rows: [], options: options)
        let first = try #require(initial.first)
        let scene = try #require(try await db.fetchScenes(projectID: project).first)
        let cut = BRollCut(start: 4, end: 6, sceneID: scene.id, sceneOffset: 0, reason: "words", origin: .user)
        var plan = first.take.plan
        plan.clips[0].brollCuts = [cut]
        try await db.updateWizardSelectionTakePlan(id: first.take.id, plan: plan)
        try await db.setTranscriptPickRange(id: pick.id, start: 4, end: 9)
        let picks = try await db.fetchTranscriptPicks(videoID: video)
        let recreated = try await db.replaceMiniTranscriptSelections(projectID: project, videoID: video,
            miniBatch: "review", picks: picks, rows: [], options: options)
        let take = try #require(recreated.first?.take)
        let restored = try #require(take.plan.clips.first?.brollCuts?.first)
        #expect(restored.id == cut.id && restored.start == 4 && restored.end == 6 && restored.sceneOffset == 0)
        var removed = take.plan
        removed.clips[0].brollCuts = []
        try await db.updateWizardSelectionTakePlan(id: take.id, plan: removed)
        let again = try await db.replaceMiniTranscriptSelections(projectID: project, videoID: video,
            miniBatch: "review", picks: picks, rows: [], options: options)
        #expect(again.first?.take.plan.clips.first?.brollCuts == [])
    }

    @Test func qaRecreationKeepsReviewedCutsOnTheirWords() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let video = try await temp.seedVideo(sceneCount: 0)
        _ = try await db.saveAnalysis(videoID: video, runName: "Q&A", instructions: "", sampleInterval: nil,
            notesJSON: nil, tagRanges: ["q&a": [(start: 0, end: 9)]], moments: [], analyzedTags: ["q&a"],
            provider: nil, model: nil, mode: "visual")
        let project = try await db.createProject(profileName: "Test", name: "B-roll Q&A", videoIDs: [video])
        let scene = try #require(try await db.fetchScenes(projectID: project).first)
        let row = TranscriptRow(id: 1, videoID: video, language: "en", isTranslation: false,
            startTime: 0, endTime: 9, text: "Why did Gane win?", originalText: nil, wordsJSON: nil, provider: nil, model: nil)
        var options = WizardStep1Options(); options.formatPreset = "podcast"
        let first = try await db.replaceMiniQASelections(projectID: project, videoID: video, miniBatch: "qa",
            kept: [scene.id], rows: [row], labels: [:], turns: [], options: options)
        let take = try #require(first.first?.take)
        var plan = take.plan
        let cut = BRollCut(start: 4, end: 6, sceneID: scene.id, sceneOffset: 0, reason: "Gane", origin: .ai)
        plan.clips[0].brollCuts = [cut]
        try await db.updateWizardSelectionTakePlan(id: take.id, plan: plan)
        try await db.setSceneEditRange(scene.id, start: 4, end: 9)
        let again = try await db.replaceMiniQASelections(projectID: project, videoID: video, miniBatch: "qa",
            kept: [scene.id], rows: [row], labels: [:], turns: [], options: options)
        let restored = try #require(again.first?.take.plan.clips.first?.brollCuts?.first)
        #expect(restored.id == cut.id && restored.start == 4 && restored.end == 6 && restored.origin == .ai)
    }
}

extension BRollReviewStorageTests {
    @Test func identicalPicksRetainIndependentCuts() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let video = try await temp.seedVideo(sceneCount: 1)
        let project = try await db.createProject(profileName: "Test", name: "Repeated picks", videoIDs: [video])
        let first = try await db.addTranscriptPick(videoID: video, start: 0, end: 8)
        let second = try await db.addTranscriptPick(videoID: video, start: 0, end: 8)
        let initial = try await db.replaceMiniTranscriptSelections(projectID: project, videoID: video,
            miniBatch: "duplicates", picks: [first, second], rows: [], options: .init())
        let sceneID = try #require(initial.first?.take.plan.clips.first?.sceneID)
        let cut = BRollCut(start: 3, end: 5, sceneID: sceneID, sceneOffset: 0, reason: "Only the second pick", origin: .user)
        let rebuilt = try await db.replaceMiniTranscriptSelections(projectID: project, videoID: video,
            miniBatch: "duplicates", picks: [second, first], rows: [], options: .init(),
            reviewedCutsByPick: [first.id: [], second.id: [cut]])
        #expect(rebuilt.count == 2)
        #expect(rebuilt[0].take.plan.clips.first?.brollCuts == [])
        #expect(rebuilt[1].take.plan.clips.first?.brollCuts == [cut])
    }
}

extension BRollReviewStorageTests {
    @Test func savedPicksRestoreIndependentCutsWithoutRunLocalIdentity() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let video = try await temp.seedVideo(sceneCount: 1)
        let project = try await db.createProject(profileName: "Test", name: "Relaunch", videoIDs: [video])
        let first = try await db.addTranscriptPick(videoID: video, start: 0, end: 8)
        let second = try await db.addTranscriptPick(videoID: video, start: 0, end: 8)
        let initial = try await db.replaceMiniTranscriptSelections(projectID: project, videoID: video,
            miniBatch: "persistent", picks: [first, second], rows: [], options: .init())
        let secondTake = try #require(initial.last?.take)
        var plan = secondTake.plan
        let cut = BRollCut(start: 3, end: 5, sceneID: plan.clips[0].sceneID, sceneOffset: 0,
            reason: "second passage", origin: .user)
        plan.clips[0].brollCuts = [cut]
        try await db.updateWizardSelectionTakePlan(id: secondTake.id, plan: plan)
        let restored = try await db.miniSavedCandidates(projectID: project, miniBatch: "persistent")
        #expect(restored.last?.take.plan.clips[0].brollCuts == [cut])
        let picks = try await db.fetchTranscriptPicks(videoID: video)
        let rebuilt = try await db.replaceMiniTranscriptSelections(projectID: project, videoID: video,
            miniBatch: "persistent", picks: picks, rows: [], options: .init())
        #expect(rebuilt.first?.take.plan.clips[0].brollCuts == [])
        #expect(rebuilt.last?.take.plan.clips[0].brollCuts == [cut])
        try await db.setTranscriptPickRange(id: second.id, start: 4, end: 8)
        let trimmed = try await db.fetchTranscriptPicks(videoID: video)
        let dropped = try await db.replaceMiniTranscriptSelections(projectID: project, videoID: video,
            miniBatch: "persistent", picks: trimmed, rows: [], options: .init())
        #expect(dropped.last?.take.plan.clips[0].brollCuts == [])
    }
}
