import Foundation
import Testing
@testable import Clip_Builder

/// Scenes on a video without an analysis run: the UNIQUE index skips NULL
/// run_ids, so these paths must find the existing row themselves.
@Suite("Scene identity")
struct SceneIdentityTests {
    private func videoWithoutRun(in temp: TempDatabase) async throws -> Int64 {
        let url = temp.path.deletingLastPathComponent().appendingPathComponent("no-run.mp4")
        try Data("fixture".utf8).write(to: url)
        return try await temp.database.registerVideo(hash: UUID().uuidString, filename: "no-run.mp4", path: url.path,
                                                     duration: 60, width: 1920, height: 1080, wide: true)
    }

    private func sceneRows(_ raw: SQLiteConnection, videoID: Int64) throws -> [SQLRow] {
        try raw.query("SELECT id, sync_id, start_time, end_time, favorite, narrative FROM scenes WHERE video_id = ? ORDER BY id",
                      [.integer(videoID)])
    }

    @Test("Saving picks twice on a video without a run reuses one scene per range")
    func picksWithoutRunReuseScenes() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await videoWithoutRun(in: temp)
        let projectID = try await database.createProject(profileName: "Test", name: "Picks", videoIDs: [videoID])
        try await database.replaceTranscripts(videoID: videoID, transcriptionKey: "t", language: "en", isTranslation: false,
            segments: [TranscriptSegment(start: 0, end: 3, text: "One two three", words: nil),
                       TranscriptSegment(start: 3, end: 6, text: "Four five six", words: nil)],
            provider: "test", model: "test")
        let rows = try await database.fetchTranscripts(videoID: videoID)
        _ = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 3)
        _ = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 3, end: 6)
        let picks = try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID)
        var options = WizardStep1Options()
        options.formatPreset = "custom"
        for batch in ["first", "second", "third"] {
            let candidates = try await database.replaceMiniTranscriptSelections(projectID: projectID, videoID: videoID,
                miniBatch: batch, picks: picks, rows: rows, options: options)
            #expect(candidates.count == 2)
            #expect(candidates.allSatisfy { $0.take.plan.clips.count == 1 })
        }
        let raw = try SQLiteConnection(path: temp.path.path)
        let scenes = try sceneRows(raw, videoID: videoID)
        #expect(scenes.count == 2, "one scene per pick range, not one per save")
        #expect(try await database.fetchScenes(ids: Set(scenes.compactMap { $0["id"]?.intValue })).allSatisfy { $0.runID == nil })
        // The story scene path shares the lookup.
        let story = try await database.storyScene(videoID: videoID, start: 0, end: 3)
        #expect(story?.id == scenes.first?["id"]?.intValue)
    }

    @Test("Pulling an identity a local duplicate already holds updates that row and keeps the batch")
    func pullOntoDuplicateKeepsGoing() async throws {
        let temp = try await TempDatabase()
        let videoID = try await videoWithoutRun(in: temp)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await temp.database.bindSync(to: scope)
        let raw = try SQLiteConnection(path: temp.path.path)
        for _ in 0..<2 {
            try raw.execute("INSERT INTO scenes (video_id, run_id, start_time, end_time) VALUES (?, NULL, 1.5, 4.0)", [.integer(videoID)])
        }
        try raw.execute("DELETE FROM sync_outbox")
        let scenes = try sceneRows(raw, videoID: videoID)
        let ids = try #require(scenes.count == 2 ? scenes.compactMap { $0["sync_id"]?.stringValue } : nil)
        let videoSyncID = try #require(try raw.query("SELECT sync_id FROM videos WHERE id = ?", [.integer(videoID)]).first?["sync_id"]?.stringValue)
        let table = try SyncTable.named("scenes")
        var wire = try SyncMapping.wire(local: ["video_id": .text(videoSyncID), "run_id": .null, "start_time": .real(1.5),
                                                "end_time": .real(4.0), "excluded": .integer(0), "ignored": .integer(0),
                                                "favorite": .integer(1), "curated": .integer(0), "stack_choice": .integer(0),
                                                "narrative": .text("pulled")],
                                       syncID: ids[1], scope: scope, table: table)
        wire["server_updated_at"] = .string("2026-11-05T19:42:29.000001+00:00")
        try await temp.database.applySyncRows([wire], scope: scope, table: table)
        let after = try sceneRows(raw, videoID: videoID)
        #expect(after.compactMap { $0["sync_id"]?.stringValue } == ids, "neither row changes identity")
        #expect(after[1]["favorite"]?.intValue == 1 && after[1]["narrative"]?.stringValue == "pulled",
                "the row holding the identity takes the pulled values")
        #expect(after[0]["favorite"]?.intValue == 0, "the other duplicate is untouched")
        #expect(try await temp.database.syncCursor(table: table) != nil, "the batch was applied")
    }

    @Test("Opening a schema-44 database merges NULL-run duplicates onto the first copy and retires the rest")
    func migrationMergesDuplicates() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await videoWithoutRun(in: temp)
        let projectID = try await database.createProject(profileName: "Test", name: "Picks", videoIDs: [videoID])
        let pick = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 1.5, end: 4)
        try await database.bindSync(to: SyncScope(teamID: UUID(), profileID: UUID()))
        let raw = try SQLiteConnection(path: temp.path.path)
        for _ in 0..<3 {
            try raw.execute("INSERT INTO scenes (video_id, run_id, start_time, end_time) VALUES (?, NULL, 1.5, 4.0)", [.integer(videoID)])
        }
        try raw.execute("INSERT INTO scenes (video_id, run_id, start_time, end_time) VALUES (?, NULL, 10, 12)", [.integer(videoID)])
        let before = try sceneRows(raw, videoID: videoID)
        let copies = before.filter { $0["start_time"]?.doubleValue == 1.5 }
        let keeper = try #require(copies.first?["id"]?.intValue)
        let other = try #require(before.first { $0["start_time"]?.doubleValue == 10 }?["id"]?.intValue)
        let extras = copies.dropFirst().compactMap { $0["id"]?.intValue }
        let extraSyncIDs = Set(copies.dropFirst().compactMap { $0["sync_id"]?.stringValue })
        try raw.execute("INSERT INTO scene_tags (scene_id, tag) VALUES (?, 'transcript-pick')", [.integer(keeper)])
        try raw.execute("INSERT INTO scene_tags (scene_id, tag) VALUES (?, 'transcript-pick')", [.integer(extras[0])])
        try raw.execute("INSERT INTO scene_tags (scene_id, tag) VALUES (?, 'podcast')", [.integer(extras[1])])
        try raw.execute("UPDATE transcript_picks SET scene_id = ? WHERE id = ?", [.integer(extras[1]), .integer(pick.id)])
        try raw.execute("UPDATE scenes SET parent_scene_id = ? WHERE id = ?", [.integer(extras[0]), .integer(other)])
        // Edits on a later copy: the keeper has defaults and takes them.
        try raw.execute("UPDATE scenes SET favorite = 1, narrative = 'later copy', edit_start = 2.0 WHERE id = ?", [.integer(extras[1])])
        try raw.execute("UPDATE scenes SET narrative = 'first copy' WHERE id = ?", [.integer(keeper)])
        try raw.execute("INSERT INTO grades (scene_id, score) VALUES (?, 4)", [.integer(keeper)])
        try raw.execute("INSERT INTO grades (scene_id, score) VALUES (?, 2)", [.integer(extras[0])])
        let document = """
            {"videoTrack":[{"type":"clip","id":\(extras[1]),"duration":2.5},{"type":"clip","id":\(other),"duration":2}],\
            "areas":[{"sceneID":\(extras[0])}],"picks":{"scene_ids":[\(extras[0]),\(other)]}}
            """
        try raw.execute("INSERT INTO timelines (project_id, name, document_json) VALUES (?, 'T', ?)", [.integer(projectID), .text(document)])
        try raw.execute("DELETE FROM sync_outbox")
        try raw.execute("PRAGMA user_version = 44")

        // The real migration, on open.
        let reopened = try await Task.detached { try Database(path: temp.path) }.value

        let after = try sceneRows(raw, videoID: videoID)
        #expect(after.compactMap { $0["id"]?.intValue } == [keeper, other])
        let merged = try #require(try raw.query("SELECT favorite, narrative, edit_start FROM scenes WHERE id = ?", [.integer(keeper)]).first)
        #expect(merged["favorite"]?.intValue == 1 && merged["edit_start"]?.doubleValue == 2.0, "defaults take the copy's edits")
        #expect(merged["narrative"]?.stringValue == "first copy", "the keeper's own value wins")
        let tags = Set(try raw.query("SELECT tag FROM scene_tags WHERE scene_id = ?", [.integer(keeper)]).compactMap { $0["tag"]?.stringValue })
        #expect(tags == ["transcript-pick", "podcast"])
        #expect(try raw.query("SELECT 1 FROM scene_tags WHERE scene_id IN (?, ?)", [.integer(extras[0]), .integer(extras[1])]).isEmpty)
        #expect(try await reopened.fetchTranscriptPicks(projectID: projectID, videoID: videoID).first?.sceneID == keeper)
        #expect(try raw.query("SELECT parent_scene_id FROM scenes WHERE id = ?", [.integer(other)]).first?["parent_scene_id"]?.intValue == keeper)
        #expect(try raw.query("SELECT score FROM grades WHERE scene_id = ? ORDER BY score", [.integer(keeper)]).compactMap { $0["score"]?.intValue } == [2, 4])
        let timeline = try #require(try raw.query("SELECT document_json FROM timelines").first?["document_json"]?.stringValue)
        #expect(SceneReferences.ids(in: timeline) == [keeper, other], "saved timelines follow the keeper")
        let outbox = try raw.query("SELECT \"table\", sync_id, op FROM sync_outbox")
        func ids(_ table: String, _ op: String) -> Set<String> {
            Set(outbox.filter { $0["table"]?.stringValue == table && $0["op"]?.stringValue == op }.compactMap { $0["sync_id"]?.stringValue })
        }
        #expect(ids("scenes", "delete") == extraSyncIDs, "every retired copy goes out as a tombstone")
        let keeperSyncID = try #require(copies.first?["sync_id"]?.stringValue)
        #expect(ids("scenes", "upsert").contains(keeperSyncID), "the keeper goes out again under its surviving identity")
        #expect(ids("grades", "upsert").count == 2, "both grades re-push so a teammate's cascaded copies come back")
        #expect(ids("scene_tags", "upsert").count == 2)
        #expect(ids("transcript_picks", "upsert").count == 1)
        #expect(try raw.query("PRAGMA user_version").first?.values.first?.intValue == Database.schemaVersion)
    }
}
