import Foundation
import Testing
@testable import Clip_Builder

@Suite("Transcript picks storage")
struct TranscriptPicksStorageTests {
    @Test func picksRoundTripInListOrder() async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 2)
        let first = try await database.addTranscriptPick(videoID: videoID, start: 1, end: 4)
        let second = try await database.addTranscriptPick(videoID: videoID, start: 6, end: 9)
        let third = try await database.addTranscriptPick(videoID: videoID, start: 12, end: 15)
        #expect([first, second, third].map(\.position) == [0, 1, 2])
        #expect(first.sceneID == nil)
        #expect(first.originalRange == 1...4)

        try await database.setTranscriptPickRange(id: second.id, start: 5, end: 10)
        try await database.reorderTranscriptPicks(videoID: videoID, ids: [third.id, second.id])
        let picks = try await database.fetchTranscriptPicks(videoID: videoID)
        #expect(picks.map(\.id) == [third.id, second.id, first.id], "listed ids first, the rest after them")
        #expect(picks.map(\.position) == [0, 1, 2])
        #expect(picks[1].range == 5...10 && picks[1].originalRange == 6...9)
        try await database.deleteTranscriptPick(id: first.id)
        #expect(try await database.fetchTranscriptPicks(videoID: videoID).map(\.id) == [third.id, second.id])
        // Picks belong to their video.
        let other = try await temp.seedVideo(sceneCount: 0)
        #expect(try await database.fetchTranscriptPicks(videoID: other).isEmpty)
    }

    @Test func savingPicksMakesScenesAndSelectionsInListOrder() async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 1)
        let projectID = try await database.createProject(profileName: "Test", name: "Picks", videoIDs: [videoID])
        try await database.replaceTranscripts(videoID: videoID, transcriptionKey: "t", language: "en", isTranslation: false,
            segments: [TranscriptSegment(start: 0, end: 3, text: "One two three", words: nil),
                       TranscriptSegment(start: 3, end: 6, text: "Four five six", words: nil)],
            provider: "test", model: "test")
        let rows = try await database.fetchTranscripts(videoID: videoID)
        let late = try await database.addTranscriptPick(videoID: videoID, start: 3, end: 6)
        let early = try await database.addTranscriptPick(videoID: videoID, start: 0, end: 3)
        try await database.reorderTranscriptPicks(videoID: videoID, ids: [early.id, late.id])
        let picks = try await database.fetchTranscriptPicks(videoID: videoID)
        var options = WizardStep1Options()
        options.formatPreset = "custom"

        let candidates = try await database.replaceMiniTranscriptSelections(projectID: projectID, videoID: videoID,
            miniBatch: "batch", picks: picks, rows: rows, options: options)
        #expect(candidates.map(\.selection.name) == ["One two three", "Four five six"])
        #expect(candidates.allSatisfy { $0.take.plan.clips.count == 1 })
        #expect(candidates.map { $0.take.plan.clips[0].start } == [0, 3])
        #expect(candidates.map { $0.take.plan.clips[0].end } == [3, 6])
        let sceneIDs = candidates.map { $0.take.plan.clips[0].sceneID }
        let scenes = try await database.fetchScenes(ids: Set(sceneIDs))
        #expect(scenes.count == 2)
        #expect(scenes.allSatisfy { $0.tags.contains(Database.transcriptPickTag) && $0.videoID == videoID })
        #expect(scenes.allSatisfy { !$0.tags.contains("podcast") }, "an untyped video without speaker turns is not podcast footage")
        #expect(scenes.allSatisfy { $0.runID != nil }, "attached to the video's active run")
        #expect(try await database.fetchTranscriptPicks(videoID: videoID).map(\.sceneID) == sceneIDs)
        // A take's footage snapshot resolves against the stored scenes.
        for candidate in candidates {
            #expect(WizardSelectionRules.resolvedPlan(candidate.take.plan, scenes: scenes) != nil)
        }

        // Saving again replaces the batch's selections rather than adding to them.
        let again = try await database.replaceMiniTranscriptSelections(projectID: projectID, videoID: videoID,
            miniBatch: "batch", picks: picks, rows: rows, options: options)
        #expect(again.count == 2)
        let selections = try await database.fetchWizardSelections(projectID: projectID, miniBatch: "batch")
        #expect(selections.count == 2)
    }

    @Test func picksFromConversationalFootageCarryThePodcastTagSoCameraFocusApplies() async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 1)
        let projectID = try await database.createProject(profileName: "Test", name: "Picks", videoIDs: [videoID])
        try await database.replaceTranscripts(videoID: videoID, transcriptionKey: "t", language: "en", isTranslation: false,
            segments: [TranscriptSegment(start: 0, end: 3, text: "One two three", words: nil)],
            provider: "test", model: "test")
        let rows = try await database.fetchTranscripts(videoID: videoID)
        _ = try await database.addTranscriptPick(videoID: videoID, start: 0, end: 3)
        let picks = try await database.fetchTranscriptPicks(videoID: videoID)
        var options = WizardStep1Options()
        options.formatPreset = "podcast"
        func tags() async throws -> [String] {
            let candidates = try await database.replaceMiniTranscriptSelections(projectID: projectID, videoID: videoID,
                miniBatch: "batch", picks: picks, rows: rows, options: options)
            let scene = try #require(try await database.fetchScenes(ids: Set(candidates.map { $0.take.plan.clips[0].sceneID })).first)
            return scene.tags
        }
        // A podcast-typed video.
        try await database.setVideoType(id: videoID, type: VideoType.podcast.rawValue)
        #expect(try await tags().contains("podcast"))
        // An untyped video with speaker turns counts as conversational too.
        try await database.setVideoType(id: videoID, type: nil)
        try await database.replaceSpeakerTurns(videoID: videoID, transcriptionKey: "t",
            turns: [SpeakerTurn(videoID: videoID, start: 0, end: 3, cluster: 0, confidence: 1)])
        let tagged = try await tags()
        #expect(tagged.contains("podcast") && tagged.contains(Database.transcriptPickTag))
    }
}
