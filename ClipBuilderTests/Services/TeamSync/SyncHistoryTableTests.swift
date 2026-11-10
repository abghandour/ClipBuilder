import Foundation
import Testing
@testable import Clip_Builder

/// Highlight History Phase 3: projects, memberships, highlights and picks.
struct SyncHistoryTableTests {
    @Test("History tables follow footage, exist locally and keep the planned natural keys")
    func historyTables() async throws {
        let temp = try await TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        #expect(SyncTable.history.map(\.name) == ["projects", "project_videos", "wizard_highlights",
                                                  "transcript_picks", "fight_picks", "qa_picks"])
        #expect(Array(SyncTable.all.suffix(SyncTable.history.count)) == SyncTable.history)
        for table in SyncTable.history {
            let local = try raw.columnNames(of: table.name)
            for column in table.columns + ["sync_id"] {
                #expect(local.contains(column), "\(table.name).\(column)")
            }
            for (column, parent) in table.references {
                #expect(table.columns.contains(column), "\(table.name).\(column)")
                #expect(SyncTable.all.contains { $0.name == parent }, "\(table.name) -> \(parent)")
            }
            for column in ["profile_name", "thumbnail_video_id", "ui_state_json", "selection_id", "take_id", "generated_video_id"] {
                #expect(!table.columns.contains(column), "\(table.name).\(column) is local-only")
            }
        }
        let keys = Dictionary(uniqueKeysWithValues: SyncTable.history.map { ($0.name, $0.naturalKey) })
        #expect(keys["wizard_highlights"] == [])
        #expect(keys["transcript_picks"] == [])
        #expect(keys["fight_picks"] == [])
        #expect(keys["qa_picks"] == ["project_id", "video_id", "scene_id"])
        #expect(keys["projects"] == ["name", "created_at"])
        #expect(keys["project_videos"] == ["project_id", "video_id"])
        #expect(SyncEngine.understoodSchemaVersion == 13)
    }

    @Test("Applying the same pulled project row twice updates it (profile_name is supplied on every upsert)")
    func projectRowAppliedTwice() async throws {
        let temp = try await TempDatabase()
        try await temp.database.ensureDefaultProject(profileName: "Brand", legacyTimelineJSON: nil)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await temp.database.bindSync(to: scope)
        let raw = try SQLiteConnection(path: temp.path.path)
        let table = try SyncTable.named("projects")
        let syncID = UUID().uuidString.lowercased()
        var wire = try SyncMapping.wire(local: ["name": .text("Launch"), "created_at": .text("2026-01-01 00:00:00"),
                                                "last_opened_at": .text("2026-01-02 00:00:00"),
                                                "archived": .integer(0), "is_home": .integer(0)],
                                        syncID: syncID, scope: scope, table: table)
        #expect(try await temp.database.applySyncRows([wire], scope: scope, table: table, advanceCursor: false))
        wire["name"] = .string("Launch v2")
        #expect(try await temp.database.applySyncRows([wire], scope: scope, table: table, advanceCursor: false))
        let rows = try raw.query("SELECT * FROM projects WHERE sync_id = ?", [.text(syncID)])
        #expect(rows.count == 1)
        #expect(rows.first?["name"]?.stringValue == "Launch v2")
        #expect(rows.first?["profile_name"]?.stringValue == "Brand")
        #expect(rows.first?["is_home"]?.intValue == 0)
    }

    @Test("Every Mac's Home shares one sync_id; a teammate's Home updates the local Home and its tombstone is ignored")
    func sharedHomeIdentity() async throws {
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let table = try SyncTable.named("projects")
        let first = try await TempDatabase(), second = try await TempDatabase()
        try await first.database.ensureDefaultProject(profileName: "Brand", legacyTimelineJSON: nil)
        try await second.database.ensureDefaultProject(profileName: "Brand", legacyTimelineJSON: nil)
        let firstRaw = try SQLiteConnection(path: first.path.path), secondRaw = try SQLiteConnection(path: second.path.path)
        // Different names and creation times: the identity must not depend on them.
        try firstRaw.execute("UPDATE projects SET name = 'Home A', created_at = '2026-01-01 00:00:00' WHERE is_home = 1")
        try secondRaw.execute("UPDATE projects SET name = 'Home B', created_at = '2026-02-01 00:00:00' WHERE is_home = 1")
        try await first.database.bindSync(to: scope)
        try await second.database.bindSync(to: scope)

        let firstChanges = try await first.database.pendingSyncChanges(scope: scope, limit: 50, table: table)
        let secondChanges = try await second.database.pendingSyncChanges(scope: scope, limit: 50, table: table)
        let home = Database.homeSyncID(scope: scope)
        #expect(try firstRaw.query("SELECT sync_id FROM projects WHERE is_home = 1").first?["sync_id"]?.stringValue == home)
        #expect(try secondRaw.query("SELECT sync_id FROM projects WHERE is_home = 1").first?["sync_id"]?.stringValue == home)
        let firstHome = try #require(firstChanges.first { $0.syncID == home })
        #expect(secondChanges.contains { $0.syncID == home })

        // The second Mac has pushed; the first Mac's Home then arrives.
        try await second.database.acknowledgeSyncChanges(secondChanges)
        let before = try secondRaw.query("SELECT COUNT(*) AS n FROM projects").first?["n"]?.intValue
        _ = try await second.database.applySyncRows([firstHome.wire], scope: scope, table: table, advanceCursor: false)
        #expect(try secondRaw.query("SELECT COUNT(*) AS n FROM projects").first?["n"]?.intValue == before)
        let merged = try #require(try secondRaw.query("SELECT * FROM projects WHERE sync_id = ?", [.text(home)]).first)
        #expect(merged["is_home"]?.intValue == 1)
        #expect(merged["name"]?.stringValue == "Home A")
        #expect(merged["profile_name"]?.stringValue == "Brand")

        // A Home without the shared identity is never inserted as a second project.
        var stray = firstHome.wire
        stray["sync_id"] = .string(UUID().uuidString.lowercased())
        _ = try await second.database.applySyncRows([stray], scope: scope, table: table, advanceCursor: false)
        #expect(try secondRaw.query("SELECT COUNT(*) AS n FROM projects").first?["n"]?.intValue == before)

        // A tombstone for the shared Home is ignored.
        let tombstone = try SyncMapping.wire(local: nil, syncID: home, scope: scope, table: table)
        _ = try await second.database.applySyncRows([tombstone], scope: scope, table: table, advanceCursor: false)
        #expect(try secondRaw.query("SELECT 1 FROM projects WHERE is_home = 1").count == 1)
    }

    @Test("A fight pick waits for fight events that have not arrived instead of dropping them")
    func fightPickWaitsForEvents() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        try await temp.database.ensureDefaultProject(profileName: "Brand", legacyTimelineJSON: nil)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await temp.database.bindSync(to: scope)
        let raw = try SQLiteConnection(path: temp.path.path)
        let videoSyncID = try #require(try raw.query("SELECT sync_id FROM videos WHERE id = ?", [.integer(videoID)]).first?["sync_id"]?.stringValue)
        let eventSyncID = UUID().uuidString.lowercased()
        let picks = try SyncTable.named("fight_picks")
        let pickID = UUID().uuidString.lowercased()
        let pick = try SyncMapping.wire(local: ["video_id": .text(videoSyncID), "project_id": .null, "position": .integer(0),
                                                "start_time": .real(1), "end_time": .real(2), "original_start": .real(1),
                                                "original_end": .real(2), "scene_id": .null,
                                                "event_ids": .text("[\"\(eventSyncID)\"]")],
                                        syncID: pickID, scope: scope, table: picks)
        _ = try await temp.database.applySyncRows([pick], scope: scope, table: picks, advanceCursor: false)
        #expect(try raw.query("SELECT 1 FROM fight_picks WHERE sync_id = ?", [.text(pickID)]).isEmpty)
        #expect(try raw.query("SELECT 1 FROM sync_pending_parents WHERE \"table\" = 'fight_picks'").count == 1)

        let events = try SyncTable.named("fight_events")
        let event = try SyncMapping.wire(local: ["video_id": .text(videoSyncID), "at_time": .real(1.5), "fighter_key": .text("a"),
                                                 "action": .text("jab"), "points": .real(1), "provider": .null, "model": .null,
                                                 "target_key": .null, "end_time": .null, "outcome": .null, "detail": .null,
                                                 "scoring_version": .integer(1)],
                                         syncID: eventSyncID, scope: scope, table: events)
        _ = try await temp.database.applySyncRows([event], scope: scope, table: events, advanceCursor: false)
        let localEvent = try #require(try raw.query("SELECT id FROM fight_events WHERE sync_id = ?", [.text(eventSyncID)]).first?["id"]?.intValue)
        #expect(try await temp.database.retrySyncParents(scope: scope, table: picks))
        #expect(try raw.query("SELECT 1 FROM sync_pending_parents").isEmpty)
        #expect(try raw.query("SELECT event_ids FROM fight_picks WHERE sync_id = ?", [.text(pickID)]).first?["event_ids"]?.stringValue
                == "[\(localEvent)]")
    }

    @Test("Highlights with a NULL parent and picks with NULL project/scene apply without waiting for parents")
    func nullReferences() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        try await temp.database.ensureDefaultProject(profileName: "Brand", legacyTimelineJSON: nil)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await temp.database.bindSync(to: scope)
        let raw = try SQLiteConnection(path: temp.path.path)
        let projectSyncID = try #require(try raw.query("SELECT sync_id FROM projects WHERE is_home = 1").first?["sync_id"]?.stringValue)
        let videoSyncID = try #require(try raw.query("SELECT sync_id FROM videos WHERE id = ?", [.integer(videoID)]).first?["sync_id"]?.stringValue)

        let highlights = try SyncTable.named("wizard_highlights")
        let parentID = UUID().uuidString.lowercased(), childID = UUID().uuidString.lowercased()
        let child = try SyncMapping.wire(local: ["project_id": .text(projectSyncID), "flow": .text("express"),
                                                 "video_hashes_json": .text("[]"), "footage_json": .text("[]"), "settings_json": .text("{}"),
                                                 "parent_id": .text(parentID), "created_at": .text("2026-01-02")],
                                         syncID: childID, scope: scope, table: highlights)
        let parent = try SyncMapping.wire(local: ["project_id": .text(projectSyncID), "flow": .text("express"),
                                                  "video_hashes_json": .text("[]"), "footage_json": .text("[]"), "settings_json": .text("{}"),
                                                  "parent_id": .null, "created_at": .text("2026-01-01")],
                                          syncID: parentID, scope: scope, table: highlights)
        // The child arrives first, waits, then resolves once its parent lands.
        _ = try await temp.database.applySyncRows([child, parent], scope: scope, table: highlights, advanceCursor: false)
        #expect(try raw.query("SELECT 1 FROM sync_pending_parents WHERE \"table\" = 'wizard_highlights'").count == 1)
        _ = try await temp.database.retrySyncParents(scope: scope, table: highlights)
        #expect(try raw.query("SELECT 1 FROM sync_pending_parents").isEmpty)
        let localParent = try #require(try raw.query("SELECT id, parent_id FROM wizard_highlights WHERE sync_id = ?", [.text(parentID)]).first)
        if case .null? = localParent["parent_id"] {} else { Issue.record("a NULL parent must stay NULL") }
        #expect(try raw.query("SELECT parent_id FROM wizard_highlights WHERE sync_id = ?", [.text(childID)]).first?["parent_id"]?.intValue
                == localParent["id"]?.intValue)

        let picks = try SyncTable.named("transcript_picks")
        let pick = try SyncMapping.wire(local: ["video_id": .text(videoSyncID), "project_id": .null, "position": .integer(0),
                                                "start_time": .real(1), "end_time": .real(2), "original_start": .real(1),
                                                "original_end": .real(2), "scene_id": .null, "kept": .integer(1)],
                                        syncID: UUID().uuidString.lowercased(), scope: scope, table: picks)
        #expect(try await temp.database.applySyncRows([pick], scope: scope, table: picks, advanceCursor: false))
        #expect(try raw.query("SELECT 1 FROM sync_pending_parents").isEmpty)
        let localPick = try #require(try raw.query("SELECT project_id, scene_id FROM transcript_picks").first)
        if case .null? = localPick["project_id"] {} else { Issue.record("project_id must pull as NULL") }
        if case .null? = localPick["scene_id"] {} else { Issue.record("scene_id must pull as NULL") }
    }
}
