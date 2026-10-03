import Foundation

extension Database {
    // MARK: - Generated videos

    @discardableResult
    func insertGeneratedVideo(path: String, duration: Double, timelineJSON: String,
                              wizardProvider: String?, wizardModel: String?,
                              projectID: Int64? = nil, selectionTakeID: Int64? = nil,
                              rationale: String? = nil, batchID: String? = nil,
                              qualityJSON: String? = nil,
                              planClipsJSON: String? = nil, settings: WizardRunSettings? = nil, roles: [AIRole] = []) throws -> Int64 {
        // The project may have been deleted while this render ran; the file
        // exists, so record it without an owner (Home shows it) rather than
        // fail the foreign key and lose it.
        var projectID = projectID
        if let id = projectID,
           try connection.query("SELECT 1 FROM projects WHERE id = ?", [.integer(id)]).isEmpty {
            projectID = nil
        }
        // A take can also be deleted while encoding. Keep the rendered output.
        var selectionTakeID = selectionTakeID
        if let id = selectionTakeID,
           try connection.query("SELECT 1 FROM wizard_selection_takes WHERE id = ?", [.integer(id)]).isEmpty {
            selectionTakeID = nil
        }
        try connection.execute("""
            INSERT INTO generated_videos (path, duration, timeline_json, wizard_provider, wizard_model,
                                          project_id, rationale, batch_id, quality_json, plan_clips_json, settings_json, models_json, selection_take_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(path), .real(duration), .text(timelineJSON),
                  wizardProvider.map(SQLValue.text) ?? .null,
                  wizardModel.map(SQLValue.text) ?? .null,
                  projectID.map(SQLValue.integer) ?? .null,
                  rationale.map(SQLValue.text) ?? .null,
                  batchID.map(SQLValue.text) ?? .null,
                  qualityJSON.map(SQLValue.text) ?? .null,
                  planClipsJSON.map(SQLValue.text) ?? .null,
                  settings.flatMap(AISettingsJSON.encode).map(SQLValue.text) ?? .null,
                  AISettingsJSON.encode((AIRunCapture.current?.roles ?? []) + roles).map(SQLValue.text) ?? .null,
                  selectionTakeID.map(SQLValue.integer) ?? .null])
        let recordID = connection.lastInsertRowID
        if wizardProvider != nil, let projectID {
            try ensureWizardTimeline(
                projectID: projectID,
                name: "Wizard · Run",
                documentJSON: timelineJSON,
                sourceRunID: selectionTakeID.map { "take:\($0)" } ?? batchID ?? "video-\(recordID)",
                thumbnailVideoID: nil
            )
        }
        return recordID
    }

    func saveGeneratedTraits(videoID: Int64, traits: PublishedEditTraits) throws {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) -> String {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        try connection.execute("""
            INSERT OR REPLACE INTO generated_video_traits
                (generated_video_id, output_width, output_height, cut_cadence, pace_curve,
                 hook_type, hook_length, people_json, screen_seconds_json, cut_targets_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.integer(videoID), .integer(Int64(traits.outputWidth)),
                  .integer(Int64(traits.outputHeight)), .real(traits.cutCadence),
                  .text(traits.paceCurve), .text(traits.hookType), .real(traits.hookLength),
                  .text(json(traits.peopleKeys)), .text(json(traits.screenSeconds)),
                  .text(json(traits.cutTargets))])
    }

