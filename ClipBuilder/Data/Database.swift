import Foundation
import CryptoKit

// MAP — Database is split by table group. This file keeps the schema,
// migrations, and shared helpers. Queries live in extensions:
//
//   Database+ScriptState.swift   Library state for Builder scripts (outside timeline snapshots)
//   Database+Projects.swift      projects, project timelines
//   Database+Videos.swift        videos, video notes, fight outcomes, person markers, video people,
//                                taste studies, Center Stage hints, voice profiles
//   Database+Analysis.swift      scenes, analysis checkpoints, analysis runs
//   Database+People.swift        people
//   Database+TagFields.swift     cached person tag descriptions
//   Database+Transcripts.swift   transcripts, speaker attribution
//   Database+WizardSelections.swift selections and their saved takes
//   Database+Generated.swift     generated videos, reviews, preferences, lessons, wizard research
//   Database+Fights.swift        fight events, fight research
//   Database+Instagram.swift     Instagram accounts, media, reports
//
// The trailing extensions in this file cover Google Drive media and output roles.

/// One `Database` per brand profile, mirroring db.py: same file layout
/// (`<data>/profiles_db/<Profile>.db`), same schema, same lazy column
/// migrations — so databases created by the Python app open unchanged.
actor Database {
    let connection: SQLiteConnection
    let path: URL
    let creationDates: VideoCreationDates
    var createdDatesBackfilled = false

    static let schema = """
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
        analyzed_at TEXT,
        podcast_layout TEXT,
        podcast_seam_x REAL,
        podcast_layout_confidence REAL,
        podcast_tiles_json TEXT
    );

    CREATE TABLE IF NOT EXISTS builder_prerequisites (
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        signature TEXT NOT NULL,
        outcome_json TEXT NOT NULL,
        PRIMARY KEY (video_id, kind)
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
        favorite_provider TEXT,
        favorite_model TEXT,
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

    CREATE TABLE IF NOT EXISTS transcript_backups (
        video_id INTEGER PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
        json TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS analysis_checkpoints (
        video_id INTEGER PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
        json TEXT NOT NULL,
        updated_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS voice_profiles (
        person_key TEXT NOT NULL,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        vector_json TEXT NOT NULL,
        windows INTEGER NOT NULL,
        correction_windows INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT DEFAULT (datetime('now')),
        PRIMARY KEY (person_key, video_id)
    );

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
        created_at TEXT DEFAULT (datetime('now')),
        category TEXT
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

    CREATE TABLE IF NOT EXISTS wizard_selections (
        id INTEGER PRIMARY KEY,
        project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        recipe TEXT NOT NULL,
        step1_options_json TEXT NOT NULL,
        best_take_id INTEGER REFERENCES wizard_selection_takes(id) ON DELETE SET NULL,
        created_at TEXT DEFAULT (datetime('now')),
        edited_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_wizard_selections_project ON wizard_selections(project_id);

    CREATE TABLE IF NOT EXISTS wizard_selection_takes (
        id INTEGER PRIMARY KEY,
        selection_id INTEGER NOT NULL REFERENCES wizard_selections(id) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        note TEXT,
        plan_json TEXT NOT NULL,
        scene_ids_json TEXT NOT NULL,
        proxy_path TEXT,
        critic_score INTEGER,
        critic_notes TEXT,
        provenance_json TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        UNIQUE(selection_id, ordinal)
    );

    CREATE TABLE IF NOT EXISTS generated_videos (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL,
        duration REAL DEFAULT 0,
        timeline_json TEXT NOT NULL,
        caption TEXT DEFAULT '',
        generated_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS projects (
        id INTEGER PRIMARY KEY,
        profile_name TEXT NOT NULL,
        name TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now')),
        last_opened_at TEXT DEFAULT (datetime('now')),
        archived INTEGER DEFAULT 0,
        is_home INTEGER NOT NULL DEFAULT 0,
        thumbnail_video_id INTEGER REFERENCES videos(id) ON DELETE SET NULL,
        ui_state_json TEXT
    );
    CREATE TABLE IF NOT EXISTS project_videos (
        project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        PRIMARY KEY (project_id, video_id)
    );
    CREATE INDEX IF NOT EXISTS idx_project_videos_video ON project_videos(video_id);

    CREATE TABLE IF NOT EXISTS timelines (
        id INTEGER PRIMARY KEY,
        project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'builder',
        document_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT DEFAULT (datetime('now')),
        edited_at TEXT DEFAULT (datetime('now')),
        source_run_id TEXT,
        thumbnail_video_id INTEGER REFERENCES videos(id) ON DELETE SET NULL,
        view_state_json TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_timelines_project ON timelines(project_id, edited_at DESC);

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

    CREATE TABLE IF NOT EXISTS speaker_turns (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        cluster INTEGER NOT NULL,
        confidence REAL NOT NULL DEFAULT 0,
        picture_side TEXT,
        picture_confidence REAL NOT NULL DEFAULT 0,
        resolved_side TEXT,
        person_key TEXT,
        tile INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_speaker_turns_video_time
        ON speaker_turns(video_id, start_time, end_time);

    CREATE TABLE IF NOT EXISTS transcript_features (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        speaker_key TEXT,
        energy REAL NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT 'speech'
    );
    CREATE INDEX IF NOT EXISTS idx_transcript_features_video_time
        ON transcript_features(video_id, start_time, end_time);

    CREATE TABLE IF NOT EXISTS topic_ranges (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        summary TEXT NOT NULL DEFAULT '',
        speaker_keys_json TEXT NOT NULL DEFAULT '[]'
    );
    CREATE INDEX IF NOT EXISTS idx_topic_ranges_video ON topic_ranges(video_id, start_time);

    CREATE TABLE IF NOT EXISTS edit_proposals (
        id INTEGER PRIMARY KEY,
        video_id INTEGER REFERENCES videos(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        reason TEXT NOT NULL DEFAULT '',
        decision TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_edit_proposals_video ON edit_proposals(video_id, start_time);

    CREATE TABLE IF NOT EXISTS library_asset_metadata (
        path TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        is_broll INTEGER NOT NULL DEFAULT 0,
        subjects_json TEXT NOT NULL DEFAULT '[]',
        tags_json TEXT NOT NULL DEFAULT '[]',
        provider TEXT,
        model TEXT,
        analyzed_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS reel_traits (
        video_kind TEXT NOT NULL,
        video_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        traits_json TEXT NOT NULL,
        computed_at TEXT NOT NULL,
        reference INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (video_kind, video_id)
    );
    CREATE TABLE IF NOT EXISTS reel_outcomes (
        video_id TEXT PRIMARY KEY,
        account_id INTEGER NOT NULL REFERENCES ig_accounts(id) ON DELETE CASCADE,
        traits_version INTEGER NOT NULL,
        outcome_json TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS generated_video_traits (
        generated_video_id INTEGER PRIMARY KEY REFERENCES generated_videos(id) ON DELETE CASCADE,
        output_width INTEGER NOT NULL,
        output_height INTEGER NOT NULL,
        cut_cadence REAL NOT NULL,
        pace_curve TEXT NOT NULL,
        hook_type TEXT NOT NULL,
        hook_length REAL NOT NULL,
        people_json TEXT NOT NULL,
        screen_seconds_json TEXT NOT NULL,
        cut_targets_json TEXT NOT NULL
    );

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
    CREATE INDEX IF NOT EXISTS idx_scenes_run ON scenes(run_id);
    CREATE INDEX IF NOT EXISTS idx_scene_tags_tag ON scene_tags(tag);
    CREATE INDEX IF NOT EXISTS idx_fight_events_video ON fight_events(video_id);
    CREATE INDEX IF NOT EXISTS idx_person_markers_person ON person_markers(person_id);
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

    init(path: URL, creationDates: VideoCreationDates = VideoCreationDates()) throws {
        self.creationDates = creationDates
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
        // WAL is durable across crashes at NORMAL; FULL adds an fsync per
        // autocommit, which the per-row sync writes paid dearly for.
        try? connection.execute("PRAGMA synchronous=NORMAL")
        try connection.execute("PRAGMA foreign_keys=ON")
        try connection.executeScript(Self.schema)
        // The lazy column migrations probe every table (a `PRAGMA
        // table_info` each) and can rebuild `scenes` wholesale, all
        // synchronously before the first frame. A database stamped with the
        // current version has already been through them.
        let stamped = try connection.query("PRAGMA user_version").first?.values.first?.intValue ?? 0
        if stamped != Self.schemaVersion {
            try Self.migrate(connection)
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS person_tag_fields (
                    person_key TEXT NOT NULL REFERENCES people(key) ON DELETE CASCADE ON UPDATE CASCADE,
                    field TEXT NOT NULL,
                    value TEXT NOT NULL,
                    provenance TEXT,
                    PRIMARY KEY (person_key, field)
                )
                """)
            if try !connection.columnNames(of: "wizard_selections").contains("mini_batch") {
                try connection.execute("ALTER TABLE wizard_selections ADD COLUMN mini_batch TEXT")
            }
            if try !connection.columnNames(of: "generated_videos").contains("selection_take_id") {
                try connection.execute("ALTER TABLE generated_videos ADD COLUMN selection_take_id INTEGER REFERENCES wizard_selection_takes(id) ON DELETE SET NULL")
            }
            try connection.transaction { [connection] in
                if stamped < 16 {
                    try connection.execute("UPDATE scenes SET favorite = 1, favorite_provider = curated_provider, favorite_model = curated_model WHERE curated = 1 AND favorite = 0")
                    try connection.execute("UPDATE scenes SET favorite_provider = curated_provider, favorite_model = curated_model WHERE curated = 1 AND favorite = 1 AND favorite_provider IS NULL")
                }
                try Self.migrateTeamSync(connection)
                try connection.execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
        }
    }

    /// Bump whenever `migrate` gains a step, so existing databases run it
    /// once more; the `CREATE … IF NOT EXISTS` schema script always runs.
    static let schemaVersion: Int64 = 24

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

