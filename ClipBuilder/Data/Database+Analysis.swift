import Foundation

extension Database {
    // MARK: - Scenes

    /// All scenes joined with their video, tags, and grade summary.
    /// One scene by id, with the same tags/grades hydration as the list.
    func fetchScene(id: Int64) throws -> SceneRecord? {
        try fetchScenes(sceneID: id).first
    }

    /// Everything the main window's library state is built from, in one
    /// actor hop, so a refresh is a single round trip instead of nine.
    func fetchLibrarySnapshot(projectID: Int64? = nil) async throws -> LibrarySnapshot {
        let projectID = try scopedProjectID(projectID)
        let videos = try await fetchVideos(projectID: projectID)
        let videoIDs = Set(videos.map(\.id))
        let generatedVideos = try fetchGeneratedVideos(projectID: projectID)
        let generatedIDs = Set(generatedVideos.map(\.id))
        return LibrarySnapshot(videos: videos,
                        scenes: try fetchScenes(projectID: projectID),
                        analysisRuns: try fetchAnalysisRuns().filter { videoIDs.contains($0.videoID) },
                        people: try fetchPeople(),
                        generatedVideos: generatedVideos,
                        feedback: try fetchAllFeedback().filter { generatedIDs.contains($0.generatedVideoID) },
                        lessons: try fetchLessons(),
                        fightResearch: ((try? fetchFightResearch()) ?? []).filter { videoIDs.contains($0.videoID) },
                        fightEvents: ((try? fetchFightEvents()) ?? []).filter { videoIDs.contains($0.videoID) },
                        videoPeopleCounts: try fetchVideoPeopleCounts().filter { videoIDs.contains($0.key) },
                        analysisCheckpoints: try fetchAnalysisCheckpoints().filter { videoIDs.contains($0.key) })
    }

    // MARK: - Analysis checkpoints (interrupted runs)

    func saveAnalysisCheckpoint(_ checkpoint: AnalysisCheckpoint) throws {
        let json = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
        try connection.execute("""
            INSERT INTO analysis_checkpoints (video_id, json, updated_at) VALUES (?, ?, datetime('now'))
            ON CONFLICT(video_id) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at
            """, [.integer(checkpoint.videoID), .text(json)])
    }

    func fetchAnalysisCheckpoint(videoID: Int64) throws -> AnalysisCheckpoint? {
        try fetchAnalysisCheckpoints()[videoID]
    }

    /// Every unfinished analysis, by video. A row that no longer decodes
    /// (an older build's shape) is dropped rather than blocking the run.
    func fetchAnalysisCheckpoints() throws -> [Int64: AnalysisCheckpoint] {
        var result: [Int64: AnalysisCheckpoint] = [:]
        for row in try connection.query("SELECT video_id, json FROM analysis_checkpoints") {
            guard let videoID = row["video_id"]?.intValue, let json = row["json"]?.stringValue,
                  let checkpoint = try? JSONDecoder().decode(AnalysisCheckpoint.self, from: Data(json.utf8))
            else { continue }
            result[videoID] = checkpoint
        }
        return result
    }

    func deleteAnalysisCheckpoint(videoID: Int64) throws {
        try connection.execute("DELETE FROM analysis_checkpoints WHERE video_id = ?", [.integer(videoID)])
    }

    /// Videos whose people-pass roster lists this person, in roster order.
    func fetchVideoIDs(personID: Int64) throws -> [Int64] {
        try connection.query(
            "SELECT video_id FROM video_people WHERE person_id = ? ORDER BY detected_at, video_id",
            [.integer(personID)]).compactMap { $0["video_id"]?.intValue }
    }

    /// Distinct people per video from the people pass.
    func fetchVideoPeopleCounts() throws -> [Int64: Int] {
        var counts: [Int64: Int] = [:]
        for row in try connection.query(
            "SELECT video_id, COUNT(DISTINCT person_id) AS people FROM video_people GROUP BY video_id") {
            if let video = row["video_id"]?.intValue, let people = row["people"]?.intValue { counts[video] = Int(people) }
        }
        return counts
    }

