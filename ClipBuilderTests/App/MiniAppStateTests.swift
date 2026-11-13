import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Express app-state regressions")
struct MiniAppStateTests {
    private func makeStore(_ temp: TempDatabase) async throws -> (AppStore, Int64, Int64) {
        let videoID = try await temp.seedVideo()
        let profile = Fixtures.brand(name: "MiniAppStateTests-\(UUID().uuidString)")
        let projectID = try await temp.database.createProject(profileName: profile.profileName, name: "Project", videoIDs: [videoID])
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        store.activeProjectID = projectID
        let video = try #require(try await temp.database.fetchVideos(projectID: projectID).first)
        store.miniFootageKind = .transcript
        store.miniFootageVideoID = videoID
        store.miniRuns[.transcript] = MiniWizardRun(projectID: projectID, video: video, footageKind: .transcript,
            length: .automatic, batchID: UUID().uuidString, candidates: [], options: WizardOptions(),
            transcript: MiniWizardTranscript(rows: [], labels: [:], picks: []))
        return (store, projectID, videoID)
    }

    private func seedPicks(_ store: AppStore, database: Database, projectID: Int64, videoID: Int64) async throws -> [TranscriptPick] {
        let picks = try await database.addTranscriptPickGroup(projectID: projectID, videoID: videoID, ranges: [0...1, 2...3])
        store.miniRuns[.transcript]?.transcript?.picks = picks
        return picks
    }

