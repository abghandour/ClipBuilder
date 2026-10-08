import Foundation

extension Database {
    func refreshFootageAvailability() throws {
        for row in try connection.query("SELECT path, drive_file_id FROM videos WHERE path IS NOT NULL UNION ALL SELECT path, drive_file_id FROM generated_videos WHERE path IS NOT NULL") {
            FootageAvailability.refresh(path: row["path"]?.stringValue, driveFileID: row["drive_file_id"]?.stringValue)
        }
    }

    /// Called with foreign keys disabled, inside the migration transaction. Copy
    /// the original DDL so every legacy/local-only column and UNIQUE hash survive.
    nonisolated static func migrateFootageSync(_ db: SQLiteConnection) throws {
        let info = try db.query("PRAGMA table_info(videos)")
        if info.first(where: { $0["name"]?.stringValue == "path" })?["notnull"]?.intValue == 1 {
            guard let original = try db.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'videos'")
                .first?["sql"]?.stringValue else { throw SyncError.invalidRow("videos schema") }
            let dependentDDL = try db.query("SELECT sql FROM sqlite_master WHERE tbl_name = 'videos' AND type IN ('index', 'trigger') AND sql IS NOT NULL")
            let rebuilt = original.replacingOccurrences(of: "CREATE TABLE videos", with: "CREATE TABLE videos_v28")
                .replacingOccurrences(of: "CREATE TABLE IF NOT EXISTS videos", with: "CREATE TABLE videos_v28")
                .replacingOccurrences(of: "path TEXT NOT NULL", with: "path TEXT")
            try db.execute(rebuilt)
            let columns = info.compactMap { $0["name"]?.stringValue }.map { "\"\($0)\"" }.joined(separator: ", ")
            try db.execute("INSERT INTO videos_v28 (\(columns)) SELECT \(columns) FROM videos")
            try db.execute("DROP TABLE videos")
            try db.execute("ALTER TABLE videos_v28 RENAME TO videos")
            for row in dependentDDL {
                if let sql = row["sql"]?.stringValue { try db.executeScript(sql) }
            }
        }
        if try !db.columnNames(of: "analysis_runs").contains("run_key") {
            try db.execute("ALTER TABLE analysis_runs ADD COLUMN run_key TEXT")
        }
        try db.execute("UPDATE analysis_runs SET run_key = lower(hex(randomblob(16))) WHERE run_key IS NULL")
    }

    /// Upgrading an attached Phase 1 profile must seed its existing footage too.
    /// Reopen the join pass for the new tables, preserving Phase 1 cursors/edits.
    nonisolated static func seedFootageSync(_ db: SQLiteConnection) throws {
        guard try !db.query("SELECT 1 FROM sync_binding").isEmpty else { return }
        for table in SyncTable.footage {
            try db.execute("INSERT OR IGNORE INTO sync_seed_progress(\"table\", after_rowid) VALUES (?, 0)", [.text(table.name)])
        }
        try db.execute("UPDATE sync_bootstrap SET complete = 0 WHERE id = 1")
        try db.execute("DELETE FROM sync_join_boundary")
    }
    nonisolated static func migrateTranscriptionSets(_ db: SQLiteConnection) throws {
        try db.executeScript("""
            CREATE TABLE IF NOT EXISTS sync_seed_progress ("table" TEXT PRIMARY KEY, after_rowid INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS sync_run_defaults (video_id INTEGER PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE, applied INTEGER NOT NULL DEFAULT 0);
            """)
        for table in ["transcripts", "speaker_turns"] {
            for column in ["transcription_key", "transcription_created_at"] where try !db.columnNames(of: table).contains(column) {
                try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) TEXT")
            }
        }
        // One legacy set per video, shared by its segments and speaker turns.
        for row in try db.query("SELECT id FROM videos WHERE id IN (SELECT video_id FROM transcripts WHERE transcription_key IS NULL UNION SELECT video_id FROM speaker_turns WHERE transcription_key IS NULL)") {
            let key = UUID().uuidString.lowercased()
            for table in ["transcripts", "speaker_turns"] {
                try db.execute("UPDATE \(table) SET transcription_key = ?, transcription_created_at = '1970-01-01T00:00:00Z' WHERE video_id = ? AND transcription_key IS NULL",
                               [.text(key), row["id"] ?? .null])
            }
        }
        for table in ["transcripts", "speaker_turns"] {
            try db.execute("CREATE INDEX IF NOT EXISTS \(table)_set ON \(table)(video_id, transcription_created_at DESC, transcription_key DESC)")
        }
    }

    func seedSyncRows() async throws {
        for table in SyncTable.all {
            while let progress = try connection.query("SELECT after_rowid FROM sync_seed_progress WHERE \"table\" = ?", [.text(table.name)]).first {
                try Task.checkCancellation()
                let rows = try connection.query("SELECT rowid AS local_rowid, sync_id FROM \(table.name) WHERE rowid > ? ORDER BY rowid LIMIT 500",
                                                [progress["after_rowid"] ?? .integer(0)])
                try connection.transaction {
                    for row in rows {
                        try Task.checkCancellation()
                        try connection.execute("""
                            INSERT INTO sync_outbox("table", sync_id, op)
                            SELECT ?, ?, 'upsert' WHERE NOT EXISTS (SELECT 1 FROM sync_outbox WHERE "table" = ? AND sync_id = ?)
                            """, [.text(table.name), row["sync_id"] ?? .null, .text(table.name), row["sync_id"] ?? .null])
                    }
                    if let last = rows.last {
                        try connection.execute("UPDATE sync_seed_progress SET after_rowid = ? WHERE \"table\" = ?", [last["local_rowid"] ?? .integer(0), .text(table.name)])
                    } else {
                        try connection.execute("DELETE FROM sync_seed_progress WHERE \"table\" = ?", [.text(table.name)])
                    }
                }
                await Task.yield()
            }
        }
    }

    /// Consume only the first arrival for a video that had no local analysis.
    /// The marker remains after consumption, so choosing All Batches is durable.
    func consumeSyncedRunDefaults() throws -> [Int64: Int64] {
        var result: [Int64: Int64] = [:]
        try connection.transaction {
            for row in try connection.query("SELECT video_id FROM sync_run_defaults WHERE applied = 0") {
                guard let video = row["video_id"]?.intValue,
                      let run = try connection.query("SELECT id FROM analysis_runs WHERE video_id = ? ORDER BY created_at DESC, sync_id DESC LIMIT 1", [.integer(video)]).first?["id"]?.intValue else { continue }
                result[video] = run
                try connection.execute("UPDATE sync_run_defaults SET applied = 1 WHERE video_id = ?", [.integer(video)])
            }
        }
        return result
    }

}