    func fetchScenes(videoID: Int64? = nil, sceneID: Int64? = nil,
                     projectID: Int64? = nil,
                     includeExcluded: Bool = true) throws -> [SceneRecord] {
        let projectID = try scopedProjectID(projectID)
        var sql = """
            SELECT s.*, v.path AS video_path, v.filename AS video_filename,
                   v.duration AS video_duration, v.wide AS video_wide,
                   v.width AS video_width, v.height AS video_height
            FROM scenes s JOIN videos v ON v.id = s.video_id
            """
        var params: [SQLValue] = []
        var conditions: [String] = []
        if let projectID {
            sql += " JOIN project_videos pv ON pv.video_id = s.video_id"
            conditions.append("pv.project_id = ?")
            params.append(.integer(projectID))
        }
        if let videoID {
            conditions.append("s.video_id = ?")
            params.append(.integer(videoID))
        }
        if let sceneID {
            conditions.append("s.id = ?")
            params.append(.integer(sceneID))
        }
        if !includeExcluded {
            conditions.append("s.excluded = 0")
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY v.filename COLLATE NOCASE, s.start_time"
        let sceneRows = try connection.query(sql, params)
        try refreshFootageAvailability()

        // Scope the tag/grade lookups to the filter — otherwise a
        // single-video fetch pays for the whole library's tags and grades.
        let sceneScope: String
        let scopeParams: [SQLValue]
        if let sceneID {
            sceneScope = " WHERE scene_id = ?"
            scopeParams = [.integer(sceneID)]
        } else if let videoID {
            sceneScope = " WHERE scene_id IN (SELECT id FROM scenes WHERE video_id = ?)"
            scopeParams = [.integer(videoID)]
        } else if projectID != nil {
            // Reuse the scene-row predicate, including exclusion filtering.
            sceneScope = " WHERE scene_id IN (SELECT s.id FROM scenes s"
                + " JOIN project_videos pv ON pv.video_id = s.video_id WHERE "
                + conditions.joined(separator: " AND ") + ")"
            scopeParams = params
        } else {
            sceneScope = ""
            scopeParams = []
        }

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
                favoriteProvider: row["favorite_provider"]?.stringValue,
                favoriteModel: row["favorite_model"]?.stringValue,
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
                modelsJSON: row["models_json"]?.stringValue,
                tags: tagsByScene[id]?.sorted() ?? [],
                gradeAverage: grade?.average,
                gradeCount: grade?.count ?? 0,
                lastGrade: grade?.last,
                videoPath: row["video_path"]?.stringValue ?? "",
                videoFilename: row["video_filename"]?.stringValue ?? "",
                videoDuration: row["video_duration"]?.doubleValue ?? 0,
                videoWidth: Int(row["video_width"]?.intValue ?? 0),
                videoHeight: Int(row["video_height"]?.intValue ?? 0),
                wide: row["video_wide"]?.boolValue ?? false,
                sourceAvailable: FootageAvailability.isPresent(path: row["video_path"]?.stringValue))
        }
    }

    func setSceneExcluded(_ sceneID: Int64, excluded: Bool) throws {
        try connection.execute("UPDATE scenes SET excluded = ? WHERE id = ?",
                               [.integer(excluded ? 1 : 0), .integer(sceneID)])
    }

    func setScenesExcluded(_ sceneIDs: [Int64], excluded: Bool) throws {
        guard !sceneIDs.isEmpty else { return }
        try connection.transaction {
            for sceneID in Set(sceneIDs) {
                try setSceneExcluded(sceneID, excluded: excluded)
            }
        }
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
        try recordSceneRole(id: sceneID, role: "Narrative", provenance: AIRunCapture.current?.roles.last(where: { $0.provenance.task == "analysis" })?.provenance)
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

    /// Promote/demote a scene in the favorite set. `provenance` records the
    /// AI Favorites that picked it; nil = the user's own pick (or a demotion).
    func setSceneFavorite(_ sceneID: Int64, favorite: Bool, provenance: AIProvenance? = nil) throws {
        let stamp = favorite ? provenance : nil
        try connection.execute("""
            UPDATE scenes SET favorite = ?, favorite_provider = ?, favorite_model = ? WHERE id = ?
            """, [.integer(favorite ? 1 : 0),
                  stamp.map { SQLValue.text($0.provider) } ?? .null,
                  stamp?.model.map(SQLValue.text) ?? .null,
                  .integer(sceneID)])
    }

    func setScenesFavorite(_ sceneIDs: [Int64], favorite: Bool,
                          provenance: AIProvenance? = nil) throws {
        guard !sceneIDs.isEmpty else { return }
        try connection.transaction {
            for sceneID in Set(sceneIDs) {
                try setSceneFavorite(sceneID, favorite: favorite, provenance: provenance)
            }
        }
    }

    /// Curation trim/extend override (nil clears back to the analyzed range).
    func setSceneEditRange(_ sceneID: Int64, start: Double?, end: Double?) throws {
        try connection.execute("UPDATE scenes SET edit_start = ?, edit_end = ? WHERE id = ?",
                               [start.map(SQLValue.real) ?? .null,
                                end.map(SQLValue.real) ?? .null, .integer(sceneID)])
    }

    /// Center Stage camera path (SceneCameraPath JSON) recorded during
    /// analysis; the scene preview animates it and renders reuse it.
    /// `seconds` is how long the tracking pass took, when the caller timed it.
    func setSceneCenterStagePath(_ sceneID: Int64, json: String?, seconds: TimeInterval? = nil) throws {
        try recordSceneRole(id: sceneID, role: "Framing",
                            provenance: json == nil ? nil : .appleVision(task: "framing", duration: seconds))
        try connection.execute("UPDATE scenes SET center_stage_path = ? WHERE id = ?",
                               [json.map(SQLValue.text) ?? .null, .integer(sceneID)])
    }

    func addGrade(sceneID: Int64, score: Int) throws {
        try connection.execute("INSERT INTO grades (scene_id, score) VALUES (?, ?)",
                               [.integer(sceneID), .integer(Int64(score))])
    }

    func addGrades(sceneIDs: [Int64], score: Int) throws {
        guard !sceneIDs.isEmpty else { return }
        try connection.transaction {
            for sceneID in Set(sceneIDs) {
                try addGrade(sceneID: sceneID, score: score)
            }
        }
    }

    // MARK: - Analysis results

    // MARK: - Analysis runs (batches)

    /// All batches joined with their video and scene count, newest first.
    func fetchAnalysisRuns() throws -> [AnalysisRun] {
        try refreshFootageAvailability()
        return try connection.query("""
            SELECT r.*, v.filename AS video_filename, v.path AS video_path,
                   (SELECT COUNT(*) FROM scenes s WHERE s.run_id = r.id) AS scene_count
            FROM analysis_runs r JOIN videos v ON v.id = r.video_id
            ORDER BY r.created_at DESC, r.sync_id DESC
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
                        sceneCount: Int(row["scene_count"]?.intValue ?? 0),
                        settingsJSON: row["settings_json"]?.stringValue, modelsJSON: row["models_json"]?.stringValue,
                        sourceAvailable: FootageAvailability.isPresent(path: row["video_path"]?.stringValue))
        }
    }

    func renameAnalysisRun(id: Int64, name: String) throws {
        try connection.execute("UPDATE analysis_runs SET name = ? WHERE id = ?",
                               [.text(name), .integer(id)])
    }

    /// Record that this batch's analyze run produced (or kept) a transcript.
    func markAnalysisRunTranscribed(id: Int64) throws {
        let row = try connection.query("SELECT settings_json FROM analysis_runs WHERE id = ?", [.integer(id)]).first
        if var settings = AISettingsJSON.decode(AnalysisRunSettings.self, row?["settings_json"]?.stringValue) {
            settings.includeTranscript = true
            try saveAnalysisSettings(id: id, settings: settings)
        }
        try updateAnalysisModels(id: id)
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
                      provider: String?, model: String?, mode: String,
                      settings: AnalysisRunSettings? = nil, roles: [AIRole] = []) throws -> Int64 {
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
                INSERT INTO analysis_runs (video_id, name, instructions, provider, model, sample_interval, notes_json, settings_json, models_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.integer(videoID), .text(runName), .text(instructions),
                      provider.map(SQLValue.text) ?? .null,
                      model.map(SQLValue.text) ?? .null,
                      .real(sampleInterval ?? 0),
                      notesJSON.map(SQLValue.text) ?? .null,
                      settings.flatMap(AISettingsJSON.encode).map(SQLValue.text) ?? .null,
                      AISettingsJSON.encode((AIRunCapture.current?.roles ?? []) + roles).map(SQLValue.text) ?? .null])
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
}
