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
}
