import Foundation
import Testing
@testable import Clip_Builder

@Suite("Analysis run storage and identity")
struct AnalysisRunsStorageTests {
    private func twoRuns(_ temp: TempDatabase) async throws -> (videoID: Int64, old: AnalysisRun, new: AnalysisRun) {
        let videoID = try await temp.seedVideo()
        let old = try #require(try await temp.database.fetchAnalysisRuns().first)
        let newID = try await temp.database.saveAnalysis(videoID: videoID, runName: "New", instructions: "", sampleInterval: 1,
            notesJSON: nil, tagRanges: ["new": [(0, 8), (8, 10)]], moments: [], analyzedTags: [], provider: nil, model: nil,
            mode: "visual", settings: AnalysisRunSettings(pipeline: AnalysisPipeline.visualPass))
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE analysis_runs SET created_at = '2026-10-11 10:00:00' WHERE id = ?", [.integer(old.id)])
        try raw.execute("UPDATE analysis_runs SET created_at = '2026-10-12 10:00:00' WHERE id = ?", [.integer(newID)])
        let new = try #require(try await temp.database.fetchAnalysisRuns().first { $0.id == newID })
        return (videoID, old, new)
    }

    @Test func discoveryUsesOneBatchWhileHistoryRetainsAll() async throws {
        let temp = try TempDatabase()
        let rows = try await twoRuns(temp)
        let projectID = try await temp.database.createProject(profileName: "Fixture", name: "Scope", videoIDs: [rows.videoID])
        let history = try await temp.database.fetchScenes(projectID: projectID, scope: .history)
        #expect(history.count == 3)
        let automatic = try await temp.database.fetchScenes(projectID: projectID, scope: .active)
        #expect(Set(automatic.compactMap(\.runID)) == [rows.new.id])
        let passes = try await temp.database.fetchAnalysisPasses()
        #expect(passes.contains { $0.pass == .scenes && $0.runKey == rows.new.runKey && $0.status == .completed })
        try await temp.database.setActiveRunKey(videoID: rows.videoID, runKey: rows.old.runKey)
        let pinned = try await temp.database.fetchScenes(scope: .active)
        #expect(Set(pinned.compactMap(\.runID)) == [rows.old.id])
        #expect(try await temp.database.fetchScenes(scope: .history).count == 3)
        let snapshot = try await temp.database.fetchLibrarySnapshot()
        #expect(snapshot.scenes == pinned && snapshot.historyScenes.count == 3)
    }

    @Test func identityIgnoresPinAndCurrentProjectScope() async throws {
        let temp = try TempDatabase()
        let rows = try await twoRuns(temp)
        let key = try #require(rows.old.runKey)
        let oldScenes = try await temp.database.fetchScenes(videoID: rows.videoID, runKey: key)
        let old = try #require(oldScenes.first)
        try await temp.database.setActiveRunKey(videoID: rows.videoID, runKey: rows.new.runKey)
        let emptyProject = try await temp.database.createProject(profileName: "Fixture", name: "No footage")
        #expect(try await temp.database.fetchScenes(projectID: emptyProject, scope: .active).isEmpty)
        #expect(try await temp.database.fetchScenes(ids: [old.id]) == [old])
        #expect(try await temp.database.fetchScene(id: old.id) == old)
    }

