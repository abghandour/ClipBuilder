import Foundation

extension Database {
    // MARK: - Projects

    /// Ensures every profile has one permanent Home project. Home has no
    /// membership rows: project-aware fetches treat it as the complete
    /// profile library, so newly discovered media appears there immediately.
    func ensureDefaultProject(profileName: String, legacyTimelineJSON: String?) throws {
        if try homeProjectID(profileName: profileName) != nil { return }
        try connection.transaction {
            if let existingID = try connection.query(
                "SELECT id FROM projects WHERE profile_name = ? ORDER BY id LIMIT 1",
                [.text(profileName)]
            ).first?["id"]?.intValue {
                try connection.execute(
                    "UPDATE projects SET name = 'Home', archived = 0, is_home = 1 WHERE id = ?",
                    [.integer(existingID)]
                )
                try connection.execute(
                    "DELETE FROM project_videos WHERE project_id = ?",
                    [.integer(existingID)]
                )
                return
            }
            try connection.execute(
                "INSERT INTO projects (profile_name, name, is_home) VALUES (?, 'Home', 1)",
                [.text(profileName)]
            )
            let projectID = connection.lastInsertRowID
            if let legacyTimelineJSON, !legacyTimelineJSON.isEmpty, legacyTimelineJSON != "{}" {
                try connection.execute("""
                    INSERT INTO timelines (project_id, name, kind, document_json)
                    VALUES (?, 'Timeline 1', 'builder', ?)
                    """, [.integer(projectID), .text(legacyTimelineJSON)])
            }
        }
    }

    func fetchProjects() throws -> [ProjectRecord] {
        let rows = try connection.query("""
            SELECT p.*,
                   CASE WHEN p.is_home = 1
                        THEN (SELECT COUNT(*) FROM videos)
                        ELSE (SELECT COUNT(*) FROM project_videos pv WHERE pv.project_id = p.id)
                   END AS source_count,
                   (SELECT COUNT(*) FROM timelines t WHERE t.project_id = p.id) AS timeline_count,
                   CASE WHEN p.is_home = 1
                        THEN (SELECT COUNT(*) FROM generated_videos g WHERE COALESCE(g.deleted, 0) = 0)
                        ELSE (SELECT COUNT(*) FROM generated_videos g
                              WHERE g.project_id = p.id AND COALESCE(g.deleted, 0) = 0)
                   END AS output_count
            FROM projects p
            ORDER BY p.is_home DESC, p.archived, p.last_opened_at DESC, p.name COLLATE NOCASE
            """)
        return try rows.map { row in
            let id = row["id"]?.intValue ?? 0
            let isHome = row["is_home"]?.boolValue ?? false
            let paths = try connection.query(
                isHome
                    ? """
                        SELECT v.path FROM videos v
                        ORDER BY CASE WHEN v.id = ? THEN 0 ELSE 1 END, v.id
                        LIMIT 3
                        """
                    : """
                        SELECT v.path FROM project_videos pv
                        JOIN videos v ON v.id = pv.video_id
                        WHERE pv.project_id = ?
                        ORDER BY CASE WHEN v.id = ? THEN 0 ELSE 1 END, v.id
                        LIMIT 3
                        """,
                isHome
                    ? [row["thumbnail_video_id"] ?? .null]
                    : [.integer(id), row["thumbnail_video_id"] ?? .null]
            )
                .compactMap { $0["path"]?.stringValue }
            return ProjectRecord(
                id: id,
                profileName: row["profile_name"]?.stringValue ?? "",
                name: row["name"]?.stringValue ?? "Untitled Project",
                createdAt: row["created_at"]?.stringValue,
                lastOpenedAt: row["last_opened_at"]?.stringValue,
                archived: row["archived"]?.boolValue ?? false,
                isHome: isHome,
                thumbnailVideoID: row["thumbnail_video_id"]?.intValue,
                uiStateJSON: row["ui_state_json"]?.stringValue,
                sourceCount: Int(row["source_count"]?.intValue ?? 0),
                timelineCount: Int(row["timeline_count"]?.intValue ?? 0),
                outputCount: Int(row["output_count"]?.intValue ?? 0),
                thumbnailPaths: paths
            )
        }
    }

    @discardableResult
    func createProject(profileName: String, name: String, videoIDs: [Int64] = []) throws -> Int64 {
        try connection.transaction {
            try connection.execute(
                "INSERT INTO projects (profile_name, name) VALUES (?, ?)",
                [.text(profileName), .text(name)]
            )
            let id = connection.lastInsertRowID
            for videoID in videoIDs {
                try connection.execute(
                    "INSERT OR IGNORE INTO project_videos (project_id, video_id) VALUES (?, ?)",
                    [.integer(id), .integer(videoID)]
                )
            }
            return id
        }
    }