    @Test("Remove All suppresses queued single, grouped, passage and split additions", arguments: ["single", "group", "passage", "split"])
    func clearPendingTranscriptAddition(_ operation: String) async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        let picks = try await seedPicks(store, database: temp.database, projectID: projectID, videoID: videoID)
        switch operation {
        case "single": store.addMiniTranscriptPick(range: 4...5)
        case "group": store.addMiniTranscriptPicks(ranges: [4...5, 6...7])
        case "passage": store.addMiniTranscriptPassage(to: picks.map(\.id), range: 4...5)
        default: store.splitMiniTranscriptPick(picks[0].id, at: 0.5)
        }
        store.deleteAllMiniTranscriptPicks()
        try await store.transcriptPickSaveTask?.value
        #expect(store.miniRuns[.transcript]?.transcript?.picks.isEmpty == true)
        #expect(try await temp.database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).isEmpty)
        #expect(store.errorQueue.isEmpty)
        await store.miniUndoSettleTask?.value
    }

    @Test("Remove All also clears an add before the first pick is visible")
    func clearFirstAddition() async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        store.addMiniTranscriptPick(range: 0...1)
        store.deleteAllMiniTranscriptPicks()
        try await store.transcriptPickSaveTask?.value
        #expect(store.miniRuns[.transcript]?.transcript?.picks.isEmpty == true)
        #expect(try await temp.database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).isEmpty)
        await store.miniUndoSettleTask?.value
    }

    @Test("A passage completion respects a later unlink, relink or removal", arguments: ["unlink", "relink", "remove"])
    func passageGroupingRace(_ operation: String) async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        let picks = try await seedPicks(store, database: temp.database, projectID: projectID, videoID: videoID)
        store.addMiniTranscriptPassage(to: picks.map(\.id), range: 4...5)
        switch operation {
        case "unlink": store.setMiniTranscriptPicksLinked(picks.map(\.id), linked: false)
        case "relink": store.setMiniTranscriptPicksLinked(picks.map(\.id), linked: true)
        default: store.deleteMiniTranscriptPicks(picks.map(\.id))
        }
        try await store.transcriptPickSaveTask?.value
        let shown = try #require(store.miniRuns[.transcript]?.transcript?.picks)
        let stored = try await temp.database.fetchTranscriptPicks(projectID: projectID, videoID: videoID)
        #expect(shown.map(\.id) == stored.map(\.id))
        #expect(shown.map(\.groupKey) == stored.map(\.groupKey))
        #expect(shown.last?.groupKey == nil)
        #expect(store.errorQueue.isEmpty)
        await store.miniUndoSettleTask?.value
    }

    @Test("Link then Unlink during an add does not relink a formerly standalone pick")
    func singletonGroupingRace() async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        let first = try await temp.database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 1)
        let second = try await temp.database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 2, end: 3)
        store.miniRuns[.transcript]?.transcript?.picks = [first, second]
        store.addMiniTranscriptPassage(to: [first.id], range: 4...5)
        store.setMiniTranscriptPicksLinked([first.id, second.id], linked: true)
        store.setMiniTranscriptPicksLinked([first.id, second.id], linked: false)
        try await store.transcriptPickSaveTask?.value
        let stored = try await temp.database.fetchTranscriptPicks(projectID: projectID, videoID: videoID)
        #expect(stored.allSatisfy { $0.groupKey == nil })
        #expect(store.miniRuns[.transcript]?.transcript?.picks.map(\.groupKey) == stored.map(\.groupKey))
        await store.miniUndoSettleTask?.value
    }

    @Test("An unchanged singleton still gains its new passage")
    func singletonPassage() {
        let original = TranscriptPick(id: 1, videoID: 1, position: 0, start: 0, end: 1,
                                      originalStart: 0, originalEnd: 1, sceneID: nil)
        var added = original
        added.id = 2
        added.groupKey = "new"
        let result = TranscriptPickUnits.completingAddition(added, to: [original], originalUnit: [original])
        #expect(result.map(\.groupKey) == ["new", "new"])
    }

    @Test("Sync refresh resumes after wizard work or Undo ends", arguments: [false, true])
    func deferredSync(_ undo: Bool) async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        let pick = try await temp.database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 1)
        if undo { store.isMiniUndoing = true } else { store.isWizardRunning = true }
        await store.refreshMiniPicksAfterSync(changedTables: ["transcript_picks"])
        #expect(store.miniRuns[.transcript]?.transcript?.picks.isEmpty == true)
        if undo { store.isMiniUndoing = false } else { store.isWizardRunning = false }
        for _ in 0..<200 {
            if store.miniRuns[.transcript]?.transcript?.picks.map(\.id) == [pick.id] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.miniRuns[.transcript]?.transcript?.picks.map(\.id) == [pick.id])
        #expect(store.miniPicksRefreshPending.isEmpty)
    }

    @Test("Quitting waits for pick additions and the latest reel order")
    func terminationFlush() async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        store.miniReelKey = MiniReelKey(projectID: projectID, videoID: videoID)
        store.miniReelLoaded = true
        store.addMiniTranscriptPick(range: 0...1)
        await store.flushForTermination()
        let picks = try await temp.database.fetchTranscriptPicks(projectID: projectID, videoID: videoID)
        #expect(picks.count == 1)
        #expect(try await temp.database.fetchExpressReelItems(projectID: projectID, videoID: videoID).map(\.itemID) == picks.map(\.id))
        store.addMiniTranscriptPick(range: 2...3)
        try await store.transcriptPickSaveTask?.value
        store.reorderMiniReel(store.miniReelItems.reversed().map(\.clipID))
        await store.flushForTermination()
        #expect(try await temp.database.fetchExpressReelItems(projectID: projectID, videoID: videoID).map(\.key) == store.miniReelItems.map(\.key))
        #expect(store.errorQueue.isEmpty)
        await store.miniUndoSettleTask?.value
    }

    @Test("Undo restores a deleted pick before intervening Q&A")
    func undoReelOrder() async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        let first = try await temp.database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 1)
        let last = try await temp.database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 4, end: 5)
        store.miniRuns[.transcript]?.transcript?.picks = [first, last]
        store.miniReelKey = MiniReelKey(projectID: projectID, videoID: videoID)
        store.miniReelLoaded = true
        store.reconcileMiniReel()
        let qa = MiniReelItem(kind: .qa, itemID: 100, start: 2, end: 3, title: "Q&A")
        store.miniReelItems.insert(qa, at: 1)
        store.deleteMiniTranscriptPick(first.id)
        await store.miniUndoSettleTask?.value
        store.undoMini(.transcript)
        await store.miniUndoStepTask?.value
        let restored = try #require(store.miniRuns[.transcript]?.transcript?.picks.first)
        #expect(store.miniReelItems.map(\.key) == [.init(kind: .transcript, itemID: restored.id), qa.key,
                                                 .init(kind: .transcript, itemID: last.id)])
        store.redoMini(.transcript)
        await store.miniUndoStepTask?.value
        #expect(store.miniReelItems.map(\.key) == [qa.key, .init(kind: .transcript, itemID: last.id)])
        await store.flushMiniReel()
        #expect(store.errorQueue.isEmpty)
    }

    @Test("Undo remaps transcript ids in the saved reel order without changing Q&A ids")
    func remappedReelOrder() {
        let order: [MiniReelRules.Key] = [.init(kind: .transcript, itemID: 1), .init(kind: .qa, itemID: 1),
                                         .init(kind: .transcript, itemID: 2)]
        let snapshot = MiniUndoSnapshot.transcript(picks: [], reelOrder: order)
        #expect(snapshot.remapping(pickIDs: [1: 9]).reelOrder == [.init(kind: .transcript, itemID: 9), order[1], order[2]])
    }

    @Test("Transcribed sources remain eligible without analysis")
    func transcriptOnlySource() throws {
        var video = Fixtures.video()
        let path = try #require(video.path)
        #expect(MiniWizardMemory.eligibleSource(video, hasScenes: false, hasTranscript: true))
        #expect(MiniWizardMemory.validatedVideoPath(path, videos: [video], transcribedIDs: [video.id]) == path)
        #expect(!MiniWizardMemory.eligibleSource(video, hasScenes: false))
        #expect(MiniWizardMemory.validatedVideoPath(path, videos: [], transcribedIDs: [video.id]).isEmpty)
        video.locallyDownloaded = false
        #expect(!MiniWizardMemory.eligibleSource(video, hasTranscript: true))
    }

    @Test("Fight scoring refreshes actions without replacing picks; clear suppresses pending adds")
    func fightRefreshAndClear() async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        let video = try #require(store.miniRuns[.transcript]?.video)
        let pick = try await temp.database.addFightPick(projectID: projectID, videoID: videoID, start: 0, end: 2, eventIDs: [])
        store.miniRuns[.fightMetrics] = MiniWizardRun(projectID: projectID, video: video, footageKind: .fightMetrics,
            length: .automatic, batchID: UUID().uuidString, candidates: [], options: WizardOptions(),
            fight: MiniWizardFight(actions: [], picks: [pick], names: [:]))
        store.fightEvents = [videoID: [FightEventRecord(id: 10, videoID: videoID, time: 3,
                                                       fighterKey: "fighter", action: "takedown", points: 2)]]
        #expect(store.miniRuns[.fightMetrics]?.fight?.actions.map(\.id) == [10])
        #expect(store.miniRuns[.fightMetrics]?.fight?.picks == [pick])
        store.addMiniFightPicks([(range: 4...5, eventIDs: [10])])
        store.deleteAllMiniFightPicks()
        try await store.fightPickSaveTask?.value
        #expect(store.miniRuns[.fightMetrics]?.fight?.picks.isEmpty == true)
        #expect(try await temp.database.fetchFightPicks(projectID: projectID, videoID: videoID).isEmpty)
    }

    @Test("A Highlights read error keeps its remembered batch; a successful empty read forgets it")
    func highlightsReadFailure() async throws {
        let temp = try await TempDatabase()
        let (store, projectID, videoID) = try await makeStore(temp)
        let video = try #require(store.miniRuns[.transcript]?.video)
        let profileName = store.activeProfile.profileName
        let batch = UUID().uuidString
        MiniWizardMemory.rememberHighlightBatch(batch, profileName: profileName, projectID: projectID,
                                                videoID: videoID, length: .automatic, setKey: "")
        defer {
            MiniWizardMemory.forgetHighlightBatch(batch, profileName: profileName, projectID: projectID,
                                                  videoID: videoID, length: .automatic, setKey: "")
        }
        let connection = try SQLiteConnection(path: temp.path.path)
        try connection.execute("ALTER TABLE wizard_selections RENAME TO unavailable_selections")
        var flow = MiniWizardFlow()
        flow.video = video
        store.restoreMiniHighlights(flow: flow)
        await store.miniFootageTask?.value
        #expect(!store.errorQueue.isEmpty)
        #expect(MiniWizardMemory.highlightBatch(profileName: profileName, projectID: projectID,
            videoID: videoID, length: .automatic, setKey: "") == batch)
        try connection.execute("ALTER TABLE unavailable_selections RENAME TO wizard_selections")
        store.restoreMiniHighlights(flow: flow)
        await store.miniFootageTask?.value
        #expect(MiniWizardMemory.highlightBatch(profileName: profileName, projectID: projectID,
            videoID: videoID, length: .automatic, setKey: "") == nil)
        await store.flushMiniReel()
    }
}