    @Test func legacyTakeHydrationUsesHistoryAndKeepsItsSceneID() async throws {
        let temp = try TempDatabase()
        let rows = try await twoRuns(temp)
        let old = try #require(try await temp.database.fetchScenes(scope: .history).first { $0.runID == rows.old.id })
        let projectID = try await temp.database.createProject(profileName: "Fixture", name: "Legacy", videoIDs: [rows.videoID])
        let selectionID = try await temp.database.insertWizardSelection(projectID: projectID, name: "Selection", recipe: "custom", step1Options: WizardOptions().step1)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: old.id, start: 0, end: 8)])
        let raw = try SQLiteConnection(path: temp.path.path)
        let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        try raw.execute("INSERT INTO wizard_selection_takes(selection_id, ordinal, plan_json, scene_ids_json) VALUES (?, 1, ?, ?)",
                        [.integer(selectionID), .text(json), .text("[\(old.id)]")])
        let takeID = raw.lastInsertRowID
        let take = try #require(try await temp.database.wizardSelectionTake(id: takeID))
        #expect(take.plan.footage?.first?.sceneID == old.id)
        #expect(take.plan.clips.first?.sceneID == old.id)
        let resolvedScenes = try await temp.database.scenesForSavedPlan(take.plan, projectID: projectID)
        #expect(resolvedScenes.map(\.id) == [old.id])
    }

    @Test @MainActor func builderFramingSurvivesPinChangeThroughReferencedScenes() async throws {
        let temp = try TempDatabase()
        let rows = try await twoRuns(temp)
        let old = try #require(try await temp.database.fetchScenes(scope: .history).first { $0.runID == rows.old.id })
        try await temp.database.setSceneCropX(old.id, fraction: 0.2)
        let projectID = try await temp.database.createProject(profileName: "Fixture", name: "Builder", videoIDs: [rows.videoID])
        let clip = Fixtures.timelineClip(sceneID: old.id, sourceStart: 0, duration: 8)
        let document = Fixtures.timelineDocument(clips: [clip])
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        _ = try await temp.database.createTimeline(projectID: projectID, name: "Saved", documentJSON: json)
        try await temp.database.setActiveRunKey(videoID: rows.videoID, runKey: rows.old.runKey)
        let first = try await temp.database.fetchLibrarySnapshot(projectID: projectID)
        let model = BuilderTimelineModel(mode: .transient)
        model.seed(document: document, scenes: [])
        model.updateScenes(first.scenes, referencedScenes: first.referencedScenes)
        let before = model.document
        try await temp.database.setActiveRunKey(videoID: rows.videoID, runKey: rows.new.runKey)
        let next = try await temp.database.fetchLibrarySnapshot(projectID: projectID)
        #expect(!next.scenes.contains { $0.id == old.id })
        #expect(next.referencedScenes.contains { $0.id == old.id })
        model.updateScenes(next.scenes, referencedScenes: next.referencedScenes)
        #expect(model.document == before)
        #expect(model.scenes.first { $0.id == old.id }?.cropXFrac == 0.2)
    }

    @Test func mergeCreatesNewBatchWithSceneAndTagUnion() async throws {
        let temp = try TempDatabase()
        let rows = try await twoRuns(temp)
        let preferred = try #require(try await temp.database.fetchScenes(scope: .history).first { $0.runID == rows.old.id })
        try await temp.database.setSceneExcluded(preferred.id, excluded: true)
        let oldScenes = try await temp.database.fetchScenes(scope: .history)
        let mergedID = try await temp.database.mergeAnalysisRuns(ids: [rows.old.id, rows.new.id], preferredID: rows.old.id)
        #expect(mergedID != rows.old.id && mergedID != rows.new.id)
        let active = try await temp.database.fetchScenes(scope: .active)
        #expect(active.count == 2 && active.allSatisfy { $0.runID == mergedID })
        #expect(Set(active.first { $0.startTime == 0 }?.tags ?? []) == ["fixture", "new"])
        #expect(active.first { $0.startTime == 0 }?.excluded == false)
        #expect(try await temp.database.fetchScenes(scope: .history).filter { $0.runID != mergedID } == oldScenes)
        let passes = try await temp.database.fetchAnalysisPasses()
        let merged = try #require(try await temp.database.fetchAnalysisRuns().first { $0.id == mergedID })
        #expect(passes.contains { $0.pass == .scenes && $0.runKey == merged.runKey && $0.status == .completed })
    }

    @Test func mergeKeepsDistinctCuratedRanges() async throws {
        let temp = try TempDatabase()
        let rows = try await twoRuns(temp)
        let old = try #require(try await temp.database.fetchScenes(scope: .history).first { $0.runID == rows.old.id })
        try await temp.database.setSceneEditRange(old.id, start: 1, end: 8)
        let mergedID = try await temp.database.mergeAnalysisRuns(ids: [rows.old.id, rows.new.id], preferredID: rows.old.id)
        let merged = try await temp.database.fetchScenes(scope: .active)
        #expect(merged.count == 3 && merged.allSatisfy { $0.runID == mergedID })
        #expect(Set(merged.map { "\($0.startTime)-\($0.endTime)" }) == ["0.0-8.0", "1.0-8.0", "8.0-10.0"])
    }

    @Test func deleteListsAllReferenceKindsAndClearsPinAtomically() async throws {
        let temp = try TempDatabase()
        let rows = try await twoRuns(temp)
        let scene = try #require(try await temp.database.fetchScenes(scope: .history).first { $0.runID == rows.old.id })
        let projectID = try await temp.database.createProject(profileName: "Fixture", name: "References", videoIDs: [rows.videoID])
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 8)])
        _ = try await temp.database.recordWizardTake(projectID: projectID, options: WizardOptions().step1, plan: plan)
        let document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(sceneID: scene.id, sourceStart: 0, duration: 8)])
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        _ = try await temp.database.createTimeline(projectID: projectID, name: "Builder reference", documentJSON: json)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("INSERT INTO generated_videos(path, timeline_json) VALUES ('/tmp/output.mp4', ?)", [.text(json)])
        let refs = try await temp.database.analysisRunReferences(id: rows.old.id)
        #expect(Set(refs.map(\.kind)) == [.take, .builder, .generated])
        #expect(refs.contains { $0.name == "Builder reference" })
        try await temp.database.setActiveRunKey(videoID: rows.videoID, runKey: rows.old.runKey)
        try raw.execute("CREATE TRIGGER reject_batch_delete BEFORE DELETE ON scenes BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        do {
            try await temp.database.deleteAnalysisRun(id: rows.old.id)
            Issue.record("Expected injected delete failure")
        } catch {}
        #expect(try await temp.database.video(id: rows.videoID)?.activeRunKey == rows.old.runKey)
        #expect(try await temp.database.fetchAnalysisRuns().contains { $0.id == rows.old.id })
        try raw.execute("DROP TRIGGER reject_batch_delete")
        try await temp.database.deleteAnalysisRun(id: rows.old.id)
        #expect(try await temp.database.video(id: rows.videoID)?.activeRunKey == nil)
        #expect(try await temp.database.activeAnalysisRun(videoID: rows.videoID).run?.id == rows.new.id)
        #expect(try await temp.database.fetchScenes(ids: [scene.id]).isEmpty)
    }

    @Test func missingPinIsPreservedAcrossReadsAndDatabaseReopen() async throws {
        let temp = try TempDatabase()
        let rows = try await twoRuns(temp)
        try await temp.database.setActiveRunKey(videoID: rows.videoID, runKey: "not-here-yet")
        _ = try await temp.database.fetchScenes(scope: .active)
        let reopened = try Database(path: temp.path)
        #expect(try await reopened.video(id: rows.videoID)?.activeRunKey == "not-here-yet")
        let resolution = try await reopened.activeAnalysisRun(videoID: rows.videoID)
        #expect(resolution.missingPin && resolution.run?.id == rows.new.id)
    }

    @Test func migrationAddsOptionalLayerAndPassColumns() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let raw = try SQLiteConnection(path: temp.path.path)
        // Reconstruct the previous schema's missing columns without its generated sync triggers.
        for row in try raw.query("SELECT name FROM sqlite_master WHERE type = 'trigger'") {
            let name = try #require(row["name"]?.stringValue)
            try raw.execute("DROP TRIGGER \"\(name)\"")
        }
        try raw.execute("ALTER TABLE videos DROP COLUMN active_run_key")
        try raw.execute("ALTER TABLE videos DROP COLUMN active_transcription_key")
        try raw.execute("ALTER TABLE analysis_passes DROP COLUMN run_key")
        try raw.execute("PRAGMA user_version = 31")
        let reopened = try Database(path: temp.path)
        #expect(try raw.columnNames(of: "videos").isSuperset(of: ["active_run_key", "active_transcription_key"]))
        #expect(try raw.columnNames(of: "analysis_passes").contains("run_key"))
        #expect(try await reopened.video(id: videoID)?.activeRunKey == nil)
        #expect(try raw.query("PRAGMA user_version").first?.values.first?.intValue == Database.schemaVersion)
    }
}
