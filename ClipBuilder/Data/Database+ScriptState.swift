import CryptoKit
import Foundation

extension Database {
    // MARK: - Script prerequisites (Library state, outside timeline snapshots)

    func savePrerequisiteResult(kind: BuilderPrerequisiteKind, videoID: Int64,
                                signature: String, outcome: PrerequisiteOutcome) throws {
        let json = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
        try connection.execute("""
            INSERT INTO builder_prerequisites (video_id, kind, signature, outcome_json) VALUES (?, ?, ?, ?)
            ON CONFLICT(video_id, kind) DO UPDATE SET signature = excluded.signature, outcome_json = excluded.outcome_json
            """, [.integer(videoID), .text(kind.rawValue), .text(signature), .text(json)])
    }

    func prerequisiteResult(kind: BuilderPrerequisiteKind, video: VideoRecord,
                            signature: String, language: String) throws -> PrerequisiteOutcome? {
        if let json = try connection.query("""
            SELECT outcome_json FROM builder_prerequisites WHERE video_id = ? AND kind = ? AND signature = ?
            """, [.integer(video.id), .text(kind.rawValue), .text(signature)]).first?["outcome_json"]?.stringValue {
            let outcome = try JSONDecoder().decode(PrerequisiteOutcome.self, from: Data(json.utf8))
            guard outcome.isComplete else { return nil }
            let hasData = try prerequisiteHasData(kind: kind, videoID: video.id, language: language)
            if outcome == .completedEmpty {
                return hasData ? .completedWithData(dataVersion: "legacy:\(video.hash)") : outcome
            }
            return hasData ? outcome : nil
        }
        // Legacy successful data is sufficient. People provenance and completed
        // analysis batches also prove successful empty results; missing rows alone
        // never prove completion for a transcript.
        let hasData = try prerequisiteHasData(kind: kind, videoID: video.id, language: language)
        switch kind {
        case .transcript:
            if hasData { return .completedWithData(dataVersion: "transcript:\(video.hash):\(language)") }
        case .people:
            if let stamp = video.peopleDetectedAt {
                return hasData ? .completedWithData(dataVersion: "people:\(stamp)") : .completedEmpty
            }
        case .analysis:
            if let run = try connection.query("SELECT id FROM analysis_runs WHERE video_id = ? ORDER BY id DESC LIMIT 1",
                                               [.integer(video.id)]).first?["id"]?.intValue,
               video.visualAnalyzedAt != nil {
                return hasData ? .completedWithData(dataVersion: "analysis:\(run)") : .completedEmpty
            }
        }
        return nil
    }

    func prerequisiteHasData(kind: BuilderPrerequisiteKind, videoID: Int64, language: String) throws -> Bool {
        switch kind {
        case .transcript:
            let tag = Locale(identifier: language).language.languageCode?.identifier ?? language
            return try fetchTranscripts(videoID: videoID).contains {
                !$0.isTranslation && (language.isEmpty || $0.language == tag)
            }
        case .people: return try !fetchVideoPeople(videoID: videoID).isEmpty
        case .analysis:
            return try !connection.query("SELECT id FROM scenes WHERE video_id = ? LIMIT 1", [.integer(videoID)]).isEmpty
        }
    }

    /// Reads all potentially affected Library tables in one actor turn. The
    /// fixed SQL list cannot be supplied by a script. Each language/translation
    /// scope is separate so the report states exactly which rows changed.
    func prerequisiteInventory(videoID: Int64) throws -> PrerequisiteInventory {
        var inventory = PrerequisiteInventory()
        nonisolated func fingerprints(_ rows: [SQLRow]) -> [String] {
            rows.map { row in
                let value = row.keys.sorted().map { key in
                    "\(key)=\(String(describing: row[key]))"
                }.joined(separator: "\n")
                return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            }.sorted()
        }
        let transcripts = try connection.query("SELECT * FROM transcripts WHERE video_id = ?", [.integer(videoID)])
        let groups = Dictionary(grouping: transcripts) { row in
            "Transcripts [\(row["language"]?.stringValue ?? ""), translation=\(row["is_translation"]?.boolValue ?? false)]"
        }
        for (scope, rows) in groups { inventory.rows[scope] = fingerprints(rows) }
        for (table, label) in [("transcript_features", "Transcript features"), ("edit_proposals", "Edit proposals"),
                               ("video_people", "Video roster"), ("analysis_runs", "Analysis batches"),
                               ("scenes", "Scenes"), ("speaker_turns", "Speaker turns"), ("topic_ranges", "Topics"),
                               ("moments", "Moments"), ("analyzed_tags", "Analyzed tags"), ("fight_outcomes", "Fight outcomes"),
                               ("builder_prerequisites", "Completion receipts")] {
            inventory.rows[label] = fingerprints(try connection.query("SELECT * FROM \(table) WHERE video_id = ?", [.integer(videoID)]))
        }
        inventory.rows["Shared identities"] = fingerprints(try connection.query("SELECT * FROM people"))
        inventory.rows["Video classification and provenance"] = fingerprints(try connection.query("SELECT * FROM videos WHERE id = ?", [.integer(videoID)]))
        inventory.rows["Scene tags"] = fingerprints(try connection.query("SELECT * FROM scene_tags WHERE scene_id IN (SELECT id FROM scenes WHERE video_id = ?)", [.integer(videoID)]))
        return inventory
    }