    func fetchGeneratedTraits() throws -> [Int64: PublishedEditTraits] {
        var output: [Int64: PublishedEditTraits] = [:]
        for row in try connection.query("SELECT * FROM generated_video_traits") {
            func decode<T: Decodable>(_ column: String, as: T.Type) -> T? {
                row[column]?.stringValue.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(T.self, from: $0) }
            }
            guard let id = row["generated_video_id"]?.intValue else { continue }
            output[id] = PublishedEditTraits(
                outputWidth: Int(row["output_width"]?.intValue ?? 1080),
                outputHeight: Int(row["output_height"]?.intValue ?? 1920),
                cutCadence: row["cut_cadence"]?.doubleValue ?? 0,
                paceCurve: row["pace_curve"]?.stringValue ?? "steady",
                hookType: row["hook_type"]?.stringValue ?? "unknown",
                hookLength: row["hook_length"]?.doubleValue ?? 0,
                peopleKeys: decode("people_json", as: [String].self) ?? [],
                screenSeconds: decode("screen_seconds_json", as: [String: Double].self) ?? [:],
                cutTargets: decode("cut_targets_json", as: [String: Int].self) ?? [:])
        }
        return output
    }

    /// The newest reel rendered from exactly these inputs, if any is still
    /// on disk. The caller decides whether to reuse it.
    func generatedVideo(projectID: Int64?, renderFingerprint: String) throws -> GeneratedVideoRecord? {
        try fetchGeneratedVideos(projectID: projectID)
            .filter { AISettingsJSON.decode(WizardRunSettings.self, $0.settingsJSON)?.renderFingerprint == renderFingerprint }
            .sorted { ($0.generatedAt ?? "") == ($1.generatedAt ?? "") ? $0.id > $1.id : ($0.generatedAt ?? "") > ($1.generatedAt ?? "") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func fetchGeneratedVideos(projectID: Int64? = nil) throws -> [GeneratedVideoRecord] {
        let projectID = try scopedProjectID(projectID)
        var sql = """
            SELECT g.*, m.stats_json AS instagram_stats_json
            FROM generated_videos g
            LEFT JOIN ig_media m ON m.media_id = g.instagram_media_id
            WHERE COALESCE(g.deleted, 0) = 0
            """
        var parameters: [SQLValue] = []
        if let projectID {
            sql += " AND g.project_id = ?"
            parameters.append(.integer(projectID))
        }
        sql += " ORDER BY g.generated_at DESC, g.id DESC"
        return try connection.query(sql, parameters).map(Self.generatedVideoRecord)
    }

    /// Home is an explicit navigation and timeline container but an implicit
    /// library scope. Passing its id to a scoped fetch is equivalent to no
    /// project filter, while ordinary projects continue through membership.
    func scopedProjectID(_ projectID: Int64?) throws -> Int64? {
        guard let projectID else { return nil }
        return try isHomeProject(projectID) ? nil : projectID
    }

    static func generatedVideoRecord(_ row: SQLRow) -> GeneratedVideoRecord {
        GeneratedVideoRecord(favorite: row["favorite"]?.boolValue ?? false, id: row["id"]?.intValue ?? 0,
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
                             coverModel: row["cover_model"]?.stringValue,
                             projectID: row["project_id"]?.intValue,
                             driveFileID: row["drive_file_id"]?.stringValue,
                             driveLink: row["drive_link"]?.stringValue,
                             driveOffloaded: row["drive_offloaded"]?.boolValue ?? false,
                             driveShared: row["drive_shared"]?.boolValue ?? false,
                             settingsJSON: row["settings_json"]?.stringValue, modelsJSON: row["models_json"]?.stringValue,
                             selectionTakeID: row["selection_take_id"]?.intValue)
    }

    func setGeneratedVideoFavorite(_ id: Int64, favorite: Bool) throws {
        try connection.execute("UPDATE generated_videos SET favorite = ? WHERE id = ?",
                               [.integer(favorite ? 1 : 0), .integer(id)])
    }

    /// Remember the picked cover frame — the Library card renders its
    /// thumbnail at this time from then on. `provenance` is the model that
    /// ranked the frame; nil = a hand pick.
    func updateGeneratedCover(id: Int64, time: Double, provenance: AIProvenance? = nil) throws {
        try recordOutputRole(id: id, role: "Cover", provenance: provenance)
        try connection.execute("""
            UPDATE generated_videos SET cover_time = ?, cover_provider = ?, cover_model = ? WHERE id = ?
            """, [.real(time),
                  provenance.map { SQLValue.text($0.provider) } ?? .null,
                  provenance?.model.map(SQLValue.text) ?? .null,
                  .integer(id)])
    }

    /// Attach the AI critic's post-render review to a generated video.
    func updateGeneratedCritique(id: Int64, critiqueJSON: String) throws {
        let value = AISettingsJSON.decode([String: JSONSetting].self, critiqueJSON)
        try recordOutputRole(id: id, role: "Critique", provenance: AIProvenance(provider: value?["provider"]?.string, model: value?["model"]?.string))
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
        try recordOutputRole(id: id, role: "Captions", provenance: AIProvenance(provider: provider, model: model))
        try connection.execute("""
            UPDATE generated_videos SET caption = ?, caption_provider = ?, caption_model = ? WHERE id = ?
            """, [.text(caption),
                  provider.map(SQLValue.text) ?? .null,
                  model.map(SQLValue.text) ?? .null,
                  .integer(id)])
        if let traits = try reelTraits(kind: "generated", videoID: String(id)) {
            try saveReelTraits(ReelTraitExtractor.applying(caption: caption, to: traits), kind: "generated", videoID: String(id))
        }
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
        for row in try connection.query("SELECT id, text FROM wizard_lessons WHERE learned_id IS NULL") {
            try connection.execute("UPDATE wizard_lessons SET learned_id = ? WHERE id = ?",
                [.text(LearnedPreferences.stableID(row["text"]?.stringValue ?? "")), row["id"] ?? .null])
        }
        return try connection.query("SELECT * FROM wizard_lessons ORDER BY pinned DESC, id").map {
            WizardLesson(learnedID: $0["learned_id"]?.stringValue ?? "",
                         updatedAt: $0["updated_at"]?.stringValue, id: $0["id"]?.intValue ?? 0,
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
        _ = try fetchLessons() // Preserve original-text identity before a rewrite.
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

    /// Local-only fingerprint of the exact feedback inputs consumed by distillLessons.
    func learnedFeedbackFingerprint() throws -> String? {
        var rows: [String] = []
        for table in ["generation_reviews", "clip_reviews", "wizard_preferences", "wizard_feedback"] {
            for row in try connection.query("SELECT * FROM \(table) ORDER BY rowid") {
                rows.append(row.keys.sorted().map { "\($0)=\(String(describing: row[$0]))" }.joined(separator: "|"))
            }
        }
        return rows.isEmpty ? nil : LearnedPreferences.stableID(rows.joined(separator: "\n"))
    }

    func learnedBenchmarks() throws -> AccountBenchmarks? {
        guard let account = try fetchIGAccounts().first(where: \.isOwn) else { return nil }
        return AccountBenchmarks.build(inputs: try fetchIGReportInputs(account: account),
            gridMedia: try fetchIGMedia(accountID: account.id), templates: try fetchIGTemplateLinks(),
            outcomes: try reelOutcomes(accountID: account.id))
    }

    func learnedEvidence() throws -> (reviews: Int, studies: Int, research: [String]) {
        let reviews = try connection.query("SELECT COUNT(*) AS n FROM generation_reviews").first?["n"]?.intValue ?? 0
        let studies = try connection.query("SELECT COUNT(*) AS n FROM taste_studies").first?["n"]?.intValue ?? 0
        let plans = try connection.query("SELECT result_json FROM wizard_research ORDER BY id")
            .compactMap { $0["result_json"]?.stringValue }
        return (Int(reviews), Int(studies), plans)
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
}
