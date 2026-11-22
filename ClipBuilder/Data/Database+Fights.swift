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
                                                     roundRanges: [FightRoundRange] = [],
                                                     kept: [FightSampling.Range] = []) throws -> Int64? {
        try connection.transaction {
            try Task.checkCancellation()
            if let expectedGeneration,
               try !isFightEventGenerationCurrent(videoID: videoID, generation: expectedGeneration) { return nil }
            let corrections = try fetchFightCorrections(videoID: videoID)
            // Rows handed back from the table (a partial retry keeps the
            // stretches it could not score) already carry the corrections.
            let resolution = FightCorrections.resolve(corrections, in: events,
                settled: Set(events.indices.filter { index in
                    events[index].id > 0 && kept.contains { events[index].time >= $0.start && events[index].time < $0.end }
                }), kept: kept)
            let corrected = resolution.events
            var ids: [Int64] = []
            let generation = try advanceFightEventGeneration(videoID: videoID)
            try connection.execute("DELETE FROM fight_events WHERE video_id = ?", [.integer(videoID)])
            // The highlights describe the events just removed.
            try connection.execute("DELETE FROM strike_highlights WHERE video_id = ?", [.integer(videoID)])
            for event in corrected {
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
                ids.append(try connection.query("SELECT last_insert_rowid() AS id").first?["id"]?.intValue ?? 0)
            }
            try bindFightCorrections(corrections, to: resolution.bound.mapValues { ids[$0] }, generation: generation)
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

    // MARK: - Local reviewer corrections

    func fetchFightCorrections(videoID: Int64) throws -> [FightCorrectionRecord] {
        try connection.query("""
            SELECT c.*, o.original_json, o.event_id, o.generation, o.siblings_json, o.added_siblings_json FROM fight_corrections c
            LEFT JOIN fight_correction_originals o ON o.correction_id = c.id
            WHERE c.video_id = ? ORDER BY c.id
            """, [.integer(videoID)]).compactMap { row in
            guard let kind = FightCorrectionRecord.Kind(rawValue: row["kind"]?.stringValue ?? "") else { return nil }
            let original = try row["original_json"]?.stringValue.map {
                try JSONDecoder().decode(FightEventRecord.self, from: Data($0.utf8))
            }
            let event = original ?? FightEventRecord(id: 0, videoID: videoID, time: row["at_time"]?.doubleValue ?? 0,
                fighterKey: row["fighter_key"]?.stringValue ?? "", action: row["action"]?.stringValue ?? "", points: 0)
            var correction = FightCorrectionRecord(event: event, kind: kind)
            correction.id = row["id"]?.intValue ?? 0
            correction.time = row["at_time"]?.doubleValue ?? 0
            correction.fighterKey = row["fighter_key"]?.stringValue ?? ""
            correction.action = row["action"]?.stringValue ?? ""
            correction.detail = row["detail"]?.stringValue
            correction.newTime = row["new_time"]?.doubleValue
            correction.newFighterKey = row["new_fighter_key"]?.stringValue
            correction.newAction = row["new_action"]?.stringValue
            correction.newDetail = row["new_detail"]?.stringValue
            correction.newEndTime = row["new_end_time"]?.doubleValue
            correction.newOutcome = row["new_outcome"]?.stringValue
            correction.newTargetKey = row["new_target_key"]?.stringValue
            correction.createdAt = row["created_at"]?.stringValue
            correction.original = original
            correction.eventID = row["event_id"]?.intValue
            correction.generation = row["generation"]?.intValue
            correction.siblings = try row["siblings_json"]?.stringValue.map {
                try JSONDecoder().decode([FightEventRecord].self, from: Data($0.utf8))
            }
            correction.addedSiblings = try row["added_siblings_json"]?.stringValue.map {
                try JSONDecoder().decode([FightEventRecord].self, from: Data($0.utf8))
            }
            return correction
        }
    }

    @discardableResult
    func saveFightCorrection(_ requested: FightCorrectionRecord) throws -> FightCorrectionRecord {
        try connection.transaction { try applyFightCorrection(requested) }
    }

    /// Inside the caller's transaction.
    private func applyFightCorrection(_ requested: FightCorrectionRecord) throws -> FightCorrectionRecord {
        do {
            try FightCorrections.validate(requested)
            let generation = try fightEventGeneration(videoID: requested.videoID)
            let events = try fetchFightEvents(videoID: requested.videoID)
            let saved = try fetchFightCorrections(videoID: requested.videoID)
            let prior = saved.first { $0.id == requested.id && requested.id != 0 }
                ?? saved.first { $0.eventID != nil && $0.eventID == requested.eventID && $0.generation == generation }
                // A correction that lost its row (a teammate's scoring put the
                // mistake back under a new id) and is made again on that very
                // mistake: the same correction, not a second one.
                // Only for an edit of an edit, and only when the row is in every
                // field what that edit was made on: a confirmation or a
                // removal of the returned row is a decision of its own.
                ?? events.first { $0.id == requested.eventID && requested.kind == .edit }.flatMap { row in
                    saved.first { other in
                        other.kind == .edit && (other.eventID == nil || other.generation != generation)
                            && other.original.map { FightCorrections.sameAction($0, row) } ?? false
                    }
                }
            if requested.id != 0, prior == nil { throw AIError.notConfigured("This correction has changed. Reopen the action and try again.") }
            let eventID = (prior?.generation == generation ? prior?.eventID : nil) ?? requested.eventID
            let current = events.first { $0.id == eventID }
            if requested.kind != .add {
                guard let current, (requested.generation ?? 0) == generation,
                      requested.original.map({ $0 == current }) ?? true else {
                    throw AIError.notConfigured("The fight action changed while you were reviewing it. Select it again.")
                }
            }
            var correction = requested
            if let prior {
                correction = prior
                // A modified user-added action remains an add when the scorer runs again.
                correction.kind = prior.kind == .add && requested.kind != .remove ? .add
                    : requested.kind == .confirm && prior.kind == .edit ? .edit : requested.kind
                correction.setReplacement(FightCorrections.replacement(requested))
            } else if let current {
                correction.original = current
                correction.time = current.time
                correction.fighterKey = current.fighterKey
                correction.action = current.action
                correction.detail = current.detail
            }
            // The popup shows a repeat of one blow, or a submission chain, as
            // one action. Correcting it covers every stored row it stands for.
            let siblings = requested.kind == .confirm ? [] : events.firstIndex { $0.id == current?.id }.map { index in
                FightCorrections.siblings(of: index, in: events).map { events[$0] }
            } ?? []
            // Removing a hand-added event is equivalent to undoing its addition.
            if prior?.kind == .add, requested.kind == .remove {
                if let current {
                    try invalidateCorrectedHighlight(current)
                    try connection.execute("DELETE FROM fight_events WHERE id = ?", [.integer(current.id)])
                }
                try connection.execute("DELETE FROM fight_corrections WHERE id = ?", [.integer(correction.id)])
                // The rest of what the row stood for goes with it, as removals of
                // their own. Without the added row the others may no longer
                // form one action, so each is checked until none is left.
                var remaining = Set(siblings.map(\.id))
                while let next = try fetchFightEvents(videoID: requested.videoID).first(where: { remaining.contains($0.id) }) {
                    remaining.remove(next.id)
                    var removal = FightCorrectionRecord(event: next, kind: .remove)
                    removal.generation = generation
                    _ = try applyFightCorrection(removal)
                }
                return correction
            }
            var removedInOwnRight = Set<Int64>()
            var handAdded = Set<Int64>()
            for sibling in siblings {
                try invalidateCorrectedHighlight(sibling)
                try connection.execute("DELETE FROM fight_events WHERE id = ?", [.integer(sibling.id)])
                // A correction of its own on a row that became part of this action.
                for other in saved where other.eventID == sibling.id && other.generation == generation && other.id != correction.id {
                    if other.kind == .edit {
                        // It would bring the row back at the next scoring. It
                        // becomes a removal in its own right: listed under
                        // Removed, undone on its own, and not part of what
                        // undoing this correction restores.
                        // It removes what the scorer logs, the original: one
                        // form only, so it cannot reach for a second row.
                        let was = other.original
                        try connection.execute("""
                            UPDATE fight_corrections SET kind = 'remove', new_time = at_time, new_fighter_key = fighter_key,
                                new_action = action, new_detail = detail, new_end_time = ?, new_outcome = ?, new_target_key = ?
                            WHERE id = ?
                            """, [was?.endTime.map(SQLValue.real) ?? .null, was?.outcome.map(SQLValue.text) ?? .null,
                                  was?.targetKey.map(SQLValue.text) ?? .null, .integer(other.id)])
                        try connection.execute("UPDATE fight_correction_originals SET event_id = NULL WHERE correction_id = ?",
                                               [.integer(other.id)])
                        removedInOwnRight.insert(sibling.id)
                    } else {
                        if other.kind == .add { handAdded.insert(sibling.id) }
                        try connection.execute("DELETE FROM fight_corrections WHERE id = ?", [.integer(other.id)])
                    }
                }
            }
            // One snapshot per row: a sibling a teammate put back and that is
            // absorbed again must not be restored twice by Undo.
            func distinct(_ rows: [FightEventRecord]) -> [FightEventRecord] {
                rows.reduce(into: [FightEventRecord]()) { kept, row in
                    if !kept.contains(where: { FightCorrections.sameAction($0, row) }) { kept.append(row) }
                }
            }
            correction.siblings = distinct((prior?.siblings ?? []) + siblings.filter { !removedInOwnRight.contains($0.id) })
            // Kept apart from the snapshots: the same action absorbed once as
            // the scorer's row and later as a hand-added one is still hand-added.
            correction.addedSiblings = distinct((prior?.addedSiblings ?? []) + siblings.filter { handAdded.contains($0.id) })
            try connection.execute("""
                INSERT INTO fight_corrections(id, video_id, kind, at_time, fighter_key, action, detail,
                    new_time, new_fighter_key, new_action, new_detail, new_end_time, new_outcome, new_target_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, new_time = excluded.new_time,
                    new_fighter_key = excluded.new_fighter_key, new_action = excluded.new_action,
                    new_detail = excluded.new_detail, new_end_time = excluded.new_end_time,
                    new_outcome = excluded.new_outcome, new_target_key = excluded.new_target_key
                """, [correction.id == 0 ? .null : .integer(correction.id), .integer(correction.videoID),
                      .text(correction.kind.rawValue), .real(correction.time), .text(correction.fighterKey), .text(correction.action),
                      correction.detail.map(SQLValue.text) ?? .null, correction.newTime.map(SQLValue.real) ?? .null,
                      correction.newFighterKey.map(SQLValue.text) ?? .null, correction.newAction.map(SQLValue.text) ?? .null,
                      correction.newDetail.map(SQLValue.text) ?? .null, correction.newEndTime.map(SQLValue.real) ?? .null,
                      correction.newOutcome.map(SQLValue.text) ?? .null, correction.newTargetKey.map(SQLValue.text) ?? .null])
            if correction.id == 0 {
                correction.id = try connection.query("SELECT last_insert_rowid() AS id").first?["id"]?.intValue ?? 0
            }
            var applied: FightEventRecord?
            if correction.kind == .remove {
                if let current { try connection.execute("DELETE FROM fight_events WHERE id = ?", [.integer(current.id)]) }
            } else if correction.kind == .confirm {
                applied = current
            } else if correction.kind == .add, prior == nil,
                      let _ = FightCorrections.index(for: correction, in: events, corrected: true) {
                // It already exists. Do not let Undo of an add delete an AI event.
                throw AIError.notConfigured("An action by this fighter already exists within 0.6 seconds. Edit that action instead.")
            } else {
                var event = FightCorrections.replacement(correction, base: current)
                event.generation = generation
                if let current {
                    event.id = current.id
                    try updateCorrectedFightEvent(event)
                } else { event.id = try insertCorrectedFightEvent(event) }
                applied = event
            }
            if let current { try invalidateCorrectedHighlight(current) }
            if let applied { try invalidateCorrectedHighlight(applied) }
            correction.eventID = applied?.id
            correction.generation = generation
            let original = try correction.original.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            let hidden = try correction.siblings.flatMap { $0.isEmpty ? nil : $0 }.map {
                String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
            }
            let addedHidden = try correction.addedSiblings.flatMap { $0.isEmpty ? nil : $0 }.map {
                String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
            }
            try connection.execute("""
                INSERT INTO fight_correction_originals(correction_id, original_json, event_id, generation, siblings_json,
                    added_siblings_json)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(correction_id) DO UPDATE SET event_id = excluded.event_id, generation = excluded.generation,
                    siblings_json = excluded.siblings_json, added_siblings_json = excluded.added_siblings_json
                """, [.integer(correction.id), original.map(SQLValue.text) ?? .null,
                      correction.eventID.map(SQLValue.integer) ?? .null, .integer(generation),
                      hidden.map(SQLValue.text) ?? .null, addedHidden.map(SQLValue.text) ?? .null])
            return correction
        }
    }

    func deleteFightCorrection(id: Int64, videoID: Int64) throws {
        try connection.transaction {
            guard let correction = try fetchFightCorrections(videoID: videoID).first(where: { $0.id == id }) else { return }
            let generation = try fightEventGeneration(videoID: videoID)
            guard correction.generation == generation else {
                throw AIError.notConfigured("The fight changed on another device. Re-score locally before undoing this correction.")
            }
            let events = try fetchFightEvents(videoID: videoID)
            let current = events.first { $0.id == correction.eventID }
            if correction.kind == .add {
                if let current {
                    try invalidateCorrectedHighlight(current)
                    try connection.execute("DELETE FROM fight_events WHERE id = ?", [.integer(current.id)])
                }
            } else if correction.kind != .confirm, var original = correction.original {
                original.generation = generation
                if let current, events.contains(where: { $0.id != current.id && FightCorrections.sameAction($0, original) }) {
                    // The original is already back as a row of its own (a
                    // teammate's): the corrected row goes, it is not turned
                    // into a second copy.
                    try invalidateCorrectedHighlight(current)
                    try connection.execute("DELETE FROM fight_events WHERE id = ?", [.integer(current.id)])
                } else if let current {
                    try invalidateCorrectedHighlight(current)
                    original.id = current.id
                    try updateCorrectedFightEvent(original)
                } else if !events.contains(where: { FightCorrections.sameAction($0, original) }) {
                    // Not when it is already there: a teammate may have put it back.
                    original.id = try insertCorrectedFightEvent(original)
                }
                try invalidateCorrectedHighlight(original)
            }
            var present = try fetchFightEvents(videoID: videoID)
            let additions = try fetchFightCorrections(videoID: videoID).filter { $0.kind == .add && $0.generation == generation }
            for var sibling in correction.siblings ?? [] {
                // Not a second copy of what is already there (a re-score or a
                // teammate may have put it back); its row is the one to use.
                if let there = present.first(where: { FightCorrections.sameAction($0, sibling) }) {
                    sibling = there
                } else {
                    sibling.generation = generation
                    sibling.id = try insertCorrectedFightEvent(sibling)
                    present.append(sibling)
                }
                // A hand-added row comes back with its addition, or the next
                // scoring would drop it.
                guard (correction.addedSiblings ?? []).contains(where: { FightCorrections.sameAction($0, sibling) }),
                      !additions.contains(where: { $0.eventID == sibling.id }) else { continue }
                try connection.execute("""
                    INSERT INTO fight_corrections(video_id, kind, at_time, fighter_key, action, detail,
                        new_time, new_fighter_key, new_action, new_detail, new_end_time, new_outcome, new_target_key)
                    VALUES (?, 'add', ?, '', '', NULL, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(videoID), .real(sibling.time), .real(sibling.time), .text(sibling.fighterKey),
                          .text(sibling.action), sibling.detail.map(SQLValue.text) ?? .null,
                          sibling.endTime.map(SQLValue.real) ?? .null, sibling.outcome.map(SQLValue.text) ?? .null,
                          sibling.targetKey.map(SQLValue.text) ?? .null])
                let addition = try connection.query("SELECT last_insert_rowid() AS id").first?["id"]?.intValue ?? 0
                try connection.execute("""
                    INSERT INTO fight_correction_originals(correction_id, original_json, event_id, generation)
                    VALUES (?, NULL, ?, ?)
                    """, [.integer(addition), .integer(sibling.id), .integer(generation)])
            }
            try connection.execute("DELETE FROM fight_corrections WHERE id = ? AND video_id = ?", [.integer(id), .integer(videoID)])
        }
    }

    private func invalidateCorrectedHighlight(_ event: FightEventRecord) throws {
        try connection.execute("DELETE FROM strike_highlights WHERE video_id = ? AND at_time = ? AND fighter_key = ?",
                               [.integer(event.videoID), .real(event.time), .text(event.fighterKey)])
    }

    private func updateCorrectedFightEvent(_ event: FightEventRecord) throws {
        // Never replace this row: id, sync_id and generation must stay stable.
        try connection.execute("""
            UPDATE fight_events SET at_time = ?, fighter_key = ?, action = ?, points = ?, detail = ?,
                end_time = ?, outcome = ?, target_key = ?, provider = ?, model = ?, scoring_version = ? WHERE id = ? AND video_id = ?
            """, [.real(event.time), .text(event.fighterKey), .text(event.action), .real(event.points),
                  event.detail.map(SQLValue.text) ?? .null, event.endTime.map(SQLValue.real) ?? .null,
                  event.outcome.map(SQLValue.text) ?? .null, event.targetKey.map(SQLValue.text) ?? .null,
                  event.provider.map(SQLValue.text) ?? .null, event.model.map(SQLValue.text) ?? .null,
                  event.scoringVersion.map { .integer(Int64($0)) } ?? .null, .integer(event.id), .integer(event.videoID)])
    }

    private func insertCorrectedFightEvent(_ event: FightEventRecord) throws -> Int64 {
        // SQLite hands the highest id out again once its row is deleted. A
        // fight pick names its actions by id, so a new action must never take
        // an id a pick (or a correction) still points at.
        let floor = try connection.query("""
            SELECT MAX(m) AS m FROM (
                SELECT MAX(id) AS m FROM fight_events
                UNION ALL SELECT MAX(event_id) FROM fight_correction_originals
                UNION ALL SELECT MAX(CAST(j.value AS INTEGER)) FROM fight_picks, json_each(fight_picks.event_ids) AS j
                    WHERE json_valid(fight_picks.event_ids))
            """).first?["m"]?.intValue ?? 0
        try connection.execute("""
            INSERT INTO fight_events(id, video_id, at_time, fighter_key, action, points, detail, end_time, outcome,
                target_key, provider, model, scoring_version, generation) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.integer(floor + 1), .integer(event.videoID), .real(event.time), .text(event.fighterKey), .text(event.action), .real(event.points),
                  event.detail.map(SQLValue.text) ?? .null, event.endTime.map(SQLValue.real) ?? .null,
                  event.outcome.map(SQLValue.text) ?? .null, event.targetKey.map(SQLValue.text) ?? .null,
                  event.provider.map(SQLValue.text) ?? .null, event.model.map(SQLValue.text) ?? .null,
                  event.scoringVersion.map { .integer(Int64($0)) } ?? .null, event.generation.map(SQLValue.integer) ?? .null])
        return try connection.query("SELECT last_insert_rowid() AS id").first?["id"]?.intValue ?? 0
    }

    private func bindFightCorrections(_ corrections: [FightCorrectionRecord], to rows: [Int64: Int64], generation: Int64) throws {
        for correction in corrections {
            try connection.execute("UPDATE fight_correction_originals SET event_id = ?, generation = ? WHERE correction_id = ?",
                                   [rows[correction.id].map(SQLValue.integer) ?? .null, .integer(generation), .integer(correction.id)])
        }
    }

    /// The sync identity of every row a correction is tied to, read before a
    /// pull and again after it: a row id alone does not survive a deletion.
    func fightCorrectionRowIdentities() throws -> [Int64: String] {
        var result: [Int64: String] = [:]
        for row in try connection.query("""
            SELECT e.id, e.sync_id FROM fight_events e JOIN fight_correction_originals o ON o.event_id = e.id
            """) {
            if let id = row["id"]?.intValue, let identity = row["sync_id"]?.stringValue { result[id] = identity }
        }
        return result
    }

    /// After Team Sync changed a video's events, inside its transaction: the
    /// event generation moved on, so every correction is tied to its row
    /// again. No event is written (see `FightCorrections.rebind`).
    func rebindFightCorrections(videoID: Int64, before: [Int64: String]) throws {
        let corrections = try fetchFightCorrections(videoID: videoID)
        guard !corrections.isEmpty else { return }
        let generation = try fightEventGeneration(videoID: videoID)
        let events = try fetchFightEvents(videoID: videoID)
        let now = try fightCorrectionRowIdentities()
        let places = FightCorrections.rebind(corrections, in: events, boundGeneration: generation - 1,
                                             sameRows: Set(before.filter { now[$0.key] == $0.value }.keys))
        try bindFightCorrections(corrections, to: places.mapValues { events[$0].id }, generation: generation)
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
                              replacing: Bool = false, expectedEvent: FightEventRecord? = nil,
                              expectedEvents: [FightEventRecord]? = nil) throws -> Bool {
        try connection.transaction {
            guard try isFightEventGenerationCurrent(videoID: videoID, generation: generation) else { return false }
            if let expectedEvent,
               try !fetchFightEvents(videoID: videoID).contains(expectedEvent) { return false }
            // A correction changes a strike without a new generation. A track
            // found for what the strike was before must not be saved for it.
            var records = records
            var corrected: [FightEventRecord] = []
            if let expectedEvents {
                let current = try fetchFightEvents(videoID: videoID)
                // What the batch read and is no longer there as read, and what
                // is there now that the batch never read. A highlight row is
                // keyed by time and fighter, so one changed strike at a key
                // puts the whole key out of this batch's hands.
                corrected = expectedEvents.filter { !current.contains($0) } + current.filter { !expectedEvents.contains($0) }
                records = records.filter { record in
                    expectedEvents.contains { record.matches(time: $0.time, fighterKey: $0.fighterKey) }
                        && !corrected.contains { record.matches(time: $0.time, fighterKey: $0.fighterKey) }
                }
            }
            if replacing, !corrected.isEmpty {
                // Replace everything except the highlights saved for those strikes meanwhile.
                for row in try fetchStrikeHighlights(videoID: videoID)
                where !corrected.contains(where: { row.matches(time: $0.time, fighterKey: $0.fighterKey) }) {
                    try connection.execute("DELETE FROM strike_highlights WHERE video_id = ? AND at_time = ? AND fighter_key = ?",
                                           [.integer(videoID), .real(row.time), .text(row.fighterKey)])
                }
            } else {
                try connection.execute(replacing ? "DELETE FROM strike_highlights WHERE video_id = ?"
                                       : "DELETE FROM strike_highlights WHERE video_id = ? AND generation != \(generation)",
                                       [.integer(videoID)])
            }
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
