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

    CREATE TABLE IF NOT EXISTS scenes (
        id INTEGER PRIMARY KEY,
        video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        excluded BOOLEAN DEFAULT 0,
        ignored BOOLEAN DEFAULT 0,
        UNIQUE(video_id, start_time, end_time)
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

    CREATE TABLE IF NOT EXISTS ig_templates (
        id INTEGER PRIMARY KEY,
        media_id INTEGER NOT NULL UNIQUE REFERENCES ig_media(id) ON DELETE CASCADE,
        template_json TEXT NOT NULL,
        provider TEXT,
        model TEXT,
        analyzed_at TEXT DEFAULT (datetime('now'))
    );
    """

    init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: path.path)
        try connection.execute("PRAGMA journal_mode=WAL")
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
                                  "caption_model", "wizard_model"]),
            ("videos", ["drive_file_id", "drive_link",
                        "analyzer_provider", "visual_analyzer_provider",
                        "speech_analyzer_provider", "analyzer_model",
                        "visual_analyzer_model", "speech_analyzer_model",
                        "visual_analyzed_at", "speech_analyzed_at"]),
            ("wizard_research", ["provider", "model"]),
            ("transcripts", ["provider", "model", "original_text", "words"]),
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
            speechAnalyzerModel: row["speech_analyzer_model"]?.stringValue)
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
            "SELECT scene_id, AVG(score) AS avg, COUNT(*) AS n FROM grades" + sceneScope + " GROUP BY scene_id",
            scopeParams)
        var gradesByScene: [Int64: (Double, Int)] = [:]
        for row in gradeRows {
            guard let sceneID = row["scene_id"]?.intValue else { continue }
            gradesByScene[sceneID] = (row["avg"]?.doubleValue ?? 0, Int(row["n"]?.intValue ?? 0))
        }

        return sceneRows.map { row in
            let id = row["id"]?.intValue ?? 0
            let grade = gradesByScene[id]
            return SceneRecord(
                id: id,
                videoID: row["video_id"]?.intValue ?? 0,
                startTime: row["start_time"]?.doubleValue ?? 0,
                endTime: row["end_time"]?.doubleValue ?? 0,
                excluded: row["excluded"]?.boolValue ?? false,
                ignored: row["ignored"]?.boolValue ?? false,
                favorite: row["favorite"]?.boolValue ?? false,
                cropXFrac: row["crop_x_frac"]?.doubleValue,
                freeCropsJSON: row["free_crops"]?.stringValue,
                tags: tagsByScene[id]?.sorted() ?? [],
                gradeAverage: grade?.0,
                gradeCount: grade?.1 ?? 0,
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

    func addGrade(sceneID: Int64, score: Int) throws {
        try connection.execute("INSERT INTO grades (scene_id, score) VALUES (?, ?)",
                               [.integer(sceneID), .integer(Int64(score))])
    }

    // MARK: - Analysis results

    /// Persist one analysis pass — mirrors analyzer.py save_analysis():
    /// tag time-ranges become scenes + scene_tags (INSERT OR IGNORE dedup),
    /// moments and analyzed-tag bookkeeping recorded, low-quality scenes
    /// auto-hidden, per-mode timestamps and provider attribution stamped.
    func saveAnalysis(videoID: Int64,
                      tagRanges: [String: [(start: Double, end: Double)]],
                      moments: [(at: Double, note: String, dialog: String?)],
                      analyzedTags: [String],
                      provider: String?, model: String?, mode: String) throws {
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
        try connection.transaction {
            for (_, entry) in rangeTags {
                // The no-op DO UPDATE makes RETURNING yield the id for the
                // pre-existing row too, replacing the insert-then-SELECT pair.
                guard let sceneID = try connection.query("""
                    INSERT INTO scenes (video_id, start_time, end_time)
                    VALUES (?, ?, ?)
                    ON CONFLICT(video_id, start_time, end_time) DO UPDATE SET video_id = video_id
                    RETURNING id
                    """, [.integer(videoID), .real(entry.start), .real(entry.end)]
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
                WHERE s.video_id = ? AND t.tag = 'low-quality'
                """, [.integer(videoID)])
            try connection.execute("""
                UPDATE scenes SET excluded = 1 WHERE video_id = ? AND id IN
                    (SELECT scene_id FROM scene_tags WHERE tag = 'low-quality')
                """, [.integer(videoID)])
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
                              wizardProvider: String?, wizardModel: String?) throws -> Int64 {
        try connection.execute("""
            INSERT INTO generated_videos (path, duration, timeline_json, wizard_provider, wizard_model)
            VALUES (?, ?, ?, ?, ?)
            """, [.text(path), .real(duration), .text(timelineJSON),
                  wizardProvider.map(SQLValue.text) ?? .null,
                  wizardModel.map(SQLValue.text) ?? .null])
        return connection.lastInsertRowID
    }

    func fetchGeneratedVideos() throws -> [GeneratedVideoRecord] {
        try connection.query("SELECT * FROM generated_videos ORDER BY generated_at DESC, id DESC").map {
            GeneratedVideoRecord(id: $0["id"]?.intValue ?? 0,
                                 path: $0["path"]?.stringValue ?? "",
                                 duration: $0["duration"]?.doubleValue ?? 0,
                                 timelineJSON: $0["timeline_json"]?.stringValue ?? "[]",
                                 caption: $0["caption"]?.stringValue ?? "",
                                 generatedAt: $0["generated_at"]?.stringValue,
                                 wizardProvider: $0["wizard_provider"]?.stringValue,
                                 wizardModel: $0["wizard_model"]?.stringValue,
                                 captionProvider: $0["caption_provider"]?.stringValue,
                                 captionModel: $0["caption_model"]?.stringValue)
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

    func deleteGeneratedVideo(id: Int64) throws {
        try connection.execute("DELETE FROM generated_videos WHERE id = ?", [.integer(id)])
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