    func renameProject(id: Int64, name: String) throws {
        try requireMutableProject(id)
        try connection.execute("UPDATE projects SET name = ? WHERE id = ?", [.text(name), .integer(id)])
    }

    func setProjectArchived(id: Int64, archived: Bool) throws {
        try requireMutableProject(id)
        try connection.execute(
            "UPDATE projects SET archived = ?, last_opened_at = datetime('now') WHERE id = ?",
            [.integer(archived ? 1 : 0), .integer(id)]
        )
    }

    func touchProject(id: Int64) throws {
        try connection.execute("UPDATE projects SET last_opened_at = datetime('now') WHERE id = ?", [.integer(id)])
    }

    func saveProjectUIState(id: Int64, json: String) throws {
        try connection.execute("UPDATE projects SET ui_state_json = ? WHERE id = ?", [.text(json), .integer(id)])
    }

    func deleteProject(id: Int64) throws {
        try requireMutableProject(id)
        try connection.execute("DELETE FROM projects WHERE id = ?", [.integer(id)])
    }

    @discardableResult
    func duplicateProject(id: Int64, profileName: String, name: String) throws -> Int64 {
        try requireMutableProject(id)
        return try connection.transaction {
            try connection.execute(
                "INSERT INTO projects (profile_name, name) VALUES (?, ?)",
                [.text(profileName), .text(name)]
            )
            let copyID = connection.lastInsertRowID
            try connection.execute("""
                INSERT INTO project_videos (project_id, video_id)
                SELECT ?, video_id FROM project_videos WHERE project_id = ?
                """, [.integer(copyID), .integer(id)])
            try connection.execute("""
                INSERT INTO timelines
                    (project_id, name, kind, document_json, created_at, edited_at,
                     source_run_id, thumbnail_video_id)
                SELECT ?, name, kind, document_json, datetime('now'), datetime('now'),
                       NULL, thumbnail_video_id
                FROM timelines WHERE project_id = ?
                """, [.integer(copyID), .integer(id)])
            return copyID
        }
    }

    func assignVideos(_ videoIDs: [Int64], to projectID: Int64) throws {
        guard try !isHomeProject(projectID) else { return }
        try connection.transaction {
            for videoID in videoIDs {
                try connection.execute(
                    "INSERT OR IGNORE INTO project_videos (project_id, video_id) VALUES (?, ?)",
                    [.integer(projectID), .integer(videoID)]
                )
            }
        }
    }

    func removeVideos(_ videoIDs: [Int64], from projectID: Int64) throws {
        try requireMutableProject(projectID)
        try connection.transaction {
            for videoID in videoIDs {
                try connection.execute(
                    "DELETE FROM project_videos WHERE project_id = ? AND video_id = ?",
                    [.integer(projectID), .integer(videoID)]
                )
            }
        }
    }

    /// Every profile video not already assigned to this project. This also
    /// includes files that have never belonged to any ordinary project.
    func fetchVideosNotInProject(_ projectID: Int64) throws -> [VideoRecord] {
        guard try !isHomeProject(projectID) else { return [] }
        return try connection.query("""
            SELECT v.* FROM videos v
            WHERE NOT EXISTS (
                  SELECT 1 FROM project_videos current
                  WHERE current.project_id = ? AND current.video_id = v.id
            )
            ORDER BY v.filename COLLATE NOCASE
            """, [.integer(projectID)]).map(Self.videoRecord)
    }

    func projectIDs(forVideo videoID: Int64) throws -> [Int64] {
        try connection.query(
            "SELECT project_id FROM project_videos WHERE video_id = ? ORDER BY project_id",
            [.integer(videoID)]
        ).compactMap { $0["project_id"]?.intValue }
    }

    func homeProjectID(profileName: String? = nil) throws -> Int64? {
        var sql = "SELECT id FROM projects WHERE is_home = 1"
        var parameters: [SQLValue] = []
        if let profileName {
            sql += " AND profile_name = ?"
            parameters.append(.text(profileName))
        }
        sql += " ORDER BY id LIMIT 1"
        return try connection.query(sql, parameters).first?["id"]?.intValue
    }

    func lastOpenedProjectID() throws -> Int64? {
        try connection.query("""
            SELECT id FROM projects
            WHERE archived = 0
            ORDER BY datetime(last_opened_at) DESC, id DESC
            LIMIT 1
            """).first?["id"]?.intValue
    }

