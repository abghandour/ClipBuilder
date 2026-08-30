import Foundation

/// One `Database` per brand profile, mirroring db.py: same file layout
/// (`<data>/profiles_db/<Profile>.db`), same schema, same lazy column
/// migrations — so databases created by the Python app open unchanged.
actor Database {
    private let connection: SQLiteConnection
    let path: URL

    private static let schema = """
    CREATE TABLE IF NOT EXISTS videos (
        id INTEGER PRIMARY KEY,
        hash TEXT UNIQUE NOT NULL,
        filename TEXT NOT NULL,
        path TEXT NOT NULL,
        duration REAL DEFAULT 0,
        width INTEGER DEFAULT 0,
        height INTEGER DEFAULT 0,
        wide BOOLEAN DEFAULT 0,
        discovered_at TEXT DEFAULT (datetime('now')),
        analyzed_at TEXT
    );

    CREATE TABLE IF NOT EXISTS analysis_runs (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        instructions TEXT NOT NULL DEFAULT '',
        provider TEXT,
        model TEXT,
        has_transcript INTEGER DEFAULT 0,
        sample_interval REAL DEFAULT 0,
        notes_json TEXT,
        created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_analysis_runs_video ON analysis_runs(video_id);

    CREATE TABLE IF NOT EXISTS scenes (
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
        curated INTEGER DEFAULT 0,
        edit_start REAL,
        edit_end REAL,
        narrative TEXT,
        score REAL,
        excitement REAL,
        parent_scene_id INTEGER REFERENCES scenes(id) ON DELETE SET NULL,
        UNIQUE(video_id, run_id, start_time, end_time)
    );

    CREATE TABLE IF NOT EXISTS scene_tags (
        scene_id INTEGER NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
        tag TEXT NOT NULL,
        PRIMARY KEY (scene_id, tag)
    );

    CREATE TABLE IF NOT EXISTS moments (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        at_time REAL NOT NULL,
        note TEXT,
        dialog TEXT
    );

    CREATE TABLE IF NOT EXISTS video_notes (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        at_time REAL NOT NULL,
        note TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_video_notes_video ON video_notes(video_id);

    CREATE TABLE IF NOT EXISTS fight_outcomes (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        run_id INTEGER NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        method TEXT NOT NULL,
        winner_key TEXT,
        loser_key TEXT,
        event TEXT,
        round INTEGER,
        created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_fight_outcomes_video ON fight_outcomes(video_id);

    CREATE TABLE IF NOT EXISTS person_markers (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        at_time REAL NOT NULL,
        x REAL NOT NULL,
        y REAL NOT NULL,
        width REAL NOT NULL,
        height REAL NOT NULL,
        person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
        ignored INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_person_markers_video ON person_markers(video_id);

    CREATE TABLE IF NOT EXISTS video_people (
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
        portrait_at REAL NOT NULL DEFAULT 0,
        portrait_json TEXT,
        ranges_json TEXT,
        detected_at TEXT DEFAULT (datetime('now')),
        PRIMARY KEY (video_id, person_id)
    );

    CREATE TABLE IF NOT EXISTS taste_studies (
        media_id INTEGER PRIMARY KEY,
        category_key TEXT,
        studied_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS center_stage_hints (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        at_time REAL NOT NULL,
        x REAL NOT NULL,
        y REAL NOT NULL,
        width REAL NOT NULL,
        height REAL NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_center_stage_hints_video ON center_stage_hints(video_id);

    CREATE TABLE IF NOT EXISTS video_subjects (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        color_index INTEGER NOT NULL DEFAULT 0,
        rects_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_video_subjects_video ON video_subjects(video_id);

    CREATE TABLE IF NOT EXISTS people (
        id INTEGER PRIMARY KEY,
        key TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        descriptor TEXT NOT NULL DEFAULT '',
        created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS analyzed_tags (
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        tag TEXT NOT NULL,
        analyzed_at TEXT DEFAULT (datetime('now')),
        PRIMARY KEY (video_id, tag)
    );

    CREATE TABLE IF NOT EXISTS grades (
        id INTEGER PRIMARY KEY,
        scene_id INTEGER NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
        score INTEGER NOT NULL,
        graded_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS generated_videos (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL,
        duration REAL DEFAULT 0,
        timeline_json TEXT NOT NULL,
        caption TEXT DEFAULT '',
        generated_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS wizard_research (
        id INTEGER PRIMARY KEY,
        topic TEXT NOT NULL,
        result_json TEXT NOT NULL,
        researched_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS fight_research (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL UNIQUE REFERENCES videos(id) ON DELETE CASCADE,
        fight_label TEXT NOT NULL DEFAULT '',
        event TEXT NOT NULL DEFAULT '',
        fight_date TEXT NOT NULL DEFAULT '',
        summary_json TEXT NOT NULL DEFAULT '{}',
        sources_json TEXT NOT NULL DEFAULT '[]',
        provider TEXT,
        model TEXT,
        researched_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS fight_events (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        at_time REAL NOT NULL,
        fighter_key TEXT NOT NULL DEFAULT '',
        action TEXT NOT NULL,
        points REAL NOT NULL DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS wizard_feedback (
        id INTEGER PRIMARY KEY,
        generated_video_id INTEGER NOT NULL REFERENCES generated_videos(id) ON DELETE CASCADE,
        feedback TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS text_overlay_presets (
        id INTEGER PRIMARY KEY,
        name TEXT,
        data_json TEXT NOT NULL,
        thumbnail BLOB,
        created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS transcripts (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        language TEXT NOT NULL DEFAULT '',
        is_translation BOOLEAN DEFAULT 0,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        text TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_transcripts_video_time
        ON transcripts(video_id, start_time, end_time);
    CREATE INDEX IF NOT EXISTS idx_transcripts_text
        ON transcripts(video_id, language);

    CREATE TABLE IF NOT EXISTS imported_externals (
        platform     TEXT NOT NULL,
        external_id  TEXT NOT NULL,
        title        TEXT,
        page_url     TEXT,
        local_path   TEXT,
        video_id     INTEGER REFERENCES videos(id) ON DELETE SET NULL,
        imported_at  TEXT DEFAULT (datetime('now')),
        PRIMARY KEY (platform, external_id)
    );

    CREATE INDEX IF NOT EXISTS idx_grades_scene ON grades(scene_id);
    CREATE INDEX IF NOT EXISTS idx_moments_video ON moments(video_id);
    CREATE INDEX IF NOT EXISTS idx_wizard_feedback_video ON wizard_feedback(generated_video_id);
    CREATE INDEX IF NOT EXISTS idx_wizard_research_topic ON wizard_research(topic, researched_at);

    CREATE TABLE IF NOT EXISTS ig_accounts (
        id INTEGER PRIMARY KEY,
        username TEXT UNIQUE NOT NULL COLLATE NOCASE,
        kind TEXT NOT NULL DEFAULT 'public',
        display_name TEXT,
        ig_user_id TEXT,
        followers INTEGER,
        profile_pic_path TEXT,
        last_fetched_at TEXT,
        added_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS ig_media (
        id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        media_id TEXT NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'reel',
        caption TEXT DEFAULT '',
        permalink TEXT,
        posted_at TEXT,
        duration REAL DEFAULT 0,
        thumbnail_path TEXT,
        local_video_path TEXT,
        stats_json TEXT DEFAULT '{}',
        source TEXT NOT NULL DEFAULT 'ytdlp',
        fetched_at TEXT DEFAULT (datetime('now')),
        UNIQUE(account_id, media_id)
    );
    CREATE INDEX IF NOT EXISTS idx_ig_media_account ON ig_media(account_id, posted_at);

    CREATE TABLE IF NOT EXISTS generation_reviews (
        id INTEGER PRIMARY KEY,
        generated_video_id INTEGER NOT NULL UNIQUE REFERENCES generated_videos(id) ON DELETE CASCADE,
        verdict INTEGER NOT NULL DEFAULT 0,
        dimensions_json TEXT NOT NULL DEFAULT '{}',
        note TEXT NOT NULL DEFAULT '',
        created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS clip_reviews (
        id INTEGER PRIMARY KEY,
        generated_video_id INTEGER NOT NULL REFERENCES generated_videos(id) ON DELETE CASCADE,
        clip_index INTEGER NOT NULL,
        scene_id INTEGER,
        verdict INTEGER NOT NULL,
        reasons_json TEXT NOT NULL DEFAULT '[]',
        UNIQUE(generated_video_id, clip_index)
    );

    CREATE TABLE IF NOT EXISTS wizard_preferences (
        id INTEGER PRIMARY KEY,
        chosen_video_id INTEGER REFERENCES generated_videos(id) ON DELETE SET NULL,
        rejected_video_id INTEGER REFERENCES generated_videos(id) ON DELETE SET NULL,
        chosen_rationale TEXT NOT NULL DEFAULT '',
        rejected_rationale TEXT NOT NULL DEFAULT '',
        created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS wizard_lessons (
        id INTEGER PRIMARY KEY,
        text TEXT NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        evidence TEXT NOT NULL DEFAULT '',
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS ig_templates (
        id INTEGER PRIMARY KEY,
        media_id INTEGER NOT NULL UNIQUE REFERENCES ig_media(id) ON DELETE CASCADE,
        template_json TEXT NOT NULL,
        provider TEXT,
        model TEXT,
        analyzed_at TEXT DEFAULT (datetime('now'))
    );

    -- Instagram reports: history and account-level data behind the Reports
    -- tab. Every table carries `source` ('graph' = live refresh, 'import' =
    -- backfilled from the peace-grappler report artifacts); live rows always
    -- win over imported rows on the same natural key.
    CREATE TABLE IF NOT EXISTS ig_account_snapshots (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        snapshot_date TEXT NOT NULL,
        followers_count INTEGER,
        follows_count INTEGER,
        media_count INTEGER,
        source TEXT NOT NULL DEFAULT 'graph',
        PRIMARY KEY (account_id, snapshot_date)
    );

    CREATE TABLE IF NOT EXISTS ig_report_media (
        id INTEGER PRIMARY KEY,
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        media_id TEXT,
        shortcode TEXT NOT NULL,
        media_type TEXT,
        media_product_type TEXT,
        caption TEXT DEFAULT '',
        caption_truncated INTEGER NOT NULL DEFAULT 0,
        permalink TEXT,
        posted_at TEXT,
        like_count INTEGER,
        comments_count INTEGER,
        thumbnail_url TEXT,
        thumbnail_path TEXT,
        source TEXT NOT NULL DEFAULT 'graph',
        fetched_at TEXT,
        UNIQUE(account_id, shortcode)
    );
    CREATE INDEX IF NOT EXISTS idx_ig_report_media_posted ON ig_report_media(account_id, posted_at);

    CREATE TABLE IF NOT EXISTS ig_media_insight_snapshots (
        id INTEGER PRIMARY KEY,
        report_media_id INTEGER NOT NULL REFERENCES ig_report_media(id) ON DELETE CASCADE,
        metric TEXT NOT NULL,
        value REAL NOT NULL,
        fetched_at TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'graph',
        UNIQUE(report_media_id, metric, fetched_at)
    );

    CREATE TABLE IF NOT EXISTS ig_account_insights (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        metric TEXT NOT NULL,
        period TEXT NOT NULL,
        breakdown_dimension TEXT NOT NULL DEFAULT '',
        breakdown_value TEXT NOT NULL DEFAULT '',
        value REAL NOT NULL,
        end_time TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'graph',
        PRIMARY KEY (account_id, metric, period, breakdown_dimension, breakdown_value, end_time)
    );

    CREATE TABLE IF NOT EXISTS ig_audience_demographics (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        metric TEXT NOT NULL,
        dimension TEXT NOT NULL,
        dimension_value TEXT NOT NULL,
        timeframe TEXT NOT NULL,
        value INTEGER NOT NULL,
        fetched_date TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'graph',
        PRIMARY KEY (account_id, metric, dimension, dimension_value, timeframe, fetched_date)
    );

    CREATE TABLE IF NOT EXISTS ig_comments (
        id TEXT PRIMARY KEY,
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        report_media_id INTEGER NOT NULL REFERENCES ig_report_media(id) ON DELETE CASCADE,
        parent_comment_id TEXT,
        username TEXT,
        from_id TEXT,
        text TEXT,
        like_count INTEGER DEFAULT 0,
        hidden INTEGER DEFAULT 0,
        timestamp TEXT NOT NULL,
        ref_timestamp TEXT,
        fetched_at TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_ig_comments_account_ts ON ig_comments(account_id, timestamp);

    CREATE TABLE IF NOT EXISTS ig_commenter_rankings_import (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        period_key TEXT NOT NULL,
        as_of TEXT NOT NULL,
        username TEXT NOT NULL COLLATE NOCASE,
        rank INTEGER,
        score INTEGER,
        early INTEGER,
        text_comments INTEGER,
        emoji_comments INTEGER,
        text_replies INTEGER,
        emoji_replies INTEGER,
        total INTEGER,
        PRIMARY KEY (account_id, period_key, username)
    );

    CREATE TABLE IF NOT EXISTS ig_commenter_activity_import (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        period_key TEXT NOT NULL,
        as_of TEXT NOT NULL,
        username TEXT NOT NULL COLLATE NOCASE,
        comments INTEGER,
        replies INTEGER,
        total INTEGER,
        top_posts_json TEXT,
        PRIMARY KEY (account_id, period_key, username)
    );

    CREATE TABLE IF NOT EXISTS ig_comment_heatmap_import (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        window_end TEXT NOT NULL,
        dow INTEGER NOT NULL,
        hour INTEGER NOT NULL,
        count INTEGER NOT NULL,
        PRIMARY KEY (account_id, window_end, dow, hour)
    );

    CREATE TABLE IF NOT EXISTS ig_reel_analysis_import (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        report_media_id INTEGER NOT NULL REFERENCES ig_report_media(id) ON DELETE CASCADE,
        analysis_date TEXT NOT NULL,
        score INTEGER,
        tier TEXT,
        good_json TEXT,
        bad_json TEXT,
        top_tip TEXT,
        PRIMARY KEY (account_id, report_media_id, analysis_date)
    );

    CREATE TABLE IF NOT EXISTS ig_ignored_accounts (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        username TEXT NOT NULL COLLATE NOCASE,
        reason TEXT,
        PRIMARY KEY (account_id, username)
    );

    CREATE TABLE IF NOT EXISTS ig_report_sync_state (
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        PRIMARY KEY (account_id, key)
    );
    """

    init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: path.path)
        do {
            try connection.execute("PRAGMA journal_mode=WAL")
        } catch {
            // WAL needs mmap + shared-memory sidecar files, which some
            // filesystems (cloud-synced or network folders) can't provide.
            // The rollback journal is slower but works everywhere.
            try connection.execute("PRAGMA journal_mode=DELETE")
        }
        try connection.execute("PRAGMA foreign_keys=ON")
        try connection.executeScript(Self.schema)
        try Self.migrate(connection)
    }

    /// Lazy column migrations mirroring db.py, so old and new columns end up
    /// identical across both apps. One `PRAGMA table_info` per table replaces
    /// the per-column probe statements.
    private static func migrate(_ connection: SQLiteConnection) throws {
        let textColumns: [(table: String, columns: [String])] = [
            ("generated_videos", ["caption", "drive_file_id", "drive_link",
                                  "caption_provider", "wizard_provider",
                                  "caption_model", "wizard_model",
                                  "rationale", "batch_id", "plan_clips_json",
                                  "cover_provider", "cover_model"]),
            ("videos", ["drive_file_id", "drive_link",
                        "analyzer_provider", "visual_analyzer_provider",
                        "speech_analyzer_provider", "analyzer_model",
                        "visual_analyzer_model", "speech_analyzer_model",
                        "visual_analyzed_at", "speech_analyzed_at",
                        "video_type",
                        "naming_provider", "naming_model",
                        "people_provider", "people_model"]),
            ("wizard_research", ["provider", "model"]),
            ("transcripts", ["provider", "model", "original_text", "words"]),
            // AI provenance: which provider/model produced each artifact.
            // NULL = human-made (or predates provenance tracking).
            ("scenes", ["curated_provider", "curated_model"]),
            ("fight_events", ["provider", "model"]),
            ("video_notes", ["provider", "model"]),
            ("wizard_lessons", ["provider", "model"]),
        ]
        for (table, columns) in textColumns {
            let existing = try connection.columnNames(of: table)
            for column in columns where !existing.contains(column) {
                try connection.execute("ALTER TABLE \(table) ADD COLUMN \(column) TEXT")
            }
        }
        let sceneColumns = try connection.columnNames(of: "scenes")
        if !sceneColumns.contains("favorite") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN favorite INTEGER DEFAULT 0")
        }
        if !sceneColumns.contains("crop_x_frac") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN crop_x_frac REAL")
        }
        if !sceneColumns.contains("free_crops") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN free_crops TEXT")
        }
        if !sceneColumns.contains("center_stage_path") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN center_stage_path TEXT")
        }
        if !sceneColumns.contains("curated") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN curated INTEGER DEFAULT 0")
        }
        if !sceneColumns.contains("edit_start") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN edit_start REAL")
        }
        if !sceneColumns.contains("edit_end") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN edit_end REAL")
        }
        if !sceneColumns.contains("narrative") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN narrative TEXT")
        }
        if !sceneColumns.contains("score") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN score REAL")
        }
        if !sceneColumns.contains("excitement") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN excitement REAL")
        }
        if !sceneColumns.contains("parent_scene_id") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN parent_scene_id INTEGER REFERENCES scenes(id) ON DELETE SET NULL")
        }
        if !sceneColumns.contains("stack_choice") {
            try connection.execute("ALTER TABLE scenes ADD COLUMN stack_choice INTEGER DEFAULT 0")
        }
        if try !connection.columnNames(of: "person_markers").contains("ignored") {
            try connection.execute("ALTER TABLE person_markers ADD COLUMN ignored INTEGER DEFAULT 0")
        }
        // People screen's Hidden bucket — display-only, identity untouched.
        let peopleColumns = try connection.columnNames(of: "people")
        if !peopleColumns.contains("hidden") {
            try connection.execute("ALTER TABLE people ADD COLUMN hidden INTEGER DEFAULT 0")
        }
        // Hand-picked avatar: frame (video + time) and normalized face box.
        // NULL = automatic (marker portrait, else the first scene's face).
        if !peopleColumns.contains("avatar_video_id") {
            try connection.execute("ALTER TABLE people ADD COLUMN avatar_video_id INTEGER")
            try connection.execute("ALTER TABLE people ADD COLUMN avatar_time REAL")
            try connection.execute("ALTER TABLE people ADD COLUMN avatar_box TEXT")
        }
        if try !connection.columnNames(of: "videos").contains("people_detected_at") {
            try connection.execute("ALTER TABLE videos ADD COLUMN people_detected_at TEXT")
        }
        if try !connection.columnNames(of: "fight_outcomes").contains("round") {
            try connection.execute("ALTER TABLE fight_outcomes ADD COLUMN round INTEGER")
        }
        let generatedColumns = try connection.columnNames(of: "generated_videos")
        if !generatedColumns.contains("deleted") {
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN deleted INTEGER DEFAULT 0")
        }
        if !generatedColumns.contains("critique_json") {
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN critique_json TEXT")
        }
        if !generatedColumns.contains("quality_json") {
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN quality_json TEXT")
        }
        if !generatedColumns.contains("instagram_media_id") {
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN instagram_media_id TEXT")
        }
        // Cover-frame pick (AI-proposed or user-chosen) — the Library card's
        // thumbnail time; NULL falls back to the old near-start frame.
        if !generatedColumns.contains("cover_time") {
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN cover_time REAL")
        }
        // Audience outcome of a published reel (critic calibration).
        if !generatedColumns.contains("audience_score") {
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN audience_score REAL")
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN audience_percentile INTEGER")
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN audience_measured_at TEXT")
        }
        try migrateScenesToAnalysisRuns(connection)
        // Databases migrated before batches learned about transcription:
        // credit each transcribed video's transcript to its newest batch.
        if try !connection.columnNames(of: "analysis_runs").contains("has_transcript") {
            try connection.execute("ALTER TABLE analysis_runs ADD COLUMN has_transcript INTEGER DEFAULT 0")
            try connection.execute("""
                UPDATE analysis_runs SET has_transcript = 1 WHERE id IN (
                    SELECT MAX(r.id) FROM analysis_runs r
                    JOIN transcripts t ON t.video_id = r.video_id
                    GROUP BY r.video_id
                )
                """)
        }
        if try !connection.columnNames(of: "analysis_runs").contains("sample_interval") {
            try connection.execute("ALTER TABLE analysis_runs ADD COLUMN sample_interval REAL DEFAULT 0")
        }
        if try !connection.columnNames(of: "analysis_runs").contains("notes_json") {
            try connection.execute("ALTER TABLE analysis_runs ADD COLUMN notes_json TEXT")
        }
    }

    /// Pre-batch databases keep scenes directly on videos with a
    /// UNIQUE(video_id, start_time, end_time) constraint. Rebuild the table
    /// with a run_id (dropping that constraint so the same range can exist in
    /// several batches) and backfill one synthetic batch per analyzed video so
    /// legacy scenes get full batch features. Scene ids are preserved, so
    /// scene_tags, grades, and clip_reviews rows stay valid.
    private static func migrateScenesToAnalysisRuns(_ connection: SQLiteConnection) throws {
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

    // MARK: - Videos

    @discardableResult
    func registerVideo(hash: String, filename: String, path: String, duration: Double,
                       width: Int, height: Int, wide: Bool) throws -> Int64 {
        let rows = try connection.query("""
            INSERT INTO videos (hash, filename, path, duration, width, height, wide)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET
                filename=excluded.filename,
                path=excluded.path,
                duration=excluded.duration,
                width=excluded.width,
                height=excluded.height,
                wide=excluded.wide
            RETURNING id
            """, [.text(hash), .text(filename), .text(path), .real(duration),
                  .integer(Int64(width)), .integer(Int64(height)), .integer(wide ? 1 : 0)])
        return rows.first?["id"]?.intValue ?? connection.lastInsertRowID
    }

    // MARK: - Video notes (timestamped analysis guidance)

    func videoNotes(videoID: Int64) throws -> [VideoNote] {
        try connection.query("SELECT * FROM video_notes WHERE video_id = ? ORDER BY at_time",
                             [.integer(videoID)]).map { row in
            VideoNote(id: row["id"]?.intValue ?? 0,
                      videoID: videoID,
                      atTime: row["at_time"]?.doubleValue ?? 0,
                      note: row["note"]?.stringValue ?? "",
                      provider: row["provider"]?.stringValue,
                      model: row["model"]?.stringValue)
        }
    }

    /// `provenance` marks an AI-written note (a saved soundbite); nil = the
    /// user typed it.
    func addVideoNote(videoID: Int64, at atTime: Double, note: String,
                      provenance: AIProvenance? = nil) throws {
        try connection.execute("""
            INSERT INTO video_notes (video_id, at_time, note, provider, model) VALUES (?, ?, ?, ?, ?)
            """, [.integer(videoID), .real(atTime), .text(note),
                  provenance.map { SQLValue.text($0.provider) } ?? .null,
                  provenance?.model.map(SQLValue.text) ?? .null])
    }

    func deleteVideoNote(id: Int64) throws {
        try connection.execute("DELETE FROM video_notes WHERE id = ?", [.integer(id)])
    }

    // MARK: - Fight outcomes

    func saveFightOutcome(videoID: Int64, runID: Int64, method: String,
                          winnerKey: String?, loserKey: String?, event: String?,
                          round: Int?) throws {
        try connection.execute("""
            INSERT INTO fight_outcomes (video_id, run_id, method, winner_key, loser_key, event, round)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.integer(videoID), .integer(runID), .text(method),
                  winnerKey.map(SQLValue.text) ?? .null,
                  loserKey.map(SQLValue.text) ?? .null,
                  event.map(SQLValue.text) ?? .null,
                  round.map { SQLValue.integer(Int64($0)) } ?? .null])
    }

    /// Latest outcome per video (newer runs win), optionally scoped to runs.
    func fetchOutcomes(runIDs: Set<Int64> = []) throws -> [FightOutcome] {
        let rows = try connection.query(
            "SELECT * FROM fight_outcomes ORDER BY video_id, id DESC")
        var seenVideos = Set<Int64>()
        var outcomes: [FightOutcome] = []
        for row in rows {
            let runID = row["run_id"]?.intValue ?? 0
            if !runIDs.isEmpty && !runIDs.contains(runID) { continue }
            let videoID = row["video_id"]?.intValue ?? 0
            guard seenVideos.insert(videoID).inserted else { continue }
            outcomes.append(FightOutcome(id: row["id"]?.intValue ?? 0,
                                         videoID: videoID,
                                         runID: runID,
                                         method: row["method"]?.stringValue ?? "",
                                         winnerKey: row["winner_key"]?.stringValue,
                                         loserKey: row["loser_key"]?.stringValue,
                                         event: row["event"]?.stringValue,
                                         round: row["round"]?.intValue.map(Int.init)))
        }
        return outcomes
    }

    // MARK: - Person markers (user-drawn identity boxes)

    func personMarkers(videoID: Int64) throws -> [PersonMarker] {
        try connection.query("SELECT * FROM person_markers WHERE video_id = ? ORDER BY at_time, id",
                             [.integer(videoID)]).map { row in
            PersonMarker(id: row["id"]?.intValue ?? 0,
                         videoID: videoID,
                         atTime: row["at_time"]?.doubleValue ?? 0,
                         x: row["x"]?.doubleValue ?? 0,
                         y: row["y"]?.doubleValue ?? 0,
                         width: row["width"]?.doubleValue ?? 0,
                         height: row["height"]?.doubleValue ?? 0,
                         personID: row["person_id"]?.intValue,
                         ignored: row["ignored"]?.boolValue ?? false)
        }
    }

    func addPersonMarker(videoID: Int64, at atTime: Double,
                         x: Double, y: Double, width: Double, height: Double) throws {
        try connection.execute("""
            INSERT INTO person_markers (video_id, at_time, x, y, width, height)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [.integer(videoID), .real(atTime), .real(x), .real(y), .real(width), .real(height)])
    }

    func updatePersonMarker(_ marker: PersonMarker) throws {
        try connection.execute("""
            UPDATE person_markers SET at_time = ?, x = ?, y = ?, width = ?, height = ?, person_id = ?,
                ignored = ?
            WHERE id = ?
            """, [.real(marker.atTime), .real(marker.x), .real(marker.y),
                  .real(marker.width), .real(marker.height),
                  marker.personID.map(SQLValue.integer) ?? .null,
                  .integer(marker.ignored ? 1 : 0), .integer(marker.id)])
    }

    func deletePersonMarker(id: Int64) throws {
        try connection.execute("DELETE FROM person_markers WHERE id = ?", [.integer(id)])
    }

    // MARK: - Video people (people-only pass roster)

    func fetchVideoPeople(videoID: Int64) throws -> [VideoPersonRecord] {
        try connection.query("""
            SELECT vp.*, p.key AS person_key, p.name AS person_name,
                   p.descriptor AS person_descriptor
            FROM video_people vp JOIN people p ON p.id = vp.person_id
            WHERE vp.video_id = ? ORDER BY vp.portrait_at, p.key
            """, [.integer(videoID)]).map { row in
            let box = row["portrait_json"]?.stringValue
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(VideoPersonRecord.PortraitBox.self, from: $0) }
            return VideoPersonRecord(videoID: videoID,
                                     personID: row["person_id"]?.intValue ?? 0,
                                     key: row["person_key"]?.stringValue ?? "",
                                     name: row["person_name"]?.stringValue ?? "",
                                     descriptor: row["person_descriptor"]?.stringValue ?? "",
                                     portraitAt: row["portrait_at"]?.doubleValue ?? 0,
                                     portraitBox: box)
        }
    }

    /// Replace the video's roster with a fresh people-pass result and stamp
    /// the video as people-detected (the tag-detection gate), recording
    /// which model did the detecting.
    func replaceVideoPeople(videoID: Int64,
                            entries: [(personID: Int64, portraitAt: Double,
                                       portraitJSON: String?, rangesJSON: String?)],
                            provenance: AIProvenance? = nil) throws {
        try connection.transaction {
            try connection.execute("""
                UPDATE videos SET people_detected_at = datetime('now'),
                    people_provider = COALESCE(?, people_provider),
                    people_model = COALESCE(?, people_model)
                WHERE id = ?
                """, [provenance.map { SQLValue.text($0.provider) } ?? .null,
                      provenance?.model.map(SQLValue.text) ?? .null,
                      .integer(videoID)])
            try connection.execute("DELETE FROM video_people WHERE video_id = ?",
                                   [.integer(videoID)])
            for entry in entries {
                try connection.execute("""
                    INSERT OR REPLACE INTO video_people
                        (video_id, person_id, portrait_at, portrait_json, ranges_json)
                    VALUES (?, ?, ?, ?, ?)
                    """, [.integer(videoID), .integer(entry.personID), .real(entry.portraitAt),
                          entry.portraitJSON.map(SQLValue.text) ?? .null,
                          entry.rangesJSON.map(SQLValue.text) ?? .null])
            }
        }
    }

    // MARK: - Taste studies (which reels taught the taste profile)

    /// media id → category key of the study that learned from it.
    func tasteStudies() throws -> [Int64: String] {
        var result: [Int64: String] = [:]
        for row in try connection.query("SELECT media_id, category_key FROM taste_studies") {
            if let id = row["media_id"]?.intValue {
                result[id] = row["category_key"]?.stringValue ?? "general"
            }
        }
        return result
    }

    func recordTasteStudy(mediaID: Int64, categoryKey: String) throws {
        try connection.execute("""
            INSERT OR REPLACE INTO taste_studies (media_id, category_key) VALUES (?, ?)
            """, [.integer(mediaID), .text(categoryKey)])
    }

    // MARK: - Center Stage hints (user-framed camera keyframes)

    func centerStageHints(videoID: Int64) throws -> [CameraHint] {
        try connection.query("SELECT * FROM center_stage_hints WHERE video_id = ? ORDER BY at_time, id",
                             [.integer(videoID)]).map { row in
            CameraHint(id: row["id"]?.intValue ?? 0,
                       videoID: videoID,
                       atTime: row["at_time"]?.doubleValue ?? 0,
                       x: row["x"]?.doubleValue ?? 0,
                       y: row["y"]?.doubleValue ?? 0,
                       width: row["width"]?.doubleValue ?? 0,
                       height: row["height"]?.doubleValue ?? 0)
        }
    }

    func addCenterStageHint(videoID: Int64, at atTime: Double,
                            x: Double, y: Double, width: Double, height: Double) throws {
        try connection.execute("""
            INSERT INTO center_stage_hints (video_id, at_time, x, y, width, height)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [.integer(videoID), .real(atTime), .real(x), .real(y), .real(width), .real(height)])
    }

    func updateCenterStageHint(_ hint: CameraHint) throws {
        try connection.execute("""
            UPDATE center_stage_hints SET at_time = ?, x = ?, y = ?, width = ?, height = ?
            WHERE id = ?
            """, [.real(hint.atTime), .real(hint.x), .real(hint.y),
                  .real(hint.width), .real(hint.height), .integer(hint.id)])
    }

    func deleteCenterStageHint(id: Int64) throws {
        try connection.execute("DELETE FROM center_stage_hints WHERE id = ?", [.integer(id)])
    }

    /// Scene ids + ranges of one analyze batch — the portrait-fit pass input.
    func sceneRanges(runID: Int64) throws -> [(id: Int64, start: Double, end: Double)] {
        try connection.query("SELECT id, start_time, end_time FROM scenes WHERE run_id = ?",
                             [.integer(runID)]).map { row in
            (row["id"]?.intValue ?? 0,
             row["start_time"]?.doubleValue ?? 0,
             row["end_time"]?.doubleValue ?? 0)
        }
    }

    func addSceneTag(sceneID: Int64, tag: String) throws {
        try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                               [.integer(sceneID), .text(tag)])
    }

    /// Drop every tag of one scene sharing a prefix — a re-run of a pass
    /// that owns that tag family (e.g. "framed:") starts from a clean slate.
    func removeSceneTags(sceneID: Int64, withPrefix prefix: String) throws {
        try connection.execute("DELETE FROM scene_tags WHERE scene_id = ? AND tag LIKE ?",
                               [.integer(sceneID), .text(prefix + "%")])
    }

    /// The person's first user-drawn marker with its video path — the best
    /// possible avatar source, since the box is ground truth for who's in it.
    func markerReference(personID: Int64) throws -> (videoPath: String, marker: PersonMarker)? {
        try connection.query("""
            SELECT pm.*, v.path AS video_path FROM person_markers pm
            JOIN videos v ON v.id = pm.video_id
            WHERE pm.person_id = ? ORDER BY pm.id LIMIT 1
            """, [.integer(personID)]).first.map { row in
            (row["video_path"]?.stringValue ?? "",
             PersonMarker(id: row["id"]?.intValue ?? 0,
                          videoID: row["video_id"]?.intValue ?? 0,
                          atTime: row["at_time"]?.doubleValue ?? 0,
                          x: row["x"]?.doubleValue ?? 0,
                          y: row["y"]?.doubleValue ?? 0,
                          width: row["width"]?.doubleValue ?? 0,
                          height: row["height"]?.doubleValue ?? 0,
                          personID: personID))
        }
    }

    /// Rename support: the file was already moved on disk; scenes join the
    /// videos table, so their paths follow automatically. `provenance` is
    /// the model that proposed the name; nil (a hand rename) clears it.
    func renameVideo(id: Int64, filename: String, path: String,
                     provenance: AIProvenance? = nil) throws {
        try connection.execute("""
            UPDATE videos SET filename = ?, path = ?, naming_provider = ?, naming_model = ? WHERE id = ?
            """, [.text(filename), .text(path),
                  provenance.map { SQLValue.text($0.provider) } ?? .null,
                  provenance?.model.map(SQLValue.text) ?? .null,
                  .integer(id)])
    }

    func fetchVideos() throws -> [VideoRecord] {
        try connection.query("SELECT * FROM videos ORDER BY filename COLLATE NOCASE").map(Self.videoRecord)
    }

    func video(id: Int64) throws -> VideoRecord? {
        try connection.query("SELECT * FROM videos WHERE id = ?", [.integer(id)]).first.map(Self.videoRecord)
    }

    private static func videoRecord(_ row: SQLRow) -> VideoRecord {
        VideoRecord(
            id: row["id"]?.intValue ?? 0,
            hash: row["hash"]?.stringValue ?? "",
            filename: row["filename"]?.stringValue ?? "",
            path: row["path"]?.stringValue ?? "",
            duration: row["duration"]?.doubleValue ?? 0,
            width: Int(row["width"]?.intValue ?? 0),
            height: Int(row["height"]?.intValue ?? 0),
            wide: row["wide"]?.boolValue ?? false,
            discoveredAt: row["discovered_at"]?.stringValue,
            analyzedAt: row["analyzed_at"]?.stringValue,
            visualAnalyzedAt: row["visual_analyzed_at"]?.stringValue,
            speechAnalyzedAt: row["speech_analyzed_at"]?.stringValue,
            visualAnalyzerProvider: row["visual_analyzer_provider"]?.stringValue,
            visualAnalyzerModel: row["visual_analyzer_model"]?.stringValue,
            speechAnalyzerProvider: row["speech_analyzer_provider"]?.stringValue,
            speechAnalyzerModel: row["speech_analyzer_model"]?.stringValue,
            peopleDetectedAt: row["people_detected_at"]?.stringValue,
            peopleProvider: row["people_provider"]?.stringValue,
            peopleModel: row["people_model"]?.stringValue,
            namingProvider: row["naming_provider"]?.stringValue,
            namingModel: row["naming_model"]?.stringValue,
            videoType: row["video_type"]?.stringValue)
    }

    func setVideoType(id: Int64, type: String?) throws {
        try connection.execute("UPDATE videos SET video_type = ? WHERE id = ?",
                               [type.map(SQLValue.text) ?? .null, .integer(id)])
    }

    // MARK: - Scenes

    /// All scenes joined with their video, tags, and grade summary.
    func fetchScenes(videoID: Int64? = nil, includeExcluded: Bool = true) throws -> [SceneRecord] {
        var sql = """
            SELECT s.*, v.path AS video_path, v.filename AS video_filename,
                   v.duration AS video_duration, v.wide AS video_wide
            FROM scenes s JOIN videos v ON v.id = s.video_id
            """
        var params: [SQLValue] = []
        var conditions: [String] = []
        if let videoID {
            conditions.append("s.video_id = ?")
            params.append(.integer(videoID))
        }
        if !includeExcluded {
            conditions.append("s.excluded = 0")
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY v.filename COLLATE NOCASE, s.start_time"
        let sceneRows = try connection.query(sql, params)

        // Scope the tag/grade lookups to the filter — otherwise a
        // single-video fetch pays for the whole library's tags and grades.
        let sceneScope = videoID != nil ? " WHERE scene_id IN (SELECT id FROM scenes WHERE video_id = ?)" : ""
        let scopeParams: [SQLValue] = videoID.map { [.integer($0)] } ?? []

        let tagRows = try connection.query("SELECT scene_id, tag FROM scene_tags" + sceneScope, scopeParams)
        var tagsByScene: [Int64: [String]] = [:]
        for row in tagRows {
            guard let sceneID = row["scene_id"]?.intValue, let tag = row["tag"]?.stringValue else { continue }
            tagsByScene[sceneID, default: []].append(tag)
        }

        let gradeRows = try connection.query(
            "SELECT scene_id, AVG(score) AS avg, COUNT(*) AS n, "
                + "(SELECT score FROM grades g2 WHERE g2.scene_id = grades.scene_id ORDER BY g2.id DESC LIMIT 1) AS last "
                + "FROM grades" + sceneScope + " GROUP BY scene_id",
            scopeParams)
        var gradesByScene: [Int64: (average: Double, count: Int, last: Int?)] = [:]
        for row in gradeRows {
            guard let sceneID = row["scene_id"]?.intValue else { continue }
            gradesByScene[sceneID] = (row["avg"]?.doubleValue ?? 0,
                                      Int(row["n"]?.intValue ?? 0),
                                      row["last"]?.intValue.map(Int.init))
        }

        return sceneRows.map { row in
            let id = row["id"]?.intValue ?? 0
            let grade = gradesByScene[id]
            // Curation edits substitute in as THE range, so every consumer
            // (wizard, builder, previews) honors trims/extensions; originals
            // ride along for the editor's reset.
            let originalStart = row["start_time"]?.doubleValue ?? 0
            let originalEnd = row["end_time"]?.doubleValue ?? 0
            return SceneRecord(
                id: id,
                videoID: row["video_id"]?.intValue ?? 0,
                runID: row["run_id"]?.intValue,
                startTime: row["edit_start"]?.doubleValue ?? originalStart,
                endTime: row["edit_end"]?.doubleValue ?? originalEnd,
                originalStart: originalStart,
                originalEnd: originalEnd,
                curated: row["curated"]?.boolValue ?? false,
                curatedProvider: row["curated_provider"]?.stringValue,
                curatedModel: row["curated_model"]?.stringValue,
                narrative: row["narrative"]?.stringValue,
                score: row["score"]?.doubleValue,
                excitement: row["excitement"]?.doubleValue,
                parentSceneID: row["parent_scene_id"]?.intValue,
                stackChoice: row["stack_choice"]?.boolValue ?? false,
                excluded: row["excluded"]?.boolValue ?? false,
                ignored: row["ignored"]?.boolValue ?? false,
                favorite: row["favorite"]?.boolValue ?? false,
                cropXFrac: row["crop_x_frac"]?.doubleValue,
                freeCropsJSON: row["free_crops"]?.stringValue,
                centerStagePathJSON: row["center_stage_path"]?.stringValue,
                tags: tagsByScene[id]?.sorted() ?? [],
                gradeAverage: grade?.average,
                gradeCount: grade?.count ?? 0,
                lastGrade: grade?.last,
                videoPath: row["video_path"]?.stringValue ?? "",
                videoFilename: row["video_filename"]?.stringValue ?? "",
                videoDuration: row["video_duration"]?.doubleValue ?? 0,
                wide: row["video_wide"]?.boolValue ?? false)
        }
    }

    func setSceneFavorite(_ sceneID: Int64, favorite: Bool) throws {
        try connection.execute("UPDATE scenes SET favorite = ? WHERE id = ?",
                               [.integer(favorite ? 1 : 0), .integer(sceneID)])
    }

    func setSceneExcluded(_ sceneID: Int64, excluded: Bool) throws {
        try connection.execute("UPDATE scenes SET excluded = ? WHERE id = ?",
                               [.integer(excluded ? 1 : 0), .integer(sceneID)])
    }

    /// Suggested 9:16 crop-window position (0 = left … 1 = right) recorded
    /// by the analyzer's portrait-fit pass; the wizard and Builder read it
    /// as the scene's default crop.
    func setSceneCropX(_ sceneID: Int64, fraction: Double) throws {
        try connection.execute("UPDATE scenes SET crop_x_frac = ? WHERE id = ?",
                               [.real(fraction), .integer(sceneID)])
    }

    /// The analyzer's sequence understanding: what happens in the scene and
    /// how entertaining it is (0–10, escalation-aware, audio-boosted).
    func setSceneNarrative(_ sceneID: Int64, narrative: String?, score: Double?) throws {
        try connection.execute("UPDATE scenes SET narrative = ?, score = ? WHERE id = ?",
                               [narrative.map(SQLValue.text) ?? .null,
                                score.map(SQLValue.real) ?? .null, .integer(sceneID)])
    }

    func setSceneScore(_ sceneID: Int64, score: Double, excitement: Double? = nil) throws {
        try connection.execute("UPDATE scenes SET score = ?, excitement = COALESCE(?, excitement) WHERE id = ?",
                               [.real(score), excitement.map(SQLValue.real) ?? .null,
                                .integer(sceneID)])
    }

    /// Mark/unmark a scene as the user's hand-picked best of its stack of
    /// near-simultaneous scenes — it replaces the AI's pick on top.
    func setSceneStackChoice(_ sceneID: Int64, chosen: Bool) throws {
        try connection.execute("UPDATE scenes SET stack_choice = ? WHERE id = ?",
                               [.integer(chosen ? 1 : 0), .integer(sceneID)])
    }

    /// Link a breakdown action to the sequence scene it was cut from.
    func setSceneParent(_ sceneID: Int64, parentID: Int64) throws {
        try connection.execute("UPDATE scenes SET parent_scene_id = ? WHERE id = ?",
                               [.integer(parentID), .integer(sceneID)])
    }

    /// Promote/demote a scene in the curated set. `provenance` records the
    /// AI Curator that picked it; nil = the user's own pick (or a demotion).
    func setSceneCurated(_ sceneID: Int64, curated: Bool, provenance: AIProvenance? = nil) throws {
        let stamp = curated ? provenance : nil
        try connection.execute("""
            UPDATE scenes SET curated = ?, curated_provider = ?, curated_model = ? WHERE id = ?
            """, [.integer(curated ? 1 : 0),
                  stamp.map { SQLValue.text($0.provider) } ?? .null,
                  stamp?.model.map(SQLValue.text) ?? .null,
                  .integer(sceneID)])
    }

    /// Curation trim/extend override (nil clears back to the analyzed range).
    func setSceneEditRange(_ sceneID: Int64, start: Double?, end: Double?) throws {
        try connection.execute("UPDATE scenes SET edit_start = ?, edit_end = ? WHERE id = ?",
                               [start.map(SQLValue.real) ?? .null,
                                end.map(SQLValue.real) ?? .null, .integer(sceneID)])
    }

    /// Center Stage camera path (SceneCameraPath JSON) recorded during
    /// analysis; the scene preview animates it and renders reuse it.
    func setSceneCenterStagePath(_ sceneID: Int64, json: String?) throws {
        try connection.execute("UPDATE scenes SET center_stage_path = ? WHERE id = ?",
                               [json.map(SQLValue.text) ?? .null, .integer(sceneID)])
    }

    func addGrade(sceneID: Int64, score: Int) throws {
        try connection.execute("INSERT INTO grades (scene_id, score) VALUES (?, ?)",
                               [.integer(sceneID), .integer(Int64(score))])
    }

    // MARK: - Analysis results

    // MARK: - Analysis runs (batches)

    /// All batches joined with their video and scene count, newest first.
    func fetchAnalysisRuns() throws -> [AnalysisRun] {
        try connection.query("""
            SELECT r.*, v.filename AS video_filename, v.path AS video_path,
                   (SELECT COUNT(*) FROM scenes s WHERE s.run_id = r.id) AS scene_count
            FROM analysis_runs r JOIN videos v ON v.id = r.video_id
            ORDER BY r.created_at DESC, r.id DESC
            """).map { row in
            AnalysisRun(id: row["id"]?.intValue ?? 0,
                        videoID: row["video_id"]?.intValue ?? 0,
                        name: row["name"]?.stringValue ?? "",
                        instructions: row["instructions"]?.stringValue ?? "",
                        provider: row["provider"]?.stringValue,
                        model: row["model"]?.stringValue,
                        hasTranscript: row["has_transcript"]?.boolValue ?? false,
                        sampleInterval: row["sample_interval"]?.doubleValue ?? 0,
                        notesJSON: row["notes_json"]?.stringValue,
                        createdAt: row["created_at"]?.stringValue,
                        videoFilename: row["video_filename"]?.stringValue ?? "",
                        videoPath: row["video_path"]?.stringValue ?? "",
                        sceneCount: Int(row["scene_count"]?.intValue ?? 0))
        }
    }

    func renameAnalysisRun(id: Int64, name: String) throws {
        try connection.execute("UPDATE analysis_runs SET name = ? WHERE id = ?",
                               [.text(name), .integer(id)])
    }

    /// Record that this batch's analyze run produced (or kept) a transcript.
    func markAnalysisRunTranscribed(id: Int64) throws {
        try connection.execute("UPDATE analysis_runs SET has_transcript = 1 WHERE id = ?",
                               [.integer(id)])
    }

    /// Delete a batch and its scenes; scene_tags and grades cascade.
    func deleteAnalysisRun(id: Int64) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM scenes WHERE run_id = ?", [.integer(id)])
            try connection.execute("DELETE FROM analysis_runs WHERE id = ?", [.integer(id)])
        }
    }

    /// Persist one analysis pass — mirrors analyzer.py save_analysis():
    /// a new analysis_runs batch records when the pass ran and the
    /// instructions it used, tag time-ranges become that batch's scenes +
    /// scene_tags (INSERT OR IGNORE dedup), moments and analyzed-tag
    /// bookkeeping recorded, low-quality scenes auto-hidden, per-mode
    /// timestamps and provider attribution stamped.
    /// Returns the id of the analyze batch the pass was stored under.
    @discardableResult
    func saveAnalysis(videoID: Int64,
                      runName: String,
                      instructions: String,
                      sampleInterval: Double?,
                      notesJSON: String?,
                      tagRanges: [String: [(start: Double, end: Double)]],
                      moments: [(at: Double, note: String, dialog: String?)],
                      analyzedTags: [String],
                      provider: String?, model: String?, mode: String) throws -> Int64 {
        // (start, end) → set of tags, so one range shared by many tags makes one scene.
        var rangeTags: [String: (start: Double, end: Double, tags: Set<String>)] = [:]
        for (tag, ranges) in tagRanges {
            for range in ranges {
                let key = "\(range.start)-\(range.end)"
                rangeTags[key, default: (range.start, range.end, [])].tags.insert(tag)
            }
        }
        // One transaction: a pass writes hundreds of rows, and committing
        // per statement would pay a WAL sync for each (and persist a
        // half-saved analysis on failure).
        return try connection.transaction {
            try connection.execute("""
                INSERT INTO analysis_runs (video_id, name, instructions, provider, model, sample_interval, notes_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.integer(videoID), .text(runName), .text(instructions),
                      provider.map(SQLValue.text) ?? .null,
                      model.map(SQLValue.text) ?? .null,
                      .real(sampleInterval ?? 0),
                      notesJSON.map(SQLValue.text) ?? .null])
            let runID = connection.lastInsertRowID
            for (_, entry) in rangeTags {
                // The no-op DO UPDATE makes RETURNING yield the id for the
                // pre-existing row too, replacing the insert-then-SELECT pair.
                guard let sceneID = try connection.query("""
                    INSERT INTO scenes (video_id, run_id, start_time, end_time)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(video_id, run_id, start_time, end_time) DO UPDATE SET video_id = video_id
                    RETURNING id
                    """, [.integer(videoID), .integer(runID), .real(entry.start), .real(entry.end)]
                ).first?["id"]?.intValue else { continue }
                for tag in entry.tags {
                    try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                           [.integer(sceneID), .text(tag)])
                }
            }
            for moment in moments {
                try connection.execute("INSERT INTO moments (video_id, at_time, note, dialog) VALUES (?, ?, ?, ?)",
                                       [.integer(videoID), .real(moment.at), .text(moment.note),
                                        moment.dialog.map(SQLValue.text) ?? .null])
            }
            for tag in analyzedTags {
                try connection.execute("INSERT OR IGNORE INTO analyzed_tags (video_id, tag) VALUES (?, ?)",
                                       [.integer(videoID), .text(tag)])
            }
            // Auto-hide unusable footage flagged low-quality by the analyzer.
            try connection.execute("""
                INSERT OR IGNORE INTO scene_tags (scene_id, tag)
                SELECT s.id, 'auto-hidden' FROM scenes s
                JOIN scene_tags t ON t.scene_id = s.id
                WHERE s.run_id = ? AND t.tag = 'low-quality'
                """, [.integer(runID)])
            try connection.execute("""
                UPDATE scenes SET excluded = 1 WHERE run_id = ? AND id IN
                    (SELECT scene_id FROM scene_tags WHERE tag = 'low-quality')
                """, [.integer(runID)])
            try connection.execute("UPDATE videos SET analyzed_at = datetime('now') WHERE id = ?", [.integer(videoID)])
            let modeColumn = mode == "speech" ? "speech" : "visual"
            try connection.execute("UPDATE videos SET \(modeColumn)_analyzed_at = datetime('now') WHERE id = ?",
                                   [.integer(videoID)])
            if let provider {
                try connection.execute("""
                    UPDATE videos SET analyzer_provider = ?, \(modeColumn)_analyzer_provider = ? WHERE id = ?
                    """, [.text(provider), .text(provider), .integer(videoID)])
            }
            if let model {
                try connection.execute("""
                    UPDATE videos SET analyzer_model = ?, \(modeColumn)_analyzer_model = ? WHERE id = ?
                    """, [.text(model), .text(model), .integer(videoID)])
            }
            return runID
        }
    }

    // MARK: - People

    func fetchPeople() throws -> [PersonRecord] {
        try connection.query("SELECT * FROM people ORDER BY name COLLATE NOCASE, id").map { row in
            PersonRecord(id: row["id"]?.intValue ?? 0,
                         key: row["key"]?.stringValue ?? "",
                         name: row["name"]?.stringValue ?? "",
                         descriptor: row["descriptor"]?.stringValue ?? "",
                         hidden: (row["hidden"]?.intValue ?? 0) != 0,
                         avatarVideoID: row["avatar_video_id"]?.intValue,
                         avatarTime: row["avatar_time"]?.doubleValue,
                         avatarBoxJSON: row["avatar_box"]?.stringValue)
        }
    }

    /// Save (or clear, with nils) a person's hand-picked avatar frame.
    func setPersonAvatar(id: Int64, videoID: Int64?, time: Double?, boxJSON: String?) throws {
        try connection.execute("""
            UPDATE people SET avatar_video_id = ?, avatar_time = ?, avatar_box = ? WHERE id = ?
            """, [videoID.map(SQLValue.integer) ?? .null,
                  time.map(SQLValue.real) ?? .null,
                  boxJSON.map(SQLValue.text) ?? .null,
                  .integer(id)])
    }

    /// Tuck a person into (or bring them back from) the People screen's
    /// Hidden bucket. Identity is untouched — detection still reuses their
    /// key and their scene tags stay.
    func setPersonHidden(id: Int64, hidden: Bool) throws {
        try connection.execute("UPDATE people SET hidden = ? WHERE id = ?",
                               [.integer(hidden ? 1 : 0), .integer(id)])
    }

    /// Register a detected person, refreshing the visual descriptor with the
    /// latest sighting (names are user-owned and never touched here).
    func upsertPerson(key: String, descriptor: String) throws {
        try connection.execute("""
            INSERT INTO people (key, descriptor) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET
                descriptor = CASE WHEN excluded.descriptor != '' THEN excluded.descriptor
                                  ELSE people.descriptor END
            """, [.text(key), .text(descriptor)])
    }

    func renamePerson(id: Int64, name: String) throws {
        try connection.execute("UPDATE people SET name = ? WHERE id = ?", [.text(name), .integer(id)])
    }

    /// Remove a person and every scene tag pointing at them.
    func deletePerson(_ person: PersonRecord) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM scene_tags WHERE tag = ?", [.text(person.tag)])
            try connection.execute("UPDATE person_markers SET person_id = NULL WHERE person_id = ?",
                                   [.integer(person.id)])
            try connection.execute("DELETE FROM people WHERE id = ?", [.integer(person.id)])
        }
    }

    /// The AI occasionally splits one real person into two keys — merging
    /// retags every scene of `source` onto `target` and drops `source`.
    func mergePeople(source: PersonRecord, into target: PersonRecord) throws {
        try connection.transaction {
            try connection.execute("UPDATE OR IGNORE scene_tags SET tag = ? WHERE tag = ?",
                                   [.text(target.tag), .text(source.tag)])
            // Rows whose retag collided with an existing target tag remain.
            try connection.execute("DELETE FROM scene_tags WHERE tag = ?", [.text(source.tag)])
            try connection.execute("UPDATE person_markers SET person_id = ? WHERE person_id = ?",
                                   [.integer(target.id), .integer(source.id)])
            try connection.execute("DELETE FROM people WHERE id = ?", [.integer(source.id)])
        }
    }

    /// Create a person by hand (split target). Returns the new record.
    func createPerson(name: String) throws -> PersonRecord {
        var key = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" { result.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if key.isEmpty { key = "person" }
        // Uniquify against existing keys.
        let existing = Set(try fetchPeople().map(\.key))
        var candidate = key
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(key)-\(counter)"
            counter += 1
        }
        try connection.execute("INSERT INTO people (key, name) VALUES (?, ?)",
                               [.text(candidate), .text(name)])
        let id = connection.lastInsertRowID
        return PersonRecord(id: id, key: candidate, name: name, descriptor: "")
    }

    /// Split support: move one scene's person tag from `from` to `to`
    /// (nil `to` = the scene simply loses the person).
    func reassignScenePerson(sceneID: Int64, from: PersonRecord, to: PersonRecord?) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM scene_tags WHERE scene_id = ? AND tag = ?",
                                   [.integer(sceneID), .text(from.tag)])
            if let to {
                try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                       [.integer(sceneID), .text(to.tag)])
            }
        }
    }

    func analyzedTags(videoID: Int64) throws -> Set<String> {
        let rows = try connection.query("SELECT tag FROM analyzed_tags WHERE video_id = ?", [.integer(videoID)])
        return Set(rows.compactMap { $0["tag"]?.stringValue })
    }

    func moments(videoID: Int64) throws -> [MomentRecord] {
        try connection.query("SELECT * FROM moments WHERE video_id = ? ORDER BY at_time", [.integer(videoID)]).map {
            MomentRecord(id: $0["id"]?.intValue ?? 0,
                         videoID: $0["video_id"]?.intValue ?? 0,
                         atTime: $0["at_time"]?.doubleValue ?? 0,
                         note: $0["note"]?.stringValue ?? "",
                         dialog: $0["dialog"]?.stringValue)
        }
    }

    // MARK: - Transcripts

    func replaceTranscripts(videoID: Int64, language: String, isTranslation: Bool,
                            segments: [TranscriptSegment], provider: String?, model: String?) throws {
        // One transaction: long videos have thousands of segments, and the
        // delete + inserts must land atomically.
        try connection.transaction {
            try connection.execute("DELETE FROM transcripts WHERE video_id = ? AND language = ? AND is_translation = ?",
                                   [.integer(videoID), .text(language), .integer(isTranslation ? 1 : 0)])
            let encoder = JSONEncoder()
            for segment in segments {
                let wordsJSON = segment.words.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
                try connection.execute("""
                    INSERT INTO transcripts (video_id, language, is_translation, start_time, end_time, text, words, provider, model)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .text(language), .integer(isTranslation ? 1 : 0),
                          .real(segment.start), .real(segment.end), .text(segment.text),
                          wordsJSON.map(SQLValue.text) ?? .null,
                          provider.map(SQLValue.text) ?? .null,
                          model.map(SQLValue.text) ?? .null])
            }
        }
    }

    func fetchTranscripts(videoID: Int64) throws -> [TranscriptRow] {
        try connection.query("SELECT * FROM transcripts WHERE video_id = ? ORDER BY is_translation, start_time",
                             [.integer(videoID)]).map {
            TranscriptRow(id: $0["id"]?.intValue ?? 0,
                          videoID: $0["video_id"]?.intValue ?? 0,
                          language: $0["language"]?.stringValue ?? "",
                          isTranslation: $0["is_translation"]?.boolValue ?? false,
                          startTime: $0["start_time"]?.doubleValue ?? 0,
                          endTime: $0["end_time"]?.doubleValue ?? 0,
                          text: $0["text"]?.stringValue ?? "",
                          originalText: $0["original_text"]?.stringValue,
                          wordsJSON: $0["words"]?.stringValue,
                          provider: $0["provider"]?.stringValue,
                          model: $0["model"]?.stringValue)
        }
    }

    /// Transcript segments overlapping [start, end] for one video — used for
    /// caption burn-in of a clip.
    func transcriptSegments(videoID: Int64, start: Double, end: Double) throws -> [TranscriptSegment] {
        try connection.query("""
            SELECT start_time, end_time, text FROM transcripts
            WHERE video_id = ? AND is_translation = 0 AND end_time > ? AND start_time < ?
            ORDER BY start_time
            """, [.integer(videoID), .real(start), .real(end)]).map {
            TranscriptSegment(start: $0["start_time"]?.doubleValue ?? 0,
                              end: $0["end_time"]?.doubleValue ?? 0,
                              text: $0["text"]?.stringValue ?? "",
                              words: nil)
        }
    }

    /// Edit transcript text in place, preserving the pristine original once.
    func updateTranscriptText(id: Int64, text: String) throws {
        try connection.execute("""
            UPDATE transcripts
            SET original_text = COALESCE(original_text, text), text = ?
            WHERE id = ?
            """, [.text(text), .integer(id)])
    }

    func revertTranscriptText(id: Int64) throws {
        try connection.execute("""
            UPDATE transcripts SET text = original_text, original_text = NULL
            WHERE id = ? AND original_text IS NOT NULL
            """, [.integer(id)])
    }

    // MARK: - Generated videos

    @discardableResult
    func insertGeneratedVideo(path: String, duration: Double, timelineJSON: String,
                              wizardProvider: String?, wizardModel: String?,
                              rationale: String? = nil, batchID: String? = nil,
                              qualityJSON: String? = nil,
                              planClipsJSON: String? = nil) throws -> Int64 {
        try connection.execute("""
            INSERT INTO generated_videos (path, duration, timeline_json, wizard_provider, wizard_model,
                                          rationale, batch_id, quality_json, plan_clips_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(path), .real(duration), .text(timelineJSON),
                  wizardProvider.map(SQLValue.text) ?? .null,
                  wizardModel.map(SQLValue.text) ?? .null,
                  rationale.map(SQLValue.text) ?? .null,
                  batchID.map(SQLValue.text) ?? .null,
                  qualityJSON.map(SQLValue.text) ?? .null,
                  planClipsJSON.map(SQLValue.text) ?? .null])
        return connection.lastInsertRowID
    }

    func fetchGeneratedVideos() throws -> [GeneratedVideoRecord] {
        try connection.query("""
            SELECT g.*, m.stats_json AS instagram_stats_json
            FROM generated_videos g
            LEFT JOIN ig_media m ON m.media_id = g.instagram_media_id
            WHERE COALESCE(g.deleted, 0) = 0
            ORDER BY g.generated_at DESC, g.id DESC
            """).map(Self.generatedVideoRecord)
    }

    private static func generatedVideoRecord(_ row: SQLRow) -> GeneratedVideoRecord {
        GeneratedVideoRecord(id: row["id"]?.intValue ?? 0,
                             path: row["path"]?.stringValue ?? "",
                             duration: row["duration"]?.doubleValue ?? 0,
                             timelineJSON: row["timeline_json"]?.stringValue ?? "[]",
                             caption: row["caption"]?.stringValue ?? "",
                             generatedAt: row["generated_at"]?.stringValue,
                             wizardProvider: row["wizard_provider"]?.stringValue,
                             wizardModel: row["wizard_model"]?.stringValue,
                             captionProvider: row["caption_provider"]?.stringValue,
                             captionModel: row["caption_model"]?.stringValue,
                             rationale: row["rationale"]?.stringValue,
                             batchID: row["batch_id"]?.stringValue,
                             qualityJSON: row["quality_json"]?.stringValue,
                             critiqueJSON: row["critique_json"]?.stringValue,
                             planClipsJSON: row["plan_clips_json"]?.stringValue,
                             instagramMediaID: row["instagram_media_id"]?.stringValue,
                             instagramStats: row["instagram_stats_json"]?.stringValue
                                .flatMap { $0.data(using: .utf8) }
                                .flatMap { try? JSONDecoder().decode(IGStats.self, from: $0) },
                             audienceScore: row["audience_score"]?.doubleValue,
                             audiencePercentile: row["audience_percentile"]?.intValue.map(Int.init),
                             coverTime: row["cover_time"]?.doubleValue,
                             coverProvider: row["cover_provider"]?.stringValue,
                             coverModel: row["cover_model"]?.stringValue)
    }

    /// Remember the picked cover frame — the Library card renders its
    /// thumbnail at this time from then on. `provenance` is the model that
    /// ranked the frame; nil = a hand pick.
    func updateGeneratedCover(id: Int64, time: Double, provenance: AIProvenance? = nil) throws {
        try connection.execute("""
            UPDATE generated_videos SET cover_time = ?, cover_provider = ?, cover_model = ? WHERE id = ?
            """, [.real(time),
                  provenance.map { SQLValue.text($0.provider) } ?? .null,
                  provenance?.model.map(SQLValue.text) ?? .null,
                  .integer(id)])
    }

    /// Attach the AI critic's post-render review to a generated video.
    func updateGeneratedCritique(id: Int64, critiqueJSON: String) throws {
        try connection.execute("UPDATE generated_videos SET critique_json = ? WHERE id = ?",
                               [.text(critiqueJSON), .integer(id)])
    }

    /// Record how a published reel did among the account's reels.
    func updateGeneratedAudience(id: Int64, score: Double, percentile: Int) throws {
        try connection.execute("""
            UPDATE generated_videos SET audience_score = ?, audience_percentile = ?,
                audience_measured_at = datetime('now') WHERE id = ?
            """, [.real(score), .integer(Int64(percentile)), .integer(id)])
    }

    /// Reel templates joined to the Graph media they analyzed, for the
    /// account benchmarks (which structural traits meet which numbers).
    func fetchIGTemplateLinks() throws -> [IGTemplateLink] {
        try connection.query("""
            SELECT t.template_json, m.media_id, m.stats_json, m.duration
            FROM ig_templates t JOIN ig_media m ON m.id = t.media_id
            """).map { row in
                IGTemplateLink(mediaID: row["media_id"]?.stringValue ?? "",
                               templateJSON: row["template_json"]?.stringValue ?? "{}",
                               statsJSON: row["stats_json"]?.stringValue,
                               duration: row["duration"]?.doubleValue ?? 0)
            }
    }

    func updateGeneratedCaption(id: Int64, caption: String, provider: String?, model: String?) throws {
        try connection.execute("""
            UPDATE generated_videos SET caption = ?, caption_provider = ?, caption_model = ? WHERE id = ?
            """, [.text(caption),
                  provider.map(SQLValue.text) ?? .null,
                  model.map(SQLValue.text) ?? .null,
                  .integer(id)])
    }

    func recentGeneratedPerformance(limit: Int = 12) throws -> [GeneratedPerformanceRecord] {
        try connection.query("""
            SELECT g.path, g.duration, g.rationale, m.stats_json
            FROM generated_videos g JOIN ig_media m ON m.media_id = g.instagram_media_id
            WHERE COALESCE(g.deleted, 0) = 0
            ORDER BY g.generated_at DESC, g.id DESC LIMIT ?
            """, [.integer(Int64(limit))]).compactMap { row in
                guard let json = row["stats_json"]?.stringValue,
                      let data = json.data(using: .utf8),
                      let stats = try? JSONDecoder().decode(IGStats.self, from: data) else { return nil }
                return GeneratedPerformanceRecord(
                    filename: URL(fileURLWithPath: row["path"]?.stringValue ?? "").lastPathComponent,
                    duration: row["duration"]?.doubleValue ?? 0,
                    rationale: row["rationale"]?.stringValue,
                    stats: stats)
            }
    }

    func markGeneratedVideoPublished(id: Int64, instagramMediaID: String) throws {
        try connection.execute("UPDATE generated_videos SET instagram_media_id = ? WHERE id = ?",
                               [.text(instagramMediaID), .integer(id)])
    }

    /// Soft delete: the row (plan, rationale, reviews) is retained as a
    /// negative training signal for the wizard; only the Library hides it.
    func deleteGeneratedVideo(id: Int64) throws {
        try connection.execute("UPDATE generated_videos SET deleted = 1 WHERE id = ?", [.integer(id)])
    }

    // MARK: - Reviews, preferences, lessons

    /// Upsert the structured review for one generated video (whole-video
    /// verdict + per-clip verdicts replace any previous review).
    func saveReview(_ review: GenerationReview, clips: [ClipReview]) throws {
        let dimensionsJSON = (try? JSONSerialization.data(withJSONObject: review.dimensions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try connection.transaction {
            try connection.execute("""
                INSERT INTO generation_reviews (generated_video_id, verdict, dimensions_json, note)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(generated_video_id) DO UPDATE SET
                    verdict=excluded.verdict,
                    dimensions_json=excluded.dimensions_json,
                    note=excluded.note,
                    created_at=datetime('now')
                """, [.integer(review.generatedVideoID), .integer(Int64(review.verdict)),
                      .text(dimensionsJSON), .text(review.note)])
            try connection.execute("DELETE FROM clip_reviews WHERE generated_video_id = ?",
                                   [.integer(review.generatedVideoID)])
            for clip in clips {
                let reasonsJSON = (try? JSONSerialization.data(withJSONObject: clip.reasons))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try connection.execute("""
                    INSERT INTO clip_reviews (generated_video_id, clip_index, scene_id, verdict, reasons_json)
                    VALUES (?, ?, ?, ?, ?)
                    """, [.integer(review.generatedVideoID), .integer(Int64(clip.clipIndex)),
                          clip.sceneID.map(SQLValue.integer) ?? .null,
                          .integer(Int64(clip.verdict)), .text(reasonsJSON)])
            }
        }
    }

    func fetchReview(generatedVideoID: Int64) throws -> (review: GenerationReview, clips: [ClipReview])? {
        guard let row = try connection.query(
            "SELECT * FROM generation_reviews WHERE generated_video_id = ?",
            [.integer(generatedVideoID)]).first else { return nil }
        let clipRows = try connection.query(
            "SELECT * FROM clip_reviews WHERE generated_video_id = ? ORDER BY clip_index",
            [.integer(generatedVideoID)])
        return (Self.generationReview(row), clipRows.map(Self.clipReview))
    }

    /// Newest-first reviews joined with their video's filename and plan
    /// rationale — the wizard's structured training input.
    func fetchReviewSummaries(limit: Int) throws -> [ReviewSummary] {
        let rows = try connection.query("""
            SELECT r.*, g.path AS video_path, g.rationale AS plan_rationale,
                   g.plan_clips_json AS plan_clips_json,
                   COALESCE(g.deleted, 0) AS video_deleted
            FROM generation_reviews r JOIN generated_videos g ON g.id = r.generated_video_id
            ORDER BY r.created_at DESC, r.id DESC LIMIT ?
            """, [.integer(Int64(limit))])
        return try rows.map { row in
            let videoID = row["generated_video_id"]?.intValue ?? 0
            let clipRows = try connection.query(
                "SELECT * FROM clip_reviews WHERE generated_video_id = ? ORDER BY clip_index",
                [.integer(videoID)])
            let path = row["video_path"]?.stringValue ?? ""
            return ReviewSummary(review: Self.generationReview(row),
                                 clips: clipRows.map(Self.clipReview),
                                 videoFilename: URL(fileURLWithPath: path).lastPathComponent,
                                 rationale: row["plan_rationale"]?.stringValue,
                                 videoDeleted: row["video_deleted"]?.boolValue ?? false,
                                 clipReasons: GeneratedVideoRecord.clipReasons(
                                     fromPlanClipsJSON: row["plan_clips_json"]?.stringValue))
        }
    }

    /// Reels the user approved (thumbs-up review), newest first, with their
    /// plan shape — the wizard's positive exemplars.
    func fetchWinningRecipes(limit: Int = 3) throws -> [WinningRecipeRecord] {
        try connection.query("""
            SELECT g.path, g.duration, g.rationale, g.plan_clips_json, m.stats_json
            FROM generated_videos g
            JOIN generation_reviews r ON r.generated_video_id = g.id AND r.verdict > 0
            LEFT JOIN ig_media m ON m.media_id = g.instagram_media_id
            WHERE COALESCE(g.deleted, 0) = 0
            ORDER BY r.created_at DESC, r.id DESC LIMIT ?
            """, [.integer(Int64(limit))]).map { row in
                WinningRecipeRecord(
                    filename: URL(fileURLWithPath: row["path"]?.stringValue ?? "").lastPathComponent,
                    duration: row["duration"]?.doubleValue ?? 0,
                    rationale: row["rationale"]?.stringValue,
                    planClipsJSON: row["plan_clips_json"]?.stringValue,
                    stats: row["stats_json"]?.stringValue
                        .flatMap { $0.data(using: .utf8) }
                        .flatMap { try? JSONDecoder().decode(IGStats.self, from: $0) })
            }
    }

    /// Every cached reel template analysis with its reel's caption and
    /// performance stats — the house-style distiller's input.
    func fetchAllIGTemplates() throws -> [(templateJSON: String, statsJSON: String?)] {
        try connection.query("""
            SELECT t.template_json, m.stats_json
            FROM ig_templates t LEFT JOIN ig_media m ON m.id = t.media_id
            ORDER BY t.analyzed_at DESC
            """).map { row in
                (row["template_json"]?.stringValue ?? "{}",
                 row["stats_json"]?.stringValue)
            }
    }

    private static func generationReview(_ row: SQLRow) -> GenerationReview {
        let dimensions = row["dimensions_json"]?.stringValue
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] } ?? [:]
        return GenerationReview(generatedVideoID: row["generated_video_id"]?.intValue ?? 0,
                                verdict: Int(row["verdict"]?.intValue ?? 0),
                                dimensions: dimensions,
                                note: row["note"]?.stringValue ?? "",
                                createdAt: row["created_at"]?.stringValue)
    }

    private static func clipReview(_ row: SQLRow) -> ClipReview {
        let reasons = row["reasons_json"]?.stringValue
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        return ClipReview(clipIndex: Int(row["clip_index"]?.intValue ?? 0),
                          sceneID: row["scene_id"]?.intValue,
                          verdict: Int(row["verdict"]?.intValue ?? 0),
                          reasons: reasons)
    }

    func addPreference(chosenID: Int64, rejectedID: Int64,
                       chosenRationale: String, rejectedRationale: String) throws {
        try connection.execute("""
            INSERT INTO wizard_preferences (chosen_video_id, rejected_video_id, chosen_rationale, rejected_rationale)
            VALUES (?, ?, ?, ?)
            """, [.integer(chosenID), .integer(rejectedID),
                  .text(chosenRationale), .text(rejectedRationale)])
    }

    func fetchPreferences(limit: Int) throws -> [PreferenceRecord] {
        try connection.query("""
            SELECT * FROM wizard_preferences ORDER BY created_at DESC, id DESC LIMIT ?
            """, [.integer(Int64(limit))]).map {
            PreferenceRecord(id: $0["id"]?.intValue ?? 0,
                             chosenRationale: $0["chosen_rationale"]?.stringValue ?? "",
                             rejectedRationale: $0["rejected_rationale"]?.stringValue ?? "",
                             createdAt: $0["created_at"]?.stringValue)
        }
    }

    func fetchLessons() throws -> [WizardLesson] {
        try connection.query("SELECT * FROM wizard_lessons ORDER BY pinned DESC, id").map {
            WizardLesson(id: $0["id"]?.intValue ?? 0,
                         text: $0["text"]?.stringValue ?? "",
                         pinned: $0["pinned"]?.boolValue ?? false,
                         evidence: $0["evidence"]?.stringValue ?? "",
                         provider: $0["provider"]?.stringValue,
                         model: $0["model"]?.stringValue,
                         createdAt: $0["created_at"]?.stringValue)
        }
    }

    /// `provenance` is the model that distilled the lesson; nil = user-written.
    @discardableResult
    func addLesson(text: String, pinned: Bool, evidence: String,
                   provenance: AIProvenance? = nil) throws -> Int64 {
        try connection.execute("""
            INSERT INTO wizard_lessons (text, pinned, evidence, provider, model) VALUES (?, ?, ?, ?, ?)
            """, [.text(text), .integer(pinned ? 1 : 0), .text(evidence),
                  provenance.map { SQLValue.text($0.provider) } ?? .null,
                  provenance?.model.map(SQLValue.text) ?? .null])
        return connection.lastInsertRowID
    }

    func updateLesson(id: Int64, text: String, pinned: Bool) throws {
        try connection.execute("""
            UPDATE wizard_lessons SET text = ?, pinned = ?, updated_at = datetime('now') WHERE id = ?
            """, [.text(text), .integer(pinned ? 1 : 0), .integer(id)])
    }

    func deleteLesson(id: Int64) throws {
        try connection.execute("DELETE FROM wizard_lessons WHERE id = ?", [.integer(id)])
    }

    /// Distillation output replaces machine-learned lessons; pinned lessons
    /// are user-owned and never touched.
    func replaceLearnedLessons(_ lessons: [(text: String, evidence: String)],
                               provenance: AIProvenance? = nil) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM wizard_lessons WHERE pinned = 0")
            for lesson in lessons {
                try connection.execute("""
                    INSERT INTO wizard_lessons (text, pinned, evidence, provider, model) VALUES (?, 0, ?, ?, ?)
                    """, [.text(lesson.text), .text(lesson.evidence),
                          provenance.map { SQLValue.text($0.provider) } ?? .null,
                          provenance?.model.map(SQLValue.text) ?? .null])
            }
        }
    }

    // MARK: - Wizard research + feedback

    func latestResearch(topic: String) throws -> WizardResearchRecord? {
        guard let row = try connection.query("""
            SELECT * FROM wizard_research WHERE topic = ? ORDER BY researched_at DESC, id DESC LIMIT 1
            """, [.text(topic)]).first else { return nil }
        return WizardResearchRecord(id: row["id"]?.intValue ?? 0,
                                    topic: topic,
                                    resultJSON: row["result_json"]?.stringValue ?? "{}",
                                    researchedAt: Self.parseSQLiteDate(row["researched_at"]?.stringValue),
                                    provider: row["provider"]?.stringValue,
                                    model: row["model"]?.stringValue)
    }

    func saveResearch(topic: String, resultJSON: String, provider: String?, model: String?) throws {
        try connection.execute("""
            INSERT INTO wizard_research (topic, result_json, provider, model) VALUES (?, ?, ?, ?)
            """, [.text(topic), .text(resultJSON),
                  provider.map(SQLValue.text) ?? .null,
                  model.map(SQLValue.text) ?? .null])
    }

    // MARK: - Fight events (action scoring)

    func fetchFightEvents() throws -> [FightEventRecord] {
        try connection.query("SELECT * FROM fight_events ORDER BY video_id, at_time").map { row in
            FightEventRecord(id: row["id"]?.intValue ?? 0,
                             videoID: row["video_id"]?.intValue ?? 0,
                             time: row["at_time"]?.doubleValue ?? 0,
                             fighterKey: row["fighter_key"]?.stringValue ?? "",
                             action: row["action"]?.stringValue ?? "",
                             points: row["points"]?.doubleValue ?? 1,
                             provider: row["provider"]?.stringValue,
                             model: row["model"]?.stringValue)
        }
    }

    /// A scoring pass replaces the video's whole event list, stamped with
    /// the model that logged the events.
    func replaceFightEvents(videoID: Int64,
                            events: [(time: Double, fighterKey: String,
                                      action: String, points: Double)],
                            provenance: AIProvenance? = nil) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM fight_events WHERE video_id = ?", [.integer(videoID)])
            for event in events {
                try connection.execute("""
                    INSERT INTO fight_events (video_id, at_time, fighter_key, action, points, provider, model)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .real(event.time), .text(event.fighterKey),
                          .text(event.action), .real(event.points),
                          provenance.map { SQLValue.text($0.provider) } ?? .null,
                          provenance?.model.map(SQLValue.text) ?? .null])
            }
        }
    }

    // MARK: - Fight research

    func fetchFightResearch() throws -> [FightResearchRecord] {
        try connection.query("SELECT * FROM fight_research ORDER BY video_id").map { row in
            FightResearchRecord(id: row["id"]?.intValue ?? 0,
                                videoID: row["video_id"]?.intValue ?? 0,
                                fightLabel: row["fight_label"]?.stringValue ?? "",
                                event: row["event"]?.stringValue ?? "",
                                fightDate: row["fight_date"]?.stringValue ?? "",
                                summaryJSON: row["summary_json"]?.stringValue ?? "{}",
                                sourcesJSON: row["sources_json"]?.stringValue ?? "[]",
                                researchedAt: Self.parseSQLiteDate(row["researched_at"]?.stringValue),
                                provider: row["provider"]?.stringValue,
                                model: row["model"]?.stringValue)
        }
    }

    func upsertFightResearch(videoID: Int64, fightLabel: String, event: String,
                             fightDate: String, summaryJSON: String, sourcesJSON: String,
                             provider: String?, model: String?) throws {
        try connection.execute("""
            INSERT INTO fight_research
                (video_id, fight_label, event, fight_date, summary_json, sources_json,
                 provider, model, researched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(video_id) DO UPDATE SET
                fight_label = excluded.fight_label,
                event = excluded.event,
                fight_date = excluded.fight_date,
                summary_json = excluded.summary_json,
                sources_json = excluded.sources_json,
                provider = excluded.provider,
                model = excluded.model,
                researched_at = excluded.researched_at
            """, [.integer(videoID), .text(fightLabel), .text(event), .text(fightDate),
                  .text(summaryJSON), .text(sourcesJSON),
                  provider.map(SQLValue.text) ?? .null,
                  model.map(SQLValue.text) ?? .null])
    }

    /// User edits to the story/identity — keeps sources and timestamp intact.
    func updateFightResearch(videoID: Int64, fightLabel: String, event: String,
                             fightDate: String, summaryJSON: String) throws {
        try connection.execute("""
            UPDATE fight_research
            SET fight_label = ?, event = ?, fight_date = ?, summary_json = ?
            WHERE video_id = ?
            """, [.text(fightLabel), .text(event), .text(fightDate),
                  .text(summaryJSON), .integer(videoID)])
    }

    func deleteFightResearch(videoID: Int64) throws {
        try connection.execute("DELETE FROM fight_research WHERE video_id = ?", [.integer(videoID)])
    }

    func fetchAllFeedback() throws -> [FeedbackRecord] {
        try connection.query("""
            SELECT f.*, g.path AS video_path, g.duration AS video_duration
            FROM wizard_feedback f JOIN generated_videos g ON g.id = f.generated_video_id
            ORDER BY f.created_at DESC, f.id DESC
            """).map {
            FeedbackRecord(id: $0["id"]?.intValue ?? 0,
                           generatedVideoID: $0["generated_video_id"]?.intValue ?? 0,
                           feedback: $0["feedback"]?.stringValue ?? "",
                           createdAt: $0["created_at"]?.stringValue,
                           videoPath: $0["video_path"]?.stringValue,
                           videoDuration: $0["video_duration"]?.doubleValue)
        }
    }

    func addFeedback(generatedVideoID: Int64, text: String) throws {
        try connection.execute("INSERT INTO wizard_feedback (generated_video_id, feedback) VALUES (?, ?)",
                               [.integer(generatedVideoID), .text(text)])
    }

    // MARK: - Instagram

    @discardableResult
    func upsertIGAccount(username: String, kind: String, displayName: String?,
                         igUserID: String?, followers: Int?) throws -> Int64 {
        let rows = try connection.query("""
            INSERT INTO ig_accounts (username, kind, display_name, ig_user_id, followers)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(username) DO UPDATE SET
                kind=excluded.kind,
                display_name=COALESCE(excluded.display_name, ig_accounts.display_name),
                ig_user_id=COALESCE(excluded.ig_user_id, ig_accounts.ig_user_id),
                followers=COALESCE(excluded.followers, ig_accounts.followers)
            RETURNING id
            """, [.text(username), .text(kind),
                  displayName.map(SQLValue.text) ?? .null,
                  igUserID.map(SQLValue.text) ?? .null,
                  followers.map { SQLValue.integer(Int64($0)) } ?? .null])
        return rows.first?["id"]?.intValue ?? connection.lastInsertRowID
    }

    func fetchIGAccounts() throws -> [IGAccountRecord] {
        try connection.query("SELECT * FROM ig_accounts ORDER BY kind DESC, username COLLATE NOCASE").map {
            IGAccountRecord(id: $0["id"]?.intValue ?? 0,
                            username: $0["username"]?.stringValue ?? "",
                            kind: $0["kind"]?.stringValue ?? "public",
                            displayName: $0["display_name"]?.stringValue,
                            igUserID: $0["ig_user_id"]?.stringValue,
                            followers: $0["followers"]?.intValue.map(Int.init),
                            profilePicPath: $0["profile_pic_path"]?.stringValue,
                            lastFetchedAt: Self.parseSQLiteDate($0["last_fetched_at"]?.stringValue),
                            addedAt: $0["added_at"]?.stringValue)
        }
    }

    func deleteIGAccount(id: Int64) throws {
        try connection.execute("DELETE FROM ig_accounts WHERE id = ?", [.integer(id)])
    }

    func markIGAccountFetched(id: Int64) throws {
        try connection.execute("UPDATE ig_accounts SET last_fetched_at = datetime('now') WHERE id = ?",
                               [.integer(id)])
    }

    /// Upsert one fetched media item. Never clears cached local paths —
    /// refreshes update stats/caption, downloads happen separately.
    @discardableResult
    func upsertIGMedia(_ item: IGMediaUpsert) throws -> Int64 {
        let rows = try connection.query("""
            INSERT INTO ig_media (account_id, media_id, media_type, caption, permalink,
                                  posted_at, duration, stats_json, source, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(account_id, media_id) DO UPDATE SET
                media_type=excluded.media_type,
                caption=excluded.caption,
                permalink=COALESCE(excluded.permalink, ig_media.permalink),
                posted_at=COALESCE(excluded.posted_at, ig_media.posted_at),
                duration=CASE WHEN excluded.duration > 0 THEN excluded.duration ELSE ig_media.duration END,
                stats_json=excluded.stats_json,
                source=excluded.source,
                fetched_at=datetime('now')
            RETURNING id
            """, [.integer(item.accountID), .text(item.mediaID), .text(item.mediaType),
                  .text(item.caption),
                  item.permalink.map(SQLValue.text) ?? .null,
                  item.postedAt.map { .text(Self.sqliteDateString($0)) } ?? .null,
                  .real(item.duration), .text(item.statsJSON), .text(item.source)])
        return rows.first?["id"]?.intValue ?? connection.lastInsertRowID
    }

    func fetchIGMedia(accountID: Int64) throws -> [IGMediaRecord] {
        try connection.query("""
            SELECT * FROM ig_media WHERE account_id = ? ORDER BY posted_at DESC, id DESC
            """, [.integer(accountID)]).map {
            IGMediaRecord(id: $0["id"]?.intValue ?? 0,
                          accountID: $0["account_id"]?.intValue ?? 0,
                          mediaID: $0["media_id"]?.stringValue ?? "",
                          mediaType: $0["media_type"]?.stringValue ?? "reel",
                          caption: $0["caption"]?.stringValue ?? "",
                          permalink: $0["permalink"]?.stringValue,
                          postedAt: Self.parseSQLiteDate($0["posted_at"]?.stringValue),
                          duration: $0["duration"]?.doubleValue ?? 0,
                          thumbnailPath: $0["thumbnail_path"]?.stringValue,
                          localVideoPath: $0["local_video_path"]?.stringValue,
                          statsJSON: $0["stats_json"]?.stringValue ?? "{}",
                          source: $0["source"]?.stringValue ?? "ytdlp",
                          fetchedAt: $0["fetched_at"]?.stringValue)
        }
    }

    /// After a Graph refresh, drop rows for the same reels previously fetched
    /// via the web (same permalink, different media id) — except ones that
    /// already carry a template analysis.
    func pruneSupersededIGMedia(accountID: Int64) throws {
        try connection.execute("""
            DELETE FROM ig_media WHERE account_id = ?1 AND source != 'graph'
                AND id NOT IN (SELECT media_id FROM ig_templates)
                AND permalink IN (SELECT permalink FROM ig_media
                                  WHERE account_id = ?1 AND source = 'graph'
                                    AND permalink IS NOT NULL)
            """, [.integer(accountID)])
    }

    func setIGMediaLocalPaths(id: Int64, thumbnailPath: String?, localVideoPath: String?) throws {
        if let thumbnailPath {
            try connection.execute("UPDATE ig_media SET thumbnail_path = ? WHERE id = ?",
                                   [.text(thumbnailPath), .integer(id)])
        }
        if let localVideoPath {
            try connection.execute("UPDATE ig_media SET local_video_path = ? WHERE id = ?",
                                   [.text(localVideoPath), .integer(id)])
        }
    }

    func saveIGTemplate(mediaID: Int64, templateJSON: String, provider: String?, model: String?) throws {
        try connection.execute("""
            INSERT INTO ig_templates (media_id, template_json, provider, model, analyzed_at)
            VALUES (?, ?, ?, ?, datetime('now'))
            ON CONFLICT(media_id) DO UPDATE SET
                template_json=excluded.template_json,
                provider=excluded.provider,
                model=excluded.model,
                analyzed_at=datetime('now')
            """, [.integer(mediaID), .text(templateJSON),
                  provider.map(SQLValue.text) ?? .null,
                  model.map(SQLValue.text) ?? .null])
    }

    func fetchIGTemplate(mediaID: Int64) throws -> IGTemplateRecord? {
        try connection.query("SELECT * FROM ig_templates WHERE media_id = ?", [.integer(mediaID)]).first.map {
            IGTemplateRecord(id: $0["id"]?.intValue ?? 0,
                             mediaID: $0["media_id"]?.intValue ?? 0,
                             templateJSON: $0["template_json"]?.stringValue ?? "",
                             provider: $0["provider"]?.stringValue,
                             model: $0["model"]?.stringValue,
                             analyzedAt: $0["analyzed_at"]?.stringValue)
        }
    }

    /// IDs of media that already have a cached template analysis.
    func fetchIGTemplateMediaIDs(accountID: Int64) throws -> Set<Int64> {
        let rows = try connection.query("""
            SELECT t.media_id FROM ig_templates t
            JOIN ig_media m ON m.id = t.media_id WHERE m.account_id = ?
            """, [.integer(accountID)])
        return Set(rows.compactMap { $0["media_id"]?.intValue })
    }

    /// Write-through registry entry for a downloaded external video —
    /// honors imported_externals' contract shared with the Python app.
    func registerImportedExternal(platform: String, externalID: String, title: String?,
                                  pageURL: String?, localPath: String?) throws {
        try connection.execute("""
            INSERT OR REPLACE INTO imported_externals (platform, external_id, title, page_url, local_path)
            VALUES (?, ?, ?, ?, ?)
            """, [.text(platform), .text(externalID),
                  title.map(SQLValue.text) ?? .null,
                  pageURL.map(SQLValue.text) ?? .null,
                  localPath.map(SQLValue.text) ?? .null])
    }

    // MARK: - Instagram reports

    /// Live rows replace imported ones; imports never overwrite live data.
    private static func sourceWins(_ table: String) -> String {
        "(excluded.source = 'graph' OR \(table).source = 'import')"
    }

    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    nonisolated static func parseISODate(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = isoFormatter.date(from: string) { return date }
        if let date = graphDateFormatter.date(from: string) { return date }
        return parseSQLiteDate(string)
    }

    /// Graph timestamps use "+0000" without a colon.
    private nonisolated static let graphDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    func upsertIGAccountSnapshots(accountID: Int64, _ snapshots: [IGAccountSnapshot]) throws {
        try connection.transaction {
            for snapshot in snapshots {
                try connection.execute("""
                    INSERT INTO ig_account_snapshots
                        (account_id, snapshot_date, followers_count, follows_count, media_count, source)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, snapshot_date) DO UPDATE SET
                        followers_count=COALESCE(excluded.followers_count, ig_account_snapshots.followers_count),
                        follows_count=COALESCE(excluded.follows_count, ig_account_snapshots.follows_count),
                        media_count=COALESCE(excluded.media_count, ig_account_snapshots.media_count),
                        source=excluded.source
                    WHERE \(Self.sourceWins("ig_account_snapshots"))
                    """, [.integer(accountID), .text(snapshot.date),
                          snapshot.followers.map { .integer(Int64($0)) } ?? .null,
                          snapshot.follows.map { .integer(Int64($0)) } ?? .null,
                          snapshot.mediaCount.map { .integer(Int64($0)) } ?? .null,
                          .text(snapshot.source)])
            }
        }
    }

    @discardableResult
    func upsertIGReportMedia(_ item: IGReportMediaUpsert) throws -> Int64 {
        let rows = try connection.query("""
            INSERT INTO ig_report_media
                (account_id, shortcode, media_id, media_type, media_product_type, caption, caption_truncated,
                 permalink, posted_at, like_count, comments_count, thumbnail_url, source, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(account_id, shortcode) DO UPDATE SET
                media_id=COALESCE(excluded.media_id, ig_report_media.media_id),
                media_type=COALESCE(excluded.media_type, ig_report_media.media_type),
                media_product_type=COALESCE(excluded.media_product_type, ig_report_media.media_product_type),
                caption=CASE WHEN excluded.caption_truncated = 0 OR ig_report_media.caption = ''
                             THEN excluded.caption ELSE ig_report_media.caption END,
                caption_truncated=CASE WHEN excluded.caption_truncated = 0 THEN 0
                                       ELSE ig_report_media.caption_truncated END,
                permalink=COALESCE(excluded.permalink, ig_report_media.permalink),
                posted_at=COALESCE(excluded.posted_at, ig_report_media.posted_at),
                like_count=COALESCE(excluded.like_count, ig_report_media.like_count),
                comments_count=COALESCE(excluded.comments_count, ig_report_media.comments_count),
                thumbnail_url=COALESCE(excluded.thumbnail_url, ig_report_media.thumbnail_url),
                source=CASE WHEN excluded.source = 'graph' THEN 'graph' ELSE ig_report_media.source END,
                fetched_at=datetime('now')
            RETURNING id
            """, [.integer(item.accountID), .text(item.shortcode),
                  item.mediaID.map(SQLValue.text) ?? .null,
                  item.mediaType.map(SQLValue.text) ?? .null,
                  item.productType.map(SQLValue.text) ?? .null,
                  .text(item.caption), .integer(item.captionTruncated ? 1 : 0),
                  item.permalink.map(SQLValue.text) ?? .null,
                  item.postedAt.map { .text(Self.sqliteDateString($0)) } ?? .null,
                  item.likeCount.map { .integer(Int64($0)) } ?? .null,
                  item.commentsCount.map { .integer(Int64($0)) } ?? .null,
                  item.thumbnailURL.map(SQLValue.text) ?? .null,
                  .text(item.source)])
        return rows.first?["id"]?.intValue ?? connection.lastInsertRowID
    }

    func setIGReportMediaThumbnailPath(id: Int64, path: String) throws {
        try connection.execute("UPDATE ig_report_media SET thumbnail_path = ? WHERE id = ?",
                               [.text(path), .integer(id)])
    }

    /// shortcode → row id for the account (imports link by shortcode).
    func fetchIGReportMediaIDs(accountID: Int64) throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        for row in try connection.query("SELECT id, shortcode FROM ig_report_media WHERE account_id = ?",
                                        [.integer(accountID)]) {
            if let shortcode = row["shortcode"]?.stringValue, let id = row["id"]?.intValue {
                map[shortcode] = id
            }
        }
        return map
    }

    /// Graph media id → row id (for the video-analysis sidecars).
    func fetchIGReportMediaGraphIDs(accountID: Int64) throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        for row in try connection.query(
            "SELECT id, media_id FROM ig_report_media WHERE account_id = ? AND media_id IS NOT NULL",
            [.integer(accountID)]) {
            if let mediaID = row["media_id"]?.stringValue, let id = row["id"]?.intValue {
                map[mediaID] = id
            }
        }
        return map
    }

    /// Append insight snapshots. A value identical to the newest stored one
    /// for the same metric is skipped, so history stays compact.
    func insertIGMediaInsightSnapshots(_ snapshots: [IGMediaInsightSnapshot]) throws {
        try connection.transaction {
            for snapshot in snapshots {
                let latest = try connection.query("""
                    SELECT value, fetched_at FROM ig_media_insight_snapshots
                    WHERE report_media_id = ? AND metric = ? ORDER BY fetched_at DESC LIMIT 1
                    """, [.integer(snapshot.reportMediaID), .text(snapshot.metric)]).first
                if let latest, latest["value"]?.doubleValue == snapshot.value,
                   (latest["fetched_at"]?.stringValue ?? "") <= snapshot.fetchedAt {
                    continue
                }
                try connection.execute("""
                    INSERT INTO ig_media_insight_snapshots (report_media_id, metric, value, fetched_at, source)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(report_media_id, metric, fetched_at) DO UPDATE SET
                        value=excluded.value, source=excluded.source
                    WHERE \(Self.sourceWins("ig_media_insight_snapshots"))
                    """, [.integer(snapshot.reportMediaID), .text(snapshot.metric), .real(snapshot.value),
                          .text(snapshot.fetchedAt), .text(snapshot.source)])
            }
        }
    }

    func upsertIGAccountInsights(accountID: Int64, _ rows: [IGAccountInsightRow]) throws {
        try connection.transaction {
            for row in rows {
                try connection.execute("""
                    INSERT INTO ig_account_insights
                        (account_id, metric, period, breakdown_dimension, breakdown_value, value, end_time, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, metric, period, breakdown_dimension, breakdown_value, end_time)
                    DO UPDATE SET value=excluded.value, source=excluded.source
                    WHERE \(Self.sourceWins("ig_account_insights"))
                    """, [.integer(accountID), .text(row.metric), .text(row.period), .text(row.dimension),
                          .text(row.breakdown), .real(row.value), .text(row.endTime), .text(row.source)])
            }
        }
    }

    func upsertIGDemographics(accountID: Int64, _ rows: [IGDemographicRow]) throws {
        try connection.transaction {
            for row in rows {
                try connection.execute("""
                    INSERT INTO ig_audience_demographics
                        (account_id, metric, dimension, dimension_value, timeframe, value, fetched_date, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, metric, dimension, dimension_value, timeframe, fetched_date)
                    DO UPDATE SET value=excluded.value, source=excluded.source
                    WHERE \(Self.sourceWins("ig_audience_demographics"))
                    """, [.integer(accountID), .text(row.metric), .text(row.dimension), .text(row.value),
                          .text(row.timeframe), .integer(Int64(row.count)), .text(row.fetchedDate),
                          .text(row.source)])
            }
        }
    }

    func upsertIGComments(accountID: Int64, _ comments: [IGCommentRecord]) throws {
        try connection.transaction {
            for comment in comments {
                try connection.execute("""
                    INSERT INTO ig_comments
                        (id, account_id, report_media_id, parent_comment_id, username, text, like_count, hidden,
                         timestamp, ref_timestamp, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
                    ON CONFLICT(id) DO UPDATE SET
                        username=COALESCE(excluded.username, ig_comments.username),
                        text=excluded.text, like_count=excluded.like_count, hidden=excluded.hidden,
                        ref_timestamp=COALESCE(excluded.ref_timestamp, ig_comments.ref_timestamp),
                        fetched_at=datetime('now')
                    """, [.text(comment.id), .integer(accountID), .integer(comment.reportMediaID),
                          comment.parentCommentID.map(SQLValue.text) ?? .null,
                          comment.username.map(SQLValue.text) ?? .null,
                          .text(comment.text), .integer(Int64(comment.likeCount)),
                          .integer(comment.hidden ? 1 : 0), .text(Self.iso(comment.timestamp)),
                          comment.refTimestamp.map { .text(Self.iso($0)) } ?? .null])
            }
        }
    }

    func upsertIGCommenterRankingsImport(accountID: Int64, _ ranking: IGImportedRanking) throws {
        try connection.transaction {
            try connection.execute(
                "DELETE FROM ig_commenter_rankings_import WHERE account_id = ? AND period_key = ? AND as_of < ?",
                [.integer(accountID), .text(ranking.periodKey), .text(ranking.asOf)])
            for (index, row) in ranking.rows.enumerated() {
                try connection.execute("""
                    INSERT INTO ig_commenter_rankings_import
                        (account_id, period_key, as_of, username, rank, score, early, text_comments, emoji_comments,
                         text_replies, emoji_replies, total)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, period_key, username) DO UPDATE SET
                        as_of=excluded.as_of, rank=excluded.rank, score=excluded.score, early=excluded.early,
                        text_comments=excluded.text_comments, emoji_comments=excluded.emoji_comments,
                        text_replies=excluded.text_replies, emoji_replies=excluded.emoji_replies,
                        total=excluded.total
                    WHERE excluded.as_of >= ig_commenter_rankings_import.as_of
                    """, [.integer(accountID), .text(ranking.periodKey), .text(ranking.asOf),
                          .text(row.username), .integer(Int64(index + 1)), .integer(Int64(row.score)),
                          .integer(Int64(row.early)), .integer(Int64(row.textComments)),
                          .integer(Int64(row.emojiComments)), .integer(Int64(row.textReplies)),
                          .integer(Int64(row.emojiReplies)), .integer(Int64(row.total))])
            }
        }
    }

    func upsertIGCommenterActivityImport(accountID: Int64, _ activity: IGImportedActivity) throws {
        try connection.transaction {
            try connection.execute(
                "DELETE FROM ig_commenter_activity_import WHERE account_id = ? AND period_key = ? AND as_of < ?",
                [.integer(accountID), .text(activity.periodKey), .text(activity.asOf)])
            for row in activity.rows {
                let posts = (try? JSONSerialization.data(withJSONObject: row.topPosts))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try connection.execute("""
                    INSERT INTO ig_commenter_activity_import
                        (account_id, period_key, as_of, username, comments, replies, total, top_posts_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, period_key, username) DO UPDATE SET
                        as_of=excluded.as_of, comments=excluded.comments, replies=excluded.replies,
                        total=excluded.total, top_posts_json=excluded.top_posts_json
                    WHERE excluded.as_of >= ig_commenter_activity_import.as_of
                    """, [.integer(accountID), .text(activity.periodKey), .text(activity.asOf),
                          .text(row.username), .integer(Int64(row.comments)), .integer(Int64(row.replies)),
                          .integer(Int64(row.total)), .text(posts)])
            }
        }
    }

    func upsertIGHeatmapImport(accountID: Int64, windowEnd: String, counts: [Int]) throws {
        guard counts.count == 168 else { return }
        try connection.transaction {
            for (index, count) in counts.enumerated() {
                try connection.execute("""
                    INSERT OR REPLACE INTO ig_comment_heatmap_import (account_id, window_end, dow, hour, count)
                    VALUES (?, ?, ?, ?, ?)
                    """, [.integer(accountID), .text(windowEnd), .integer(Int64(index / 24)),
                          .integer(Int64(index % 24)), .integer(Int64(count))])
            }
        }
    }

    func upsertIGReelAnalyses(accountID: Int64, _ rows: [IGReelAnalysisRow]) throws {
        func json(_ strings: [String]) -> String {
            (try? JSONSerialization.data(withJSONObject: strings))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        try connection.transaction {
            for row in rows {
                try connection.execute("""
                    INSERT OR REPLACE INTO ig_reel_analysis_import
                        (account_id, report_media_id, analysis_date, score, tier, good_json, bad_json, top_tip)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(accountID), .integer(row.reportMediaID), .text(row.date),
                          .integer(Int64(row.score)), .text(row.tier), .text(json(row.good)),
                          .text(json(row.bad)), row.topTip.map(SQLValue.text) ?? .null])
            }
        }
    }

    func fetchIGIgnoredAccounts(accountID: Int64) throws -> [String] {
        try connection.query(
            "SELECT username FROM ig_ignored_accounts WHERE account_id = ? ORDER BY username COLLATE NOCASE",
            [.integer(accountID)]).compactMap { $0["username"]?.stringValue }
    }

    func addIGIgnoredAccount(accountID: Int64, username: String, reason: String?) throws {
        try connection.execute("""
            INSERT OR IGNORE INTO ig_ignored_accounts (account_id, username, reason) VALUES (?, ?, ?)
            """, [.integer(accountID), .text(username), reason.map(SQLValue.text) ?? .null])
    }

    func removeIGIgnoredAccount(accountID: Int64, username: String) throws {
        try connection.execute("DELETE FROM ig_ignored_accounts WHERE account_id = ? AND username = ?",
                               [.integer(accountID), .text(username)])
    }

    func igSyncState(accountID: Int64) throws -> [String: String] {
        var state: [String: String] = [:]
        for row in try connection.query("SELECT key, value FROM ig_report_sync_state WHERE account_id = ?",
                                        [.integer(accountID)]) {
            if let key = row["key"]?.stringValue, let value = row["value"]?.stringValue { state[key] = value }
        }
        return state
    }

    func setIGSyncState(accountID: Int64, key: String, value: String) throws {
        try connection.execute("""
            INSERT OR REPLACE INTO ig_report_sync_state (account_id, key, value) VALUES (?, ?, ?)
            """, [.integer(accountID), .text(key), .text(value)])
    }

    /// Media rows with insight snapshots, for the sync's "which posts still
    /// need insights" decision: id → newest fetched_at.
    func fetchIGReportMediaInsightDates(accountID: Int64) throws -> [Int64: String] {
        var map: [Int64: String] = [:]
        for row in try connection.query("""
            SELECT s.report_media_id AS id, MAX(s.fetched_at) AS latest
            FROM ig_media_insight_snapshots s JOIN ig_report_media m ON m.id = s.report_media_id
            WHERE m.account_id = ? AND s.source = 'graph' GROUP BY s.report_media_id
            """, [.integer(accountID)]) {
            if let id = row["id"]?.intValue, let latest = row["latest"]?.stringValue { map[id] = latest }
        }
        return map
    }

    /// Everything the report builder needs, in one round trip to the actor.
    func fetchIGReportInputs(account: IGAccountRecord) throws -> IGReportInputs {
        let accountID = account.id
        var inputs = IGReportInputs(account: account)

        inputs.snapshots = try connection.query(
            "SELECT * FROM ig_account_snapshots WHERE account_id = ? ORDER BY snapshot_date",
            [.integer(accountID)]).map {
            IGAccountSnapshot(date: $0["snapshot_date"]?.stringValue ?? "",
                              followers: $0["followers_count"]?.intValue.map(Int.init),
                              follows: $0["follows_count"]?.intValue.map(Int.init),
                              mediaCount: $0["media_count"]?.intValue.map(Int.init),
                              source: $0["source"]?.stringValue ?? "graph")
        }

        var metrics: [Int64: [String: Double]] = [:]
        for row in try connection.query("""
            SELECT s.report_media_id AS id, s.metric, s.value
            FROM ig_media_insight_snapshots s
            JOIN (SELECT report_media_id, metric, MAX(fetched_at) AS latest
                  FROM ig_media_insight_snapshots GROUP BY report_media_id, metric) l
              ON l.report_media_id = s.report_media_id AND l.metric = s.metric AND l.latest = s.fetched_at
            JOIN ig_report_media m ON m.id = s.report_media_id
            WHERE m.account_id = ?
            """, [.integer(accountID)]) {
            guard let id = row["id"]?.intValue, let metric = row["metric"]?.stringValue,
                  let value = row["value"]?.doubleValue else { continue }
            metrics[id, default: [:]][metric] = value
        }
        inputs.media = try connection.query(
            "SELECT * FROM ig_report_media WHERE account_id = ? ORDER BY posted_at DESC, id DESC",
            [.integer(accountID)]).map {
            let id = $0["id"]?.intValue ?? 0
            return IGReportMediaRow(id: id, accountID: accountID,
                                    mediaID: $0["media_id"]?.stringValue,
                                    shortcode: $0["shortcode"]?.stringValue ?? "",
                                    mediaType: $0["media_type"]?.stringValue,
                                    productType: $0["media_product_type"]?.stringValue,
                                    caption: $0["caption"]?.stringValue ?? "",
                                    captionTruncated: $0["caption_truncated"]?.boolValue ?? false,
                                    permalink: $0["permalink"]?.stringValue,
                                    postedAt: Self.parseSQLiteDate($0["posted_at"]?.stringValue),
                                    likeCount: $0["like_count"]?.intValue.map(Int.init),
                                    commentsCount: $0["comments_count"]?.intValue.map(Int.init),
                                    thumbnailURL: $0["thumbnail_url"]?.stringValue,
                                    thumbnailPath: $0["thumbnail_path"]?.stringValue,
                                    source: $0["source"]?.stringValue ?? "graph",
                                    metrics: metrics[id] ?? [:])
        }

        inputs.accountInsights = try connection.query(
            "SELECT * FROM ig_account_insights WHERE account_id = ? ORDER BY end_time",
            [.integer(accountID)]).map {
            IGAccountInsightRow(metric: $0["metric"]?.stringValue ?? "",
                                period: $0["period"]?.stringValue ?? "day",
                                dimension: $0["breakdown_dimension"]?.stringValue ?? "",
                                breakdown: $0["breakdown_value"]?.stringValue ?? "",
                                value: $0["value"]?.doubleValue ?? 0,
                                endTime: $0["end_time"]?.stringValue ?? "",
                                source: $0["source"]?.stringValue ?? "graph")
        }

        inputs.demographics = try connection.query("""
            SELECT d.* FROM ig_audience_demographics d
            JOIN (SELECT metric, dimension, timeframe, MAX(fetched_date) AS latest
                  FROM ig_audience_demographics WHERE account_id = ?1 GROUP BY metric, dimension, timeframe) l
              ON l.metric = d.metric AND l.dimension = d.dimension AND l.timeframe = d.timeframe
                 AND l.latest = d.fetched_date
            WHERE d.account_id = ?1 ORDER BY d.value DESC
            """, [.integer(accountID)]).map {
            IGDemographicRow(metric: $0["metric"]?.stringValue ?? "",
                             dimension: $0["dimension"]?.stringValue ?? "",
                             value: $0["dimension_value"]?.stringValue ?? "",
                             count: Int($0["value"]?.intValue ?? 0),
                             timeframe: $0["timeframe"]?.stringValue ?? "",
                             fetchedDate: $0["fetched_date"]?.stringValue ?? "",
                             source: $0["source"]?.stringValue ?? "graph")
        }

        inputs.comments = try connection.query(
            "SELECT * FROM ig_comments WHERE account_id = ? AND hidden = 0 ORDER BY timestamp",
            [.integer(accountID)]).compactMap {
            guard let timestamp = Self.parseISODate($0["timestamp"]?.stringValue) else { return nil }
            return IGCommentRecord(id: $0["id"]?.stringValue ?? "",
                                   reportMediaID: $0["report_media_id"]?.intValue ?? 0,
                                   parentCommentID: $0["parent_comment_id"]?.stringValue,
                                   username: $0["username"]?.stringValue,
                                   text: $0["text"]?.stringValue ?? "",
                                   likeCount: Int($0["like_count"]?.intValue ?? 0),
                                   hidden: $0["hidden"]?.boolValue ?? false,
                                   timestamp: timestamp,
                                   refTimestamp: Self.parseISODate($0["ref_timestamp"]?.stringValue))
        }

        var rankings: [String: IGImportedRanking] = [:]
        for row in try connection.query(
            "SELECT * FROM ig_commenter_rankings_import WHERE account_id = ? ORDER BY period_key, rank",
            [.integer(accountID)]) {
            let key = row["period_key"]?.stringValue ?? ""
            let entry = IGCommenterRankingRow(username: row["username"]?.stringValue ?? "",
                                              score: Int(row["score"]?.intValue ?? 0),
                                              early: Int(row["early"]?.intValue ?? 0),
                                              textComments: Int(row["text_comments"]?.intValue ?? 0),
                                              emojiComments: Int(row["emoji_comments"]?.intValue ?? 0),
                                              textReplies: Int(row["text_replies"]?.intValue ?? 0),
                                              emojiReplies: Int(row["emoji_replies"]?.intValue ?? 0))
            rankings[key, default: IGImportedRanking(periodKey: key, asOf: row["as_of"]?.stringValue ?? "",
                                                     rows: [])].rows.append(entry)
        }
        inputs.importedRankings = Array(rankings.values)

        var activity: [String: IGImportedActivity] = [:]
        for row in try connection.query(
            "SELECT * FROM ig_commenter_activity_import WHERE account_id = ? ORDER BY period_key, total DESC",
            [.integer(accountID)]) {
            let key = row["period_key"]?.stringValue ?? ""
            let posts = row["top_posts_json"]?.stringValue.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            let entry = IGCommenterActivityRow(username: row["username"]?.stringValue ?? "",
                                               comments: Int(row["comments"]?.intValue ?? 0),
                                               replies: Int(row["replies"]?.intValue ?? 0),
                                               topPosts: posts)
            activity[key, default: IGImportedActivity(periodKey: key, asOf: row["as_of"]?.stringValue ?? "",
                                                      rows: [])].rows.append(entry)
        }
        inputs.importedActivity = Array(activity.values)

        for row in try connection.query(
            "SELECT window_end, dow, hour, count FROM ig_comment_heatmap_import WHERE account_id = ?",
            [.integer(accountID)]) {
            guard let end = row["window_end"]?.stringValue, let dow = row["dow"]?.intValue,
                  let hour = row["hour"]?.intValue, let count = row["count"]?.intValue else { continue }
            var grid = inputs.importedHeatmaps[end] ?? Array(repeating: 0, count: 168)
            let index = Int(dow) * 24 + Int(hour)
            if grid.indices.contains(index) { grid[index] = Int(count) }
            inputs.importedHeatmaps[end] = grid
        }

        inputs.reelAnalyses = try connection.query(
            "SELECT * FROM ig_reel_analysis_import WHERE account_id = ? ORDER BY analysis_date",
            [.integer(accountID)]).map {
            func strings(_ column: String) -> [String] {
                $0[column]?.stringValue.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            }
            return IGReelAnalysisRow(reportMediaID: $0["report_media_id"]?.intValue ?? 0,
                                     date: $0["analysis_date"]?.stringValue ?? "",
                                     score: Int($0["score"]?.intValue ?? 0),
                                     tier: $0["tier"]?.stringValue ?? "",
                                     good: strings("good_json"), bad: strings("bad_json"),
                                     topTip: $0["top_tip"]?.stringValue)
        }

        inputs.ignoredUsernames = Set(try fetchIGIgnoredAccounts(accountID: accountID).map { $0.lowercased() })
        inputs.syncState = try igSyncState(accountID: accountID)
        return inputs
    }

    // MARK: - Helpers

    /// DateFormatter construction is expensive; the formatter is immutable
    /// after setup and documented thread-safe, so share one instance.
    private nonisolated static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    nonisolated static func parseSQLiteDate(_ string: String?) -> Date? {
        string.flatMap { sqliteDateFormatter.date(from: $0) }
    }

    nonisolated static func sqliteDateString(_ date: Date) -> String {
        sqliteDateFormatter.string(from: date)
    }
}
