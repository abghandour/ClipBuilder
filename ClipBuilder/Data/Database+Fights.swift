import Foundation

extension Database {
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
                             model: row["model"]?.stringValue,
                             targetKey: row["target_key"]?.stringValue,
                             endTime: row["end_time"]?.doubleValue,
                             outcome: row["outcome"]?.stringValue,
                             detail: row["detail"]?.stringValue,
                             scoringVersion: row["scoring_version"]?.intValue.map(Int.init),
                             generation: row["generation"]?.intValue)
        }
    }

    /// A scoring pass replaces the video's whole event list, stamped with
    /// the model that logged the events.
    func replaceFightEvents(videoID: Int64,
                            events: [(time: Double, fighterKey: String,
                                      action: String, points: Double)],
                            provenance: AIProvenance? = nil) throws {
        try replaceFightEventRecords(videoID: videoID, events: events.map {
            FightEventRecord(id: 0, videoID: videoID, time: $0.time, fighterKey: $0.fighterKey,
                             action: $0.action, points: $0.points, provider: provenance?.provider,
                             model: provenance?.model)
        })
    }

    /// The local generation is durable even for a completed pass with zero events.
    func fightEventGeneration(videoID: Int64) throws -> Int64 {
        try connection.query("SELECT generation FROM fight_event_generations WHERE video_id = ?",
                             [.integer(videoID)]).first?["generation"]?.intValue ?? 0
    }

    func isFightEventGenerationCurrent(videoID: Int64, generation: Int64) throws -> Bool {
        try fightEventGeneration(videoID: videoID) == generation
    }

    @discardableResult
    func advanceFightEventGeneration(videoID: Int64) throws -> Int64 {
        let generation = try fightEventGeneration(videoID: videoID) + 1
        try connection.execute("""
            INSERT INTO fight_event_generations(video_id, generation) VALUES (?, ?)
            ON CONFLICT(video_id) DO UPDATE SET generation = excluded.generation
            """, [.integer(videoID), .integer(generation)])
        // Phase E will invalidate local metrics here. No metric table exists in A/B.
        return generation
    }

    @discardableResult
    func replaceFightEventRecords(videoID: Int64, events: [FightEventRecord],
                                  expectedGeneration: Int64? = nil,
                                  roundRanges: [FightRoundRange] = []) throws -> Bool {
        try connection.transaction {
            try Task.checkCancellation()
            if let expectedGeneration,
               try !isFightEventGenerationCurrent(videoID: videoID, generation: expectedGeneration) { return false }
            let generation = try advanceFightEventGeneration(videoID: videoID)
            try connection.execute("DELETE FROM fight_events WHERE video_id = ?", [.integer(videoID)])
            for event in events {
                try connection.execute("""
                    INSERT INTO fight_events (video_id, at_time, fighter_key, action, points, provider, model,
                                              target_key, end_time, outcome, detail, scoring_version, generation)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .real(event.time), .text(event.fighterKey),
                          .text(event.action), .real(event.points), event.provider.map(SQLValue.text) ?? .null,
                          event.model.map(SQLValue.text) ?? .null, event.targetKey.map(SQLValue.text) ?? .null,
                          event.endTime.map(SQLValue.real) ?? .null, event.outcome.map(SQLValue.text) ?? .null,
                          event.detail.map(SQLValue.text) ?? .null,
                          event.scoringVersion.map { .integer(Int64($0)) } ?? .null, .integer(generation)])
            }
            for range in roundRanges {
                // Existing round tags may be editor-supplied; never overwrite them.
                try connection.execute("""
                    INSERT OR IGNORE INTO scene_tags(scene_id, tag)
                    SELECT id, ? FROM scenes WHERE video_id = ? AND start_time >= ? AND end_time <= ?
                    AND NOT EXISTS (SELECT 1 FROM scene_tags WHERE scene_id = scenes.id AND tag LIKE 'round:%')
                    """, [.text("round:\(range.round)"), .integer(videoID), .real(range.start), .real(range.end)])
            }
            return true
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
}
