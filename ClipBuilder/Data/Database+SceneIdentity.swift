import Foundation

extension Database {
    /// The scene for a range on a run, inserted when missing.
    ///
    /// `scenes` is UNIQUE on (video_id, run_id, start_time, end_time), but
    /// SQLite treats every NULL run_id as distinct, so an `ON CONFLICT` upsert
    /// never fires for a video without an analysis run: each save of its picks
    /// added one more copy of every scene, and Team Sync pushed each copy under
    /// its own identity (eleven copies per pick on a teammate's Mac on
    /// 2026-11-05, which then broke every pull with a sync_id collision). The
    /// lookup uses IS so it finds the existing row either way.
    func sceneID(videoID: Int64, runID: Int64?, start: Double, end: Double) throws -> Int64 {
        let run = runID.map(SQLValue.integer) ?? .null
        if let existing = try connection.query("""
            SELECT id FROM scenes WHERE video_id = ? AND run_id IS ? AND start_time = ? AND end_time = ?
            ORDER BY id LIMIT 1
            """, [.integer(videoID), run, .real(start), .real(end)]).first?["id"]?.intValue {
            return existing
        }
        try connection.execute("INSERT INTO scenes (video_id, run_id, start_time, end_time) VALUES (?, ?, ?, ?)",
                               [.integer(videoID), run, .real(start), .real(end)])
        return connection.lastInsertRowID
    }

    /// Scene columns a user or the AI may have set on a later copy. Flags
    /// default to 0, everything else to NULL; the keeper takes a copy's value
    /// where its own is still the default.
    private static let mergedSceneColumns = [
        "excluded", "ignored", "favorite", "favorite_provider", "favorite_model", "crop_x_frac", "free_crops",
        "center_stage_path", "curated", "curated_provider", "curated_model", "edit_start", "edit_end", "narrative",
        "score", "excitement", "stack_choice", "models_json",
    ]

    /// JSON columns that name scenes by local id (see `SceneReferences`).
    private static let sceneJSONColumns = [
        ("timelines", "document_json"), ("wizard_selection_takes", "plan_json"), ("generated_videos", "timeline_json"),
    ]

    /// Schema 45: fold the copies that NULL-run inserts left behind into one
    /// scene per range. The lowest id stays and takes any edits the copies
    /// carried; tags, picks, grades, reviews, child scenes and the saved
    /// timeline, take and output JSON move to it; the other copies are deleted.
    ///
    /// Runs after the sync triggers are installed: the deletes queue
    /// tombstones so a teammate's copies retire too, and the keeper with its
    /// tags, picks and grades are queued so they go out again under the
    /// surviving identity. A Mac whose single copy carried a retired identity
    /// loses it to the tombstone and gets it back from that re-push (its
    /// cascaded grades and tags come back with it). Foreign keys are off
    /// during migration; children are moved by hand.
    nonisolated static func mergeDuplicateScenes(_ db: SQLiteConnection) throws {
        let groups = try db.query("""
            SELECT MIN(id) AS keeper, GROUP_CONCAT(id) AS ids FROM scenes WHERE run_id IS NULL
            GROUP BY video_id, start_time, end_time HAVING COUNT(*) > 1
            """)
        var map: [Int64: Int64] = [:]
        for group in groups {
            guard let keeper = group["keeper"]?.intValue, let ids = group["ids"]?.stringValue else { continue }
            let extras = ids.split(separator: ",").compactMap { Int64($0) }.filter { $0 != keeper }.sorted()
            for extra in extras {
                map[extra] = keeper
                try mergeSceneEdits(db, from: extra, into: keeper)
                try db.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) SELECT ?, tag FROM scene_tags WHERE scene_id = ?",
                               [.integer(keeper), .integer(extra)])
                try db.execute("DELETE FROM scene_tags WHERE scene_id = ?", [.integer(extra)])
                for table in ["transcript_picks", "fight_picks", "grades", "clip_reviews"] {
                    try db.execute("UPDATE \(table) SET scene_id = ? WHERE scene_id = ?", [.integer(keeper), .integer(extra)])
                }
                // UNIQUE(project_id, video_id, scene_id): a pick the keeper already has stays once.
                try db.execute("UPDATE OR IGNORE qa_picks SET scene_id = ? WHERE scene_id = ?", [.integer(keeper), .integer(extra)])
                try db.execute("DELETE FROM qa_picks WHERE scene_id = ?", [.integer(extra)])
                try db.execute("UPDATE scenes SET parent_scene_id = ? WHERE parent_scene_id = ?", [.integer(keeper), .integer(extra)])
                try db.execute("DELETE FROM scenes WHERE id = ?", [.integer(extra)])
            }
            try queueForPush(db, table: "scenes", column: "id", keeper: keeper)
            for table in ["scene_tags", "transcript_picks", "fight_picks", "qa_picks", "grades"] {
                try queueForPush(db, table: table, column: "scene_id", keeper: keeper)
            }
        }
        guard !map.isEmpty else { return }
        for (table, column) in sceneJSONColumns {
            for row in try db.query("SELECT id, \(column) AS json FROM \(table)") {
                guard let id = row["id"]?.intValue, let json = row["json"]?.stringValue,
                      let rewritten = SceneReferences.remapping(json, map: map) else { continue }
                try db.execute("UPDATE \(table) SET \(column) = ? WHERE id = ?", [.text(rewritten), .integer(id)])
            }
        }
        NSLog("Scenes migration: merged %d duplicate ranges (%d copies)", groups.count, map.count)
    }

    /// Queues the keeper's rows of `table` to go out again, changed here or
    /// not. Written to the outbox directly: the update triggers only queue
    /// a row whose synced columns changed, so touching it does nothing.
    /// Same conditions as those triggers (an attached profile, sync not
    /// suspended, a row that has an identity).
    private nonisolated static func queueForPush(_ db: SQLiteConnection, table: String, column: String, keeper: Int64) throws {
        guard try db.columnNames(of: table).contains("sync_id") else { return }
        let rows = """
            SELECT sync_id FROM \(table) WHERE \(column) = ? AND sync_id IS NOT NULL
                AND EXISTS (SELECT 1 FROM sync_binding) AND (SELECT suspended FROM sync_control WHERE id = 1) = 0
            """
        try db.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND op = 'upsert' AND sync_id IN (\(rows))",
                       [.text(table), .integer(keeper)])
        try db.execute("INSERT INTO sync_outbox(\"table\", sync_id, op) SELECT ?, sync_id, 'upsert' FROM (\(rows))",
                       [.text(table), .integer(keeper)])
    }

    private nonisolated static func mergeSceneEdits(_ db: SQLiteConnection, from extra: Int64, into keeper: Int64) throws {
        let columns = mergedSceneColumns.joined(separator: ", ")
        guard let source = try db.query("SELECT \(columns) FROM scenes WHERE id = ?", [.integer(extra)]).first,
              let target = try db.query("SELECT \(columns) FROM scenes WHERE id = ?", [.integer(keeper)]).first else { return }
        func isDefault(_ value: SQLValue?) -> Bool {
            switch value {
            case nil, .null: return true
            case .integer(let v): return v == 0
            case .text(let v): return v.isEmpty
            default: return false
            }
        }
        var assignments: [String] = []
        var values: [SQLValue] = []
        for column in mergedSceneColumns where isDefault(target[column]) && !isDefault(source[column]) {
            assignments.append("\(column) = ?")
            values.append(source[column] ?? .null)
        }
        guard !assignments.isEmpty else { return }
        try db.execute("UPDATE scenes SET \(assignments.joined(separator: ", ")) WHERE id = ?", values + [.integer(keeper)])
    }
}