// MARK: - Google Drive (media only; profile preferences stay in this local DB)
extension Database {
    func driveSetting(_ key: String) throws -> String? {
        try connection.query("SELECT value FROM drive_settings WHERE key = ?", [.text(key)]).first?["value"]?.stringValue
    }

    func setDriveSetting(_ key: String, value: String) throws {
        try connection.execute("INSERT INTO drive_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                               [.text(key), .text(value)])
    }

    func driveSource(fileID: String) throws -> VideoRecord? {
        try connection.query("SELECT * FROM videos WHERE drive_file_id = ? LIMIT 1", [.text(fileID)])
            .first.map(Self.videoRecord)
    }

    func driveMedia(path: String) throws -> DriveMedia? {
        if let row = try connection.query("SELECT * FROM videos WHERE path = ? AND drive_file_id IS NOT NULL LIMIT 1", [.text(path)]).first {
            return Self.videoRecord(row).driveMedia
        }
        return try connection.query("SELECT * FROM generated_videos WHERE path = ? AND drive_file_id IS NOT NULL LIMIT 1", [.text(path)])
            .first.map { Self.generatedVideoRecord($0).driveMedia }
    }

    func setDriveCopy(_ media: DriveMedia, file: DriveFile) throws {
        let table = media.kind == .source ? "videos" : "generated_videos"
        try connection.execute("UPDATE \(table) SET drive_file_id = ?, drive_link = ?, drive_shared = ?, drive_offloaded = 0 WHERE id = ?",
                               [.text(file.id), .text(file.link), .integer(file.isShared ? 1 : 0), .integer(media.recordID)])
    }

    func setDriveOffloaded(_ media: DriveMedia, _ value: Bool) throws {
        let table = media.kind == .source ? "videos" : "generated_videos"
        try connection.execute("UPDATE \(table) SET drive_offloaded = ? WHERE id = ? AND drive_file_id IS NOT NULL",
                               [.integer(value ? 1 : 0), .integer(media.recordID)])
    }
}

// MARK: - Captured AI run details
extension Database {
    func saveAnalysisSettings(id: Int64, settings: AnalysisRunSettings) throws {
        var settings = settings
        settings.modelPrompts = AIRunCapture.current?.prompts ?? settings.modelPrompts
        try connection.execute("UPDATE analysis_runs SET settings_json = ? WHERE id = ?",
                               [AISettingsJSON.encode(settings).map(SQLValue.text) ?? .null, .integer(id)])
    }

