import Foundation

extension Database {
    // MARK: - Fight events (action scoring)

    func hasFightEvents(videoID: Int64) throws -> Bool {
        try !connection.query("SELECT 1 FROM fight_events WHERE video_id = ? LIMIT 1", [.integer(videoID)]).isEmpty
    }

    /// One indexed lookup per unresolved render source, including negative marks.
    /// No track decoding and no per-clip queries.
    func strikeHighlightStatus(videoID: Int64) throws -> WizardStrikeHighlights.SavedStatus {
        let actions = StrikeStatsSummary.strikeFamily.sorted()
        let placeholders = actions.map { _ in "?" }.joined(separator: ",")
        let row = try connection.query("""
            SELECT EXISTS(SELECT 1 FROM fight_events WHERE video_id = ?) AS has_events,
                   EXISTS(SELECT 1 FROM fight_events WHERE video_id = ? AND action IN (\(placeholders))) AS has_strikes,
                   EXISTS(SELECT 1 FROM strike_highlights WHERE video_id = ? AND rules_version = ?
                          AND generation = COALESCE((SELECT generation FROM fight_event_generations WHERE video_id = ?), 0)) AS has_marks
            """, [.integer(videoID), .integer(videoID)] + actions.map(SQLValue.text)
                + [.integer(videoID), .integer(Int64(StrikeHighlightRules.version)), .integer(videoID)]).first
        return .init(hasFightEvents: row?["has_events"]?.intValue == 1,
                     hasStrikes: row?["has_strikes"]?.intValue == 1,
                     hasSavedRows: row?["has_marks"]?.intValue == 1)
    }