    func moveTimelines(from sourceProjectID: Int64, to destinationProjectID: Int64) throws {
        try requireMutableProject(sourceProjectID)
        guard try isHomeProject(destinationProjectID) else {
            throw ProjectMutationError.destinationMustBeHome
        }
        try connection.execute(
            "UPDATE timelines SET project_id = ?, edited_at = datetime('now') WHERE project_id = ?",
            [.integer(destinationProjectID), .integer(sourceProjectID)]
        )
    }

    func isHomeProject(_ id: Int64) throws -> Bool {
        try connection.query(
            "SELECT is_home FROM projects WHERE id = ? LIMIT 1",
            [.integer(id)]
        ).first?["is_home"]?.boolValue ?? false
    }

    private func requireMutableProject(_ id: Int64) throws {
        if try isHomeProject(id) {
            throw ProjectMutationError.homeIsPermanent
        }
    }

    // MARK: - Project timelines

    func fetchTimelines(projectID: Int64) throws -> [TimelineRecord] {
        try connection.query("""
            SELECT t.*, v.path AS thumbnail_path FROM timelines t
            LEFT JOIN videos v ON v.id = t.thumbnail_video_id
            WHERE t.project_id = ?
            ORDER BY t.edited_at DESC, t.id DESC
            """, [.integer(projectID)]).map(Self.timelineRecord)
    }

    func fetchTimeline(id: Int64) throws -> TimelineRecord? {
        try connection.query("""
            SELECT t.*, v.path AS thumbnail_path FROM timelines t
            LEFT JOIN videos v ON v.id = t.thumbnail_video_id
            WHERE t.id = ?
            """, [.integer(id)]).first.map(Self.timelineRecord)
    }