    func reelTraits(kind: String, videoID: String, version: Int = ReelTraits.version) throws -> ReelTraits? {
        guard let text = try connection.query("SELECT traits_json FROM reel_traits WHERE video_kind = ? AND video_id = ? AND version = ?",
            [.text(kind), .text(videoID), .integer(Int64(version))]).first?["traits_json"]?.stringValue else { return nil }
        return try JSONDecoder().decode(ReelTraits.self, from: Data(text.utf8))
    }

    func saveReelTraits(_ traits: ReelTraits, kind: String, videoID: String, reference: Bool = false,
                        version: Int = ReelTraits.version) throws {
        try connection.execute("INSERT OR REPLACE INTO reel_traits (video_kind, video_id, version, traits_json, computed_at, reference) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(kind), .text(videoID), .integer(Int64(version)),
             .text(String(decoding: try JSONEncoder().encode(traits), as: UTF8.self)),
             .text(ReportDates.iso(Date())), .integer(reference ? 1 : 0)])
    }

    func reelTraitIsReference(kind: String, videoID: String) throws -> Bool {
        try connection.query("SELECT reference FROM reel_traits WHERE video_kind = ? AND video_id = ?",
            [.text(kind), .text(videoID)]).first?["reference"]?.boolValue ?? false
    }

    func replaceReelOutcomes(accountID: Int64, rows: [ReelOutcome]) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM reel_outcomes WHERE account_id = ?", [.integer(accountID)])
            let own = try connection.query("SELECT kind FROM ig_accounts WHERE id = ?", [.integer(accountID)]).first?["kind"]?.stringValue == "own"
            for row in rows where own && row.accountID == accountID && !row.reference {
                try connection.execute("INSERT INTO reel_outcomes (video_id, account_id, traits_version, outcome_json) VALUES (?, ?, ?, ?)",
                    [.text(row.videoID), .integer(accountID), .integer(Int64(ReelTraits.version)), .text(String(decoding: try JSONEncoder().encode(row), as: UTF8.self))])
            }
        }
    }

    func reelOutcomes(accountID: Int64? = nil) throws -> [ReelOutcome] {
        let rows = try connection.query("SELECT o.outcome_json FROM reel_outcomes o JOIN ig_accounts a ON a.id = o.account_id WHERE a.kind = 'own' AND o.traits_version = \(ReelTraits.version)" + (accountID == nil ? "" : " AND o.account_id = ?"),
            accountID.map { [.integer($0)] } ?? [])
        return try rows.compactMap { row in
            guard let text = row["outcome_json"]?.stringValue else { return nil }
            return try JSONDecoder().decode(ReelOutcome.self, from: Data(text.utf8))
        }.sorted { ($0.postedAt, $0.videoID) < ($1.postedAt, $1.videoID) }
    }

    func rebuildReelOutcomes(account: IGAccountRecord) throws {
        var inputs = try fetchIGReportInputs(account: account)
        // Instagram supplies daily totals, not per-reel medians. Materialize
        // the account's posting-month medians from its own insight snapshots;
        // never substitute daily totals or the month the import happened.
        var monthly: [String: [String: [Double]]] = [:]
        let grid = try fetchIGMedia(accountID: account.id)
        if account.isOwn {
            for media in inputs.media where media.isReel {
                guard let posted = media.postedAt else { continue }
                let month = String(ReportDates.iso(posted).prefix(7))
                let traits = try reelTraits(kind: "imported", videoID: String(media.id))
                let duration = traits?.duration ?? grid.first(where: { $0.mediaID == media.mediaID })?.duration ?? 0
                var raw: [String: Double] = [:]
                raw["saves"] = media.metrics["saved"] ?? media.metrics["saves"]
                raw["shares"] = media.metrics["shares"]
                raw["comments"] = media.metrics["comments"]
                if duration > 0, let watch = media.metrics["ig_reels_avg_watch_time"] {
                    raw["watch_fraction"] = watch / 1000 / duration
                }
                for (metric, value) in raw where value.isFinite && value >= 0 {
                    monthly[month, default: [:]][metric, default: []].append(value)
                }
            }
            try connection.execute("DELETE FROM ig_account_insights WHERE account_id = ? AND source = 'reel-traits'", [.integer(account.id)])
            let medians = monthly.flatMap { month, metrics in
                metrics.map { metric, values in
                    IGAccountInsightRow(metric: "reel_" + metric + "_median", period: "month", dimension: "", breakdown: "",
                        value: ReelTraitExtractor.median(values), endTime: month + "-01T00:00:00Z", source: "reel-traits")
                }
            }
            try upsertIGAccountInsights(accountID: account.id, medians)
            inputs.accountInsights.removeAll { $0.source == "reel-traits" }
            inputs.accountInsights += medians
        }
        var outcomes: [ReelOutcome] = []
        for media in inputs.media where media.isReel {
            guard let traits = try reelTraits(kind: "imported", videoID: String(media.id)),
                  !(try reelTraitIsReference(kind: "imported", videoID: String(media.id))),
                  let row = ReelOutcome.joined(media: media, traits: traits, account: account, insights: inputs.accountInsights) else { continue }
            outcomes.append(row)
        }
        try replaceReelOutcomes(accountID: account.id, rows: outcomes)
    }

    func importedReelFiles() throws -> [(id: String, path: String, videoID: Int64?)] {
        try connection.query("SELECT external_id, local_path, video_id FROM imported_externals WHERE platform = 'instagram' AND local_path IS NOT NULL").compactMap { row in
            guard let id = row["external_id"]?.stringValue, let path = row["local_path"]?.stringValue,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return (id, path, row["video_id"]?.intValue)
        }
    }

    func importedReelPath(externalIDs: [String]) throws -> (path: String, videoID: Int64?)? {
        for id in externalIDs {
            if let row = try connection.query("SELECT local_path, video_id FROM imported_externals WHERE platform = 'instagram' AND external_id = ?", [.text(id)]).first,
               let path = row["local_path"]?.stringValue, FileManager.default.fileExists(atPath: path) {
                return (path, row["video_id"]?.intValue)
            }
        }
        return nil
    }

    func topLiftReelFiles(before cutoff: Date) throws -> [URL] {
        let rows = try reelOutcomes().filter { $0.postedAt <= cutoff && !$0.lift.isEmpty }
            .sorted { ReelTraitExtractor.average(Array($0.lift.values)) > ReelTraitExtractor.average(Array($1.lift.values)) }
        return try rows.prefix(10).compactMap { outcome in
            guard let id = Int64(outcome.videoID),
                  let row = try connection.query("SELECT media_id, shortcode FROM ig_report_media WHERE id = ?", [.integer(id)]).first,
                  let local = try importedReelPath(externalIDs: [row["media_id"]?.stringValue ?? "", row["shortcode"]?.stringValue ?? ""]) else { return nil }
            return URL(fileURLWithPath: local.path)
        }
    }

    func clipModelRows() throws -> [ReelModelRow] {
        let scenes = try fetchScenes(includeExcluded: true)
        var rows: [ReelModelRow] = []
        for scene in scenes {
            var votes: [Double] = []
            if scene.favorite { votes.append(1) }
            if let grade = scene.gradeAverage, scene.gradeCount > 0 { votes.append(grade >= 3 ? 1 : 0) }
            let reviews = try connection.query("SELECT verdict FROM clip_reviews WHERE scene_id = ?", [.integer(scene.id)])
            votes += reviews.compactMap { $0["verdict"]?.intValue }.filter { $0 != 0 }.map { $0 > 0 ? 1 : 0 }
            let proposals = try connection.query("SELECT decision FROM edit_proposals WHERE video_id = ? AND start_time < ? AND end_time > ? AND decision != 'pending'",
                [.integer(scene.videoID), .real(scene.endTime), .real(scene.startTime)])
            // Accepting a proposed CUT means reject this footage, not keep it.
            votes += proposals.compactMap { $0["decision"]?.stringValue }.map { $0 == "accepted" ? 0 : 1 }
            guard !votes.isEmpty else { continue }
            let date = try connection.query("SELECT discovered_at FROM videos WHERE id = ?", [.integer(scene.videoID)]).first?["discovered_at"]?.stringValue
            rows.append(ReelModelRow(id: String(scene.id), date: Self.parseSQLiteDate(date) ?? .distantPast,
                features: ClipRanker.features(scene, traits: try reelTraits(kind: "scene", videoID: SceneTraitExtractor.cacheKey(scene))), targets: ["keep": ReelTraitExtractor.average(votes) >= 0.5 ? 1 : 0]))
        }
        return rows
    }

    func modelPreferencePairs() throws -> [(ReelTraits, ReelTraits)] {
        try connection.query("SELECT chosen_video_id, rejected_video_id FROM wizard_preferences ORDER BY id").compactMap { row in
            guard let chosen = row["chosen_video_id"]?.intValue, let rejected = row["rejected_video_id"]?.intValue,
                  let a = try reelTraits(kind: "generated", videoID: String(chosen)),
                  let b = try reelTraits(kind: "generated", videoID: String(rejected)) else { return nil }
            return (a, b)
        }
    }

    func cachedDetectors(videoID: Int64, fingerprint: String) throws -> VideoDetectors? {
        guard let row = try connection.query("SELECT * FROM video_detectors WHERE video_id = ? AND algorithm_version = ?", [.integer(videoID), .text(fingerprint)]).first,
              let black = row["black_json"]?.stringValue,
              let frozen = row["frozen_json"]?.stringValue,
              let cuts = row["cuts_json"]?.stringValue else { return nil }
        return try VideoDetectors(
            black: JSONDecoder().decode([ClosedRange<Double>].self, from: Data(black.utf8)),
            frozen: JSONDecoder().decode([ClosedRange<Double>].self, from: Data(frozen.utf8)),
            cuts: JSONDecoder().decode([Double].self, from: Data(cuts.utf8)))
    }

    func cacheDetectors(_ detectors: VideoDetectors, videoID: Int64, fingerprint: String) throws {
        let encoder = JSONEncoder()
        try connection.execute("""
            INSERT OR REPLACE INTO video_detectors (video_id, algorithm_version, black_json, frozen_json, cuts_json)
            VALUES (?, ?, ?, ?, ?)
            """, [.integer(videoID), .text(fingerprint),
                  .text(String(decoding: try encoder.encode(detectors.black), as: UTF8.self)),
                  .text(String(decoding: try encoder.encode(detectors.frozen), as: UTF8.self)),
                  .text(String(decoding: try encoder.encode(detectors.cuts), as: UTF8.self))])
    }

    /// "wal" normally; "delete" after the fallback in `init`.
    func journalMode() throws -> String {
        try connection.query("PRAGMA journal_mode").first?.values.first?.stringValue ?? ""
    }

    /// Lazy column migrations mirroring db.py, so old and new columns end up
    /// identical across both apps. One `PRAGMA table_info` per table replaces
    /// the per-column probe statements.
    func fetchBuilderScripts() throws -> [BuilderScriptRecord] {
        try connection.query("SELECT * FROM builder_scripts ORDER BY updated_at DESC,id").map { try BuilderScriptPersistence.read($0) }
    }

    /// No suspension between checking IDs and writing. A regular install only
    /// fills missing IDs; explicit restore resets bundled app-origin rows only.
    func installBuilderScriptExamples(restoring: Bool = false) throws {
        try connection.transaction {
            let existing = Dictionary(uniqueKeysWithValues: try fetchBuilderScripts().map { ($0.id, $0) })
            for example in ScriptExamples.all {
                if let record = existing[example.id], !(restoring && record.origin == .app) { continue }
                try saveBuilderScript(source: example.source, id: example.id, origin: .app)
            }
        }
    }

    @discardableResult
    func saveBuilderScript(source: String, id: UUID = UUID(), origin: BuilderScriptRecord.Origin = .human) throws -> BuilderScriptRecord {
        let header = try ScriptHeader.parse(source)
        let metadata = try header.metadataJSON()
        let now = Date.now.ISO8601Format()
        // One statement: malformed headers/JSON fail before any stored field changes.
        try connection.execute("""
            INSERT INTO builder_scripts (id,name,description,source,params_json,requires_json,mode,origin,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, description=excluded.description, source=excluded.source,
                params_json=excluded.params_json, requires_json=excluded.requires_json,
                mode=excluded.mode, updated_at=excluded.updated_at
            """, [.text(id.uuidString), .text(header.name), .text(header.description), .text(source),
                  .text(metadata.params), .text(metadata.requires), .text(header.mode), .text(origin.rawValue), .text(now), .text(now)])
        guard let row = try connection.query("SELECT * FROM builder_scripts WHERE id=?", [.text(id.uuidString)]).first else {
            throw ScriptError.invalid("Saved script is unavailable.")
        }
        return try BuilderScriptPersistence.read(row)
    }

    func deleteBuilderScript(id: UUID) throws {
        try connection.execute("DELETE FROM builder_scripts WHERE id=?", [.text(id.uuidString)])
    }

    func duplicateBuilderScript(id: UUID) throws -> BuilderScriptRecord {
        guard let row = try connection.query("SELECT * FROM builder_scripts WHERE id=?", [.text(id.uuidString)]).first else {
            throw ScriptError.invalid("Script no longer exists.")
        }
        return try saveBuilderScript(source: BuilderScriptPersistence.read(row).source, origin: .human)
    }

    func importBuilderScript(from url: URL) throws -> BuilderScriptRecord {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
        guard data.count <= 256 * 1024, let source = String(data: data, encoding: .utf8) else {
            throw ScriptError.invalid("Expected a UTF-8 JavaScript file of at most 256 KiB.")
        }
        return try saveBuilderScript(source: source)
    }

    func exportBuilderScript(id: UUID, to url: URL) throws {
        guard let row = try connection.query("SELECT * FROM builder_scripts WHERE id=?", [.text(id.uuidString)]).first else {
            throw ScriptError.invalid("Script no longer exists.")
        }
        try BuilderScriptPersistence.read(row).source.write(to: url, atomically: true, encoding: .utf8)
    }

    func markBuilderScriptRun(id: UUID, status: BuilderRunStatus) throws {
        try connection.execute("UPDATE builder_scripts SET last_run_at=?,last_run_status=? WHERE id=?",
            [.text(Date.now.ISO8601Format()), .text(status.rawValue), .text(id.uuidString)])
    }

    static func migrate(_ connection: SQLiteConnection) throws {
        try connection.executeScript(BuilderScriptPersistence.schema)
        if try !connection.columnNames(of: "timelines").contains("document_revision") {
            try connection.execute("ALTER TABLE timelines ADD COLUMN document_revision INTEGER NOT NULL DEFAULT 0")
        }
        try connection.executeScript("""
            CREATE TABLE IF NOT EXISTS builder_runs (
                run_uuid TEXT PRIMARY KEY,
                timeline_id INTEGER NOT NULL REFERENCES timelines(id) ON DELETE CASCADE,
                request TEXT, created_at TEXT, provider TEXT, model TEXT, duration_seconds REAL,
                status TEXT CHECK(status IN ('completed', 'applied', 'failed', 'discarded', 'reverted')),
                baseline_revision INTEGER, applied_revision INTEGER, summary TEXT,
                library_effects_json TEXT, events_json TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_builder_runs_timeline ON builder_runs(timeline_id, created_at DESC);
            CREATE TABLE IF NOT EXISTS timeline_wizard_before (
                timeline_id INTEGER PRIMARY KEY REFERENCES timelines(id) ON DELETE CASCADE,
                run_uuid TEXT, request TEXT, created_at TEXT, document_json TEXT, applied_revision INTEGER
            );
            """)
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS video_detectors (
                video_id INTEGER PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
                algorithm_version TEXT NOT NULL, black_json TEXT NOT NULL,
                frozen_json TEXT NOT NULL, cuts_json TEXT NOT NULL,
                computed_at TEXT DEFAULT (datetime('now'))
            )
            """)
        let textColumns: [(table: String, columns: [String])] = [
            ("library_asset_metadata", ["display_name", "placements_json", "technique"]),
            ("analysis_runs", ["settings_json", "models_json"]),
            ("generated_videos", ["settings_json", "models_json", "caption", "drive_file_id", "drive_link",
                                  "caption_provider", "wizard_provider",
                                  "caption_model", "wizard_model",
                                  "rationale", "batch_id", "plan_clips_json",
                                  "cover_provider", "cover_model"]),
            ("videos", ["created_at", "drive_file_id", "drive_link",
                        "analyzer_provider", "visual_analyzer_provider",
                        "speech_analyzer_provider", "analyzer_model",
                        "visual_analyzer_model", "speech_analyzer_model",
                        "visual_analyzed_at", "speech_analyzed_at",
                        "video_type", "podcast_layout",
                        "naming_provider", "naming_model",
                        "people_provider", "people_model"]),
            ("wizard_research", ["provider", "model"]),
            ("transcripts", ["provider", "model", "original_text", "words", "technique"]),
            // AI provenance: which provider/model produced each artifact.
            // NULL = human-made (or predates provenance tracking).
            ("scenes", ["models_json", "curated_provider", "curated_model", "favorite_provider", "favorite_model"]),
            ("fight_events", ["provider", "model"]),
            ("video_notes", ["provider", "model"]),
            ("wizard_lessons", ["provider", "model", "learned_id"]),
        ]
        for (table, columns) in textColumns {
            let existing = try connection.columnNames(of: table)
            for column in columns where !existing.contains(column) {
                try connection.execute("ALTER TABLE \(table) ADD COLUMN \(column) TEXT")
            }
        }
        for table in ["videos", "generated_videos"] {
            let columns = try connection.columnNames(of: table)
            for name in ["drive_offloaded", "drive_shared"] where !columns.contains(name) {
                try connection.execute("ALTER TABLE \(table) ADD COLUMN \(name) INTEGER NOT NULL DEFAULT 0")
            }
        }
        try connection.execute("CREATE TABLE IF NOT EXISTS drive_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let sceneColumns = try connection.columnNames(of: "scenes")
        let videoColumns = try connection.columnNames(of: "videos")
        if !videoColumns.contains("podcast_seam_x") {
            try connection.execute("ALTER TABLE videos ADD COLUMN podcast_seam_x REAL")
        }
        if !videoColumns.contains("podcast_layout_confidence") {
            try connection.execute("ALTER TABLE videos ADD COLUMN podcast_layout_confidence REAL")
        }
        if !videoColumns.contains("podcast_tiles_json") {
            try connection.execute("ALTER TABLE videos ADD COLUMN podcast_tiles_json TEXT")
        }
        if !(try connection.columnNames(of: "speaker_turns")).contains("tile") {
            try connection.execute("ALTER TABLE speaker_turns ADD COLUMN tile INTEGER")
        }
        // How long the on-device passes took, for the AI details sheet.
        for column in ["speech_seconds", "people_seconds"] where !videoColumns.contains(column) {
            try connection.execute("ALTER TABLE videos ADD COLUMN \(column) REAL")
        }
        let transcriptColumns = try connection.columnNames(of: "transcripts")
        if !transcriptColumns.contains("seconds") {
            try connection.execute("ALTER TABLE transcripts ADD COLUMN seconds REAL")
        }
        // The user's say on who speaks a line: NULL automatic, '' unknown, else a person key.
        if !transcriptColumns.contains("speaker_key") {
            try connection.execute("ALTER TABLE transcripts ADD COLUMN speaker_key TEXT")
        }
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
        // Role filed by the user (fighter, trainer, press…); NULL = none yet.
        if !peopleColumns.contains("category") {
            try connection.execute("ALTER TABLE people ADD COLUMN category TEXT")
        }
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
        if try !connection.columnNames(of: "timelines").contains("view_state_json") {
            try connection.execute("ALTER TABLE timelines ADD COLUMN view_state_json TEXT")
        }
        let projectColumns = try connection.columnNames(of: "projects")
        if !projectColumns.contains("is_home") {
            try connection.execute("ALTER TABLE projects ADD COLUMN is_home INTEGER NOT NULL DEFAULT 0")
            try connection.transaction {
                try connection.execute("""
                    UPDATE projects
                    SET is_home = 1, name = 'Home', archived = 0
                    WHERE id IN (
                        SELECT MIN(id) FROM projects GROUP BY profile_name
                    )
                    """)
                try connection.execute("""
                    DELETE FROM project_videos
                    WHERE project_id IN (SELECT id FROM projects WHERE is_home = 1)
                    """)
            }
        }
        try connection.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_one_home
            ON projects(profile_name) WHERE is_home = 1
            """)
        let generatedColumns = try connection.columnNames(of: "generated_videos")
        if !generatedColumns.contains("favorite") {
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN favorite INTEGER DEFAULT 0")
        }
        if !generatedColumns.contains("project_id") {
            try connection.execute("ALTER TABLE generated_videos ADD COLUMN project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL")
        }
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
}