    func fetchFightEvents(videoID: Int64? = nil) throws -> [FightEventRecord] {
        try connection.query("SELECT * FROM fight_events" + (videoID == nil ? "" : " WHERE video_id = ?")
                             + " ORDER BY video_id, at_time", videoID.map { [.integer($0)] } ?? []).map { row in
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

    /// No suspension or sync write can separate the events from their generation.
    func fightEventsForMarking(videoID: Int64) throws -> (events: [FightEventRecord], generation: Int64) {
        try connection.transaction {
            (try fetchFightEvents(videoID: videoID), try fightEventGeneration(videoID: videoID))
        }
    }

    /// Confirm rows and eligible events against the same generation, including
    /// when Team Sync replaces events without a local work claim.
    func strikeHighlightMarkingState(videoID: Int64) throws -> (events: [FightEventRecord], generation: Int64, saved: [StrikeHighlightRecord]) {
        try connection.transaction {
            (try fetchFightEvents(videoID: videoID), try fightEventGeneration(videoID: videoID),
             try fetchStrikeHighlights(videoID: videoID))
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
        try replaceFightEventRecordsReturningGeneration(videoID: videoID, events: events,
            expectedGeneration: expectedGeneration, roundRanges: roundRanges) != nil
    }

    @discardableResult
    func replaceFightEventRecordsReturningGeneration(videoID: Int64, events: [FightEventRecord],
                                                     expectedGeneration: Int64? = nil,
                                                     roundRanges: [FightRoundRange] = []) throws -> Int64? {
        try connection.transaction {
            try Task.checkCancellation()
            if let expectedGeneration,
               try !isFightEventGenerationCurrent(videoID: videoID, generation: expectedGeneration) { return nil }
            let generation = try advanceFightEventGeneration(videoID: videoID)
            try connection.execute("DELETE FROM fight_events WHERE video_id = ?", [.integer(videoID)])
            // The highlights describe the events just removed.
            try connection.execute("DELETE FROM strike_highlights WHERE video_id = ?", [.integer(videoID)])
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
            return generation
        }
    }

    // MARK: - Strike highlights

    /// One actor-isolated snapshot for Express; reads/JSON decoding never run
    /// on the UI actor, and contacts cannot come from another scoring generation.
    func strikeClipStatusSnapshot(videoID: Int64) throws -> StrikeClipStatusRules.Saved {
        try connection.transaction {
            let events = try fetchFightEvents(videoID: videoID)
            let saved = try fetchStrikeHighlights(videoID: videoID)
            return StrikeClipStatusRules.Saved(tracks: saved.compactMap(\.track),
                // The same times the marker hands the engine, unmarked strikes included.
                contacts: saved.map(\.pauseTime).sorted(),
                complete: WizardStrikeHighlights.missingStrikes(events: events, saved: saved).isEmpty)
        }
    }

    /// Contact-only reads never load or decode track_json. One joined query
    /// also gives snapshots all requested videos without a per-video round trip.
    func fetchStrikeContacts(videoIDs: [Int64], overlapping range: ClosedRange<Double>? = nil) throws -> [Int64: [Double]] {
        guard !videoIDs.isEmpty else { return [:] }
        let placeholders = videoIDs.map { _ in "?" }.joined(separator: ",")
        var sql = """
            SELECT h.video_id, h.contact_time FROM strike_highlights h
            LEFT JOIN fight_event_generations g ON g.video_id = h.video_id
            WHERE h.video_id IN (\(placeholders)) AND h.rules_version = ?
            AND h.generation = COALESCE(g.generation, 0) AND h.contact_time IS NOT NULL
            """
        var values = videoIDs.map(SQLValue.integer) + [.integer(Int64(StrikeHighlightRules.version))]
        if let range {
            sql += " AND h.contact_time BETWEEN ? AND ?"
            values += [.real(range.lowerBound), .real(range.upperBound)]
        }
        var result: [Int64: [Double]] = [:]
        for row in try connection.query(sql + " ORDER BY h.video_id, h.contact_time", values) {
            if let id = row["video_id"]?.intValue, let contact = row["contact_time"]?.doubleValue, contact.isFinite {
                result[id, default: []].append(contact)
            }
        }
        return result
    }

    private func strikeHighlight(_ row: [String: SQLValue], videoID: Int64) -> StrikeHighlightRecord {
        StrikeHighlightRecord(
            videoID: videoID, time: row["at_time"]?.doubleValue ?? 0,
            fighterKey: row["fighter_key"]?.stringValue ?? "",
            track: row["track_json"]?.stringValue.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(StrikeHighlightRules.Track.self, from: $0) })
    }

    /// The saved highlights of one video's CURRENT events, including the
    /// strikes where none was found (`track` nil). Rows that describe events
    /// since replaced (a re-score, a sync) or older rules are left out.
    /// `overlapping` keeps the tracks that show inside a source range.
    func fetchStrikeHighlights(videoID: Int64, overlapping range: ClosedRange<Double>? = nil) throws -> [StrikeHighlightRecord] {
        var sql = "SELECT * FROM strike_highlights WHERE video_id = ? AND rules_version = ? AND generation = ?"
        var values: [SQLValue] = [.integer(videoID), .integer(Int64(StrikeHighlightRules.version)),
                                  .integer(try fightEventGeneration(videoID: videoID))]
        if let range {
            // A track lies within a second of its strike's logged time.
            sql += " AND at_time BETWEEN ? AND ?"
            values += [.real(range.lowerBound - 2), .real(range.upperBound + 2)]
        }
        return try connection.query(sql + " ORDER BY at_time", values).map { strikeHighlight($0, videoID: videoID) }
    }

    /// One strike's saved highlight; nil when nothing is saved for it yet.
    func fetchStrikeHighlight(videoID: Int64, time: Double, fighterKey: String,
                              expectedGeneration: Int64? = nil) throws -> StrikeHighlightRecord? {
        let generation = try fightEventGeneration(videoID: videoID)
        if let expectedGeneration, expectedGeneration != generation { return nil }
        return try connection.query("""
            SELECT * FROM strike_highlights WHERE video_id = ? AND rules_version = ? AND generation = ?
            AND fighter_key = ? AND at_time BETWEEN ? AND ? LIMIT 1
            """, [.integer(videoID), .integer(Int64(StrikeHighlightRules.version)),
                  .integer(generation), .text(fighterKey),
                  .real(time - 0.001), .real(time + 0.001)]).first.map { strikeHighlight($0, videoID: videoID) }
    }

    /// Saves highlights found for the events of `generation`. Returns false,
    /// saving nothing, when the events have been replaced since: the work
    /// describes strikes that no longer exist. `replacing` first drops every
    /// row of the video.
    @discardableResult
    func saveStrikeHighlights(videoID: Int64, _ records: [StrikeHighlightRecord], generation: Int64,
                              replacing: Bool = false) throws -> Bool {
        try connection.transaction {
            guard try isFightEventGenerationCurrent(videoID: videoID, generation: generation) else { return false }
            try connection.execute(replacing ? "DELETE FROM strike_highlights WHERE video_id = ?"
                                   : "DELETE FROM strike_highlights WHERE video_id = ? AND generation != \(generation)",
                                   [.integer(videoID)])
            for record in records {
                let json = try record.track.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                try connection.execute("""
                    INSERT OR REPLACE INTO strike_highlights (video_id, at_time, fighter_key, contact_time, track_json, rules_version, generation)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .real(record.time), .text(record.fighterKey),
                          record.track.map { .real($0.contact) } ?? .null, json.map(SQLValue.text) ?? .null,
                          .integer(Int64(StrikeHighlightRules.version)), .integer(generation)])
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