    func updateAnalysisModels(id: Int64) throws {
        let row = try connection.query("SELECT video_id FROM analysis_runs WHERE id = ?", [.integer(id)]).first
        let video = try row?["video_id"]?.intValue.flatMap { try self.video(id: $0) }
        let existing = try connection.query("SELECT models_json FROM analysis_runs WHERE id = ?", [.integer(id)]).first
        var roles = AISettingsJSON.decode([AIRole].self, existing?["models_json"]?.stringValue) ?? []
        for role in AIRunCapture.current?.roles ?? [] where !roles.contains(role) { roles.append(role) }
        if let video {
            for (role, value) in [("Transcript", video.transcriptionProvenance), ("People", video.peopleProvenance), ("Naming", video.namingProvenance)] {
                if let value { roles.append(AIRole(role: role, provenance: value)) }
            }
        }
        try connection.execute("UPDATE analysis_runs SET models_json = ? WHERE id = ?", [AISettingsJSON.encode(roles).map(SQLValue.text) ?? .null, .integer(id)])
    }

    func recordSceneRole(id: Int64, role: String, provenance: AIProvenance?) throws {
        guard var provenance else { return }
        if provenance.at == nil { provenance.at = Date() }
        let row = try connection.query("SELECT models_json FROM scenes WHERE id = ?", [.integer(id)]).first
        var roles = AISettingsJSON.decode([AIRole].self, row?["models_json"]?.stringValue) ?? []
        roles.removeAll { $0.role == role }
        roles.append(AIRole(role: role, provenance: provenance))
        try connection.execute("UPDATE scenes SET models_json = ? WHERE id = ?",
                               [AISettingsJSON.encode(roles).map(SQLValue.text) ?? .null, .integer(id)])
    }

    func recordOutputRole(id: Int64, role: String, provenance: AIProvenance?) throws {
        guard var provenance else { return }
        if provenance.at == nil { provenance.at = Date() }
        let row = try connection.query("SELECT models_json, settings_json FROM generated_videos WHERE id = ?", [.integer(id)]).first
        var roles = AISettingsJSON.decode([AIRole].self, row?["models_json"]?.stringValue) ?? []
        roles.removeAll { $0.role == role }
        roles.append(AIRole(role: role, provenance: provenance))
        if var settings = AISettingsJSON.decode(WizardRunSettings.self, row?["settings_json"]?.stringValue),
           let prompts = AIRunCapture.current?.prompts {
            settings.modelPrompts.merge(prompts) { _, new in new }
            try connection.execute("UPDATE generated_videos SET settings_json = ? WHERE id = ?",
                                   [AISettingsJSON.encode(settings).map(SQLValue.text) ?? .null, .integer(id)])
        }
        try connection.execute("UPDATE generated_videos SET models_json = ? WHERE id = ?",
                               [AISettingsJSON.encode((AIRunCapture.current?.roles ?? []) + roles).map(SQLValue.text) ?? .null, .integer(id)])
    }
}