    @discardableResult
    func createTimeline(projectID: Int64, name: String, kind: String = "builder",
                        documentJSON: String = "{}", sourceRunID: String? = nil,
                        thumbnailVideoID: Int64? = nil) throws -> Int64 {
        try connection.execute("""
            INSERT INTO timelines
                (project_id, name, kind, document_json, source_run_id, thumbnail_video_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [.integer(projectID), .text(name), .text(kind), .text(documentJSON),
                  sourceRunID.map(SQLValue.text) ?? .null,
                  thumbnailVideoID.map(SQLValue.integer) ?? .null])
        return connection.lastInsertRowID
    }

    /// The editor viewport for one timeline; independent of the document so
    /// scrubbing or zooming never counts as an edit.
    func saveTimelineViewState(id: Int64, json: String) throws {
        try connection.execute("UPDATE timelines SET view_state_json = ? WHERE id = ?",
                               [.text(json), .integer(id)])
    }

    func saveTimeline(id: Int64, name: String? = nil, documentJSON: String,
                      thumbnailVideoID: Int64? = nil) throws {
        if let name {
            try connection.execute("""
                UPDATE timelines SET name = ?, document_json = ?, thumbnail_video_id = ?,
                                     edited_at = datetime('now'), document_revision = document_revision + 1 WHERE id = ?
                """, [.text(name), .text(documentJSON),
                      thumbnailVideoID.map(SQLValue.integer) ?? .null, .integer(id)])
        } else {
            try connection.execute("""
                UPDATE timelines SET document_json = ?, thumbnail_video_id = ?,
                                     edited_at = datetime('now'), document_revision = document_revision + 1 WHERE id = ?
                """, [.text(documentJSON), thumbnailVideoID.map(SQLValue.integer) ?? .null,
                      .integer(id)])
        }
    }

    func recordBuilderRun(_ run: BuilderRunRecord) throws {
        try connection.transaction {
            try BuilderRunPersistence.record(run, on: connection)
            try BuilderRunPersistence.retainRuns(timelineID: run.timelineID, on: connection)
        }
    }

    func updateBuilderRunStatus(runUUID: String, status: BuilderRunStatus) throws {
        try connection.execute("UPDATE builder_runs SET status = ? WHERE run_uuid = ?",
                               [.text(status.rawValue), .text(runUUID)])
    }

    func fetchBuilderRuns(timelineID: Int64, limit: Int = 50) throws -> [BuilderRunRecord] {
        try connection.query("""
            SELECT * FROM builder_runs WHERE timeline_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?
            """, [.integer(timelineID), .integer(Int64(max(0, min(50, limit))))]).map(BuilderRunPersistence.run)
    }

    func saveWizardBefore(_ before: WizardBeforeRecord) throws {
        try BuilderRunPersistence.saveBefore(before, on: connection)
    }

    func fetchWizardBefore(timelineID: Int64) throws -> WizardBeforeRecord? {
        try connection.query("SELECT * FROM timeline_wizard_before WHERE timeline_id = ?",
                             [.integer(timelineID)]).first.map(BuilderRunPersistence.before)
    }

    func deleteWizardBefore(timelineID: Int64) throws {
        try connection.execute("DELETE FROM timeline_wizard_before WHERE timeline_id = ?", [.integer(timelineID)])
    }

    /// Ordinary autosave and snapshot undo/redo share the same actor write and status transaction.
    func saveTimelineRevision(id: Int64, documentJSON: String, revision: Int,
                              thumbnailVideoID: Int64?, runUUID: String?, status: BuilderRunStatus?) throws {
        // The synchronous Wizard connection can hold the writer lock too.
        try connection.execute("PRAGMA busy_timeout=5000")
        try connection.transaction {
            // An equal revision may belong to a winning Wizard commit, so a
            // queued autosave must advance it rather than overwrite it.
            try connection.execute("""
                UPDATE timelines SET document_json = ?, document_revision = ?, thumbnail_video_id = ?,
                    edited_at = datetime('now') WHERE id = ? AND document_revision < ?
                """, [.text(documentJSON), .integer(Int64(revision)),
                      thumbnailVideoID.map(SQLValue.integer) ?? .null, .integer(id), .integer(Int64(revision))])
            guard try connection.query("SELECT changes() AS count").first?["count"]?.intValue == 1 else {
                throw ApplyFailure.staleRevision
            }
            if let runUUID, let status { try updateBuilderRunStatus(runUUID: runUUID, status: status) }
        }
    }

    /// Called only after AppStore drains this timeline's serialized save queue.
    /// The private connection permits commit + live installation without an actor
    /// suspension. SQLite's immediate transaction and revision CAS arbitrate other writers.
    nonisolated func commitWizardSnapshot(timelineID: Int64, documentJSON: String,
                                          expectedRevision: Int, revision: Int, thumbnailVideoID: Int64?,
                                          run: BuilderRunRecord?, before: WizardBeforeRecord?,
                                          revertingRunUUID: String? = nil) throws {
        let db = try SQLiteConnection(path: path.path)
        try db.execute("PRAGMA busy_timeout=5000")
        try db.execute("PRAGMA foreign_keys=ON")
        // transaction() begins IMMEDIATE, acquiring the writer lock before CAS.
        try db.transaction {
            try db.execute("""
                UPDATE timelines SET document_json = ?, document_revision = ?, thumbnail_video_id = ?,
                    edited_at = datetime('now') WHERE id = ? AND document_revision = ?
                """, [.text(documentJSON), .integer(Int64(revision)),
                      thumbnailVideoID.map(SQLValue.integer) ?? .null,
                      .integer(timelineID), .integer(Int64(expectedRevision))])
            guard try db.query("SELECT changes() AS count").first?["count"]?.intValue == 1 else {
                throw ApplyFailure.staleRevision
            }
            if let run { try BuilderRunPersistence.record(run, on: db) }
            if let before { try BuilderRunPersistence.saveBefore(before, on: db) }
            if let revertingRunUUID {
                try db.execute("DELETE FROM timeline_wizard_before WHERE timeline_id = ? AND run_uuid = ?",
                               [.integer(timelineID), .text(revertingRunUUID)])
                guard try db.query("SELECT changes() AS count").first?["count"]?.intValue == 1 else {
                    throw ApplyFailure.missingBeforeVersion
                }
                try db.execute("UPDATE builder_runs SET status = 'reverted' WHERE run_uuid = ?",
                               [.text(revertingRunUUID)])
            }
            try BuilderRunPersistence.retainRuns(timelineID: timelineID, on: db)
        }
    }

    func renameTimeline(id: Int64, name: String) throws {
        try connection.execute(
            "UPDATE timelines SET name = ?, edited_at = datetime('now') WHERE id = ?",
            [.text(name), .integer(id)]
        )
    }

    @discardableResult
    func duplicateTimeline(id: Int64, name: String) throws -> Int64? {
        guard let row = try connection.query(
            "SELECT * FROM timelines WHERE id = ?", [.integer(id)]
        ).first else { return nil }
        return try createTimeline(
            projectID: row["project_id"]?.intValue ?? 0,
            name: name,
            kind: "builder",
            documentJSON: row["document_json"]?.stringValue ?? "{}",
            thumbnailVideoID: row["thumbnail_video_id"]?.intValue
        )
    }

    func deleteTimeline(id: Int64) throws {
        try connection.execute("DELETE FROM timelines WHERE id = ?", [.integer(id)])
    }

    func ensureWizardTimeline(projectID: Int64, name: String, documentJSON: String,
                              sourceRunID: String, thumbnailVideoID: Int64?) throws {
        if let id = try connection.query(
            "SELECT id FROM timelines WHERE project_id = ? AND kind = 'wizard' AND source_run_id = ? LIMIT 1",
            [.integer(projectID), .text(sourceRunID)]
        ).first?["id"]?.intValue {
            try saveTimeline(id: id, name: name, documentJSON: documentJSON,
                             thumbnailVideoID: thumbnailVideoID)
        } else {
            try createTimeline(projectID: projectID, name: name, kind: "wizard",
                               documentJSON: documentJSON, sourceRunID: sourceRunID,
                               thumbnailVideoID: thumbnailVideoID)
        }
    }

    private static func timelineRecord(_ row: SQLRow) -> TimelineRecord {
        TimelineRecord(
            id: row["id"]?.intValue ?? 0,
            projectID: row["project_id"]?.intValue ?? 0,
            name: row["name"]?.stringValue ?? "Untitled Timeline",
            kind: row["kind"]?.stringValue ?? "builder",
            documentJSON: row["document_json"]?.stringValue ?? "{}",
            createdAt: row["created_at"]?.stringValue,
            editedAt: row["edited_at"]?.stringValue,
            sourceRunID: row["source_run_id"]?.stringValue,
            thumbnailVideoID: row["thumbnail_video_id"]?.intValue,
            thumbnailPath: row["thumbnail_path"]?.stringValue,
            viewStateJSON: row["view_state_json"]?.stringValue,
            documentRevision: Int(row["document_revision"]?.intValue ?? 0)
        )
    }

    /// Pre-batch databases keep scenes directly on videos with a
    /// UNIQUE(video_id, start_time, end_time) constraint. Rebuild the table
    /// with a run_id (dropping that constraint so the same range can exist in
    /// several batches) and backfill one synthetic batch per analyzed video so
    /// legacy scenes get full batch features. Scene ids are preserved, so
    /// scene_tags, grades, and clip_reviews rows stay valid.
    static func migrateScenesToAnalysisRuns(_ connection: SQLiteConnection) throws {
        guard try !connection.columnNames(of: "scenes").contains("run_id") else { return }
        // The rebuild drops/renames a table other tables reference — FK
        // checks must be off, and SQLite only allows toggling them outside a
        // transaction.
        try connection.execute("PRAGMA foreign_keys=OFF")
        defer { try? connection.execute("PRAGMA foreign_keys=ON") }
        try connection.transaction {
            try connection.execute("""
                INSERT INTO analysis_runs (video_id, name, instructions, provider, model, created_at)
                SELECT v.id,
                       v.filename || ' — as of ' ||
                           strftime('%Y-%m-%d %H:%M',
                                    COALESCE(v.visual_analyzed_at, v.analyzed_at, 'now'),
                                    'localtime'),
                       '',
                       v.visual_analyzer_provider,
                       v.visual_analyzer_model,
                       COALESCE(v.visual_analyzed_at, v.analyzed_at, datetime('now'))
                FROM videos v WHERE EXISTS (SELECT 1 FROM scenes s WHERE s.video_id = v.id)
                """)
            try connection.execute("""
                CREATE TABLE scenes_new (
                    id INTEGER PRIMARY KEY,
                    video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                    run_id INTEGER REFERENCES analysis_runs(id) ON DELETE CASCADE,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    excluded BOOLEAN DEFAULT 0,
                    ignored BOOLEAN DEFAULT 0,
                    favorite INTEGER DEFAULT 0,
                    crop_x_frac REAL,
                    free_crops TEXT,
                    center_stage_path TEXT,
                    UNIQUE(video_id, run_id, start_time, end_time)
                )
                """)
            try connection.execute("""
                INSERT INTO scenes_new (id, video_id, run_id, start_time, end_time,
                                        excluded, ignored, favorite, crop_x_frac, free_crops,
                                        center_stage_path)
                SELECT s.id, s.video_id, r.id, s.start_time, s.end_time,
                       s.excluded, s.ignored, s.favorite, s.crop_x_frac, s.free_crops,
                       s.center_stage_path
                FROM scenes s
                LEFT JOIN analysis_runs r ON r.video_id = s.video_id
                """)
            try connection.execute("DROP TABLE scenes")
            try connection.execute("ALTER TABLE scenes_new RENAME TO scenes")
        }
    }
}
