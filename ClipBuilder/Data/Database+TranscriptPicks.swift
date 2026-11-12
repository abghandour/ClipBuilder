import Foundation

extension Database {
    static let transcriptPickTag = "transcript-pick"

    /// The video's picks in this project, plus legacy picks no project owns
    /// yet. `projectID == nil` reads every project's picks (id lookups).
    /// With a project, only picks of the active transcript set (see
    /// `activeSetPickPredicate`).
    func fetchTranscriptPicks(projectID: Int64?, videoID: Int64) throws -> [TranscriptPick] {
        guard let projectID else {
            return try connection.query("SELECT * FROM transcript_picks WHERE video_id = ? ORDER BY position, id",
                                        [.integer(videoID)]).map(Self.transcriptPick)
        }
        return try connection.query("""
            SELECT * FROM transcript_picks WHERE video_id = ? AND (project_id = ? OR project_id IS NULL)
                AND \(Self.activeSetPickPredicate)
            ORDER BY position, id
            """, [.integer(videoID), .integer(projectID)]).map(Self.transcriptPick)
    }

    /// What Express's Transcript tab shows, read in one call: the active
    /// set's key, its rows and the picks made on it. Read apart, a pin
    /// changed in between would pair one set's picks with another's key,
    /// and the shown-set guard would then pass writes aimed at the wrong list.
    func expressTranscript(projectID: Int64, videoID: Int64) throws -> (setKey: String?, rows: [TranscriptRow], picks: [TranscriptPick]) {
        try connection.transaction {
            let key = try activeTranscription(videoID: videoID).key
            return (key, try fetchTranscripts(videoID: videoID, transcriptionKey: key),
                    try fetchTranscriptPicks(projectID: projectID, videoID: videoID))
        }
    }

    /// A pick belongs to the list unless it was made on another transcript
    /// set that still exists. Picks with no recorded set, or whose set was
    /// deleted, stay visible: unknown provenance is not wrong provenance.
    static let activeSetPickPredicate = """
        (transcript_picks.transcription_key IS NULL
            OR transcript_picks.transcription_key IS (\(resolvedTranscriptionKeySQL(videoID: "transcript_picks.video_id")))
            OR NOT EXISTS (SELECT 1 FROM transcripts t WHERE t.video_id = transcript_picks.video_id
                AND t.transcription_key = transcript_picks.transcription_key))
        """

    /// How many of the video's picks in this project each other transcript
    /// set holds: the ones `activeSetPickPredicate` keeps off the list. A
    /// teammate's picks arrive stamped with the set they were made on, which
    /// need not be the one in use on this Mac.
    func transcriptPickCountsOnOtherSets(projectID: Int64, videoID: Int64) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try connection.query("""
            SELECT transcription_key AS set_key, COUNT(*) AS n FROM transcript_picks
            WHERE video_id = ? AND (project_id = ? OR project_id IS NULL) AND NOT \(Self.activeSetPickPredicate)
            GROUP BY transcription_key
            """, [.integer(videoID), .integer(projectID)]) {
            if let key = row["set_key"]?.stringValue, let n = row["n"]?.intValue { counts[key] = Int(n) }
        }
        return counts
    }

    /// The set the caller's screen shows must still be the active one:
    /// the lists below are read through it, and a pin changed elsewhere
    /// (Team Sync, the Transcript sheet) would aim a write at picks the
    /// user is not looking at. Returns the set to stamp new picks with.
    private func requireShownSet(_ set: TranscriptPickSet, videoID: Int64) throws -> String? {
        let active = try activeTranscription(videoID: videoID).key
        if case .shown(let shown) = set, shown != active { throw TranscriptPickSetError.changed }
        return active
    }

    /// Before the active set changes: picks nobody stamped (and picks of a
    /// deleted set) were made on the set in use now, so they stay with it.
    func claimTranscriptPicks(videoID: Int64, key: String) throws {
        try connection.execute("""
            UPDATE transcript_picks SET transcription_key = ? WHERE video_id = ?
                AND (transcription_key IS NULL
                    OR NOT EXISTS (SELECT 1 FROM transcripts t WHERE t.video_id = transcript_picks.video_id
                        AND t.transcription_key = transcript_picks.transcription_key))
            """, [.text(key), .integer(videoID)])
    }

    /// Legacy picks (from before picks were per project) join the first
    /// project that writes to the video's list.
    private func adoptLegacyTranscriptPicks(projectID: Int64, videoID: Int64) throws {
        try connection.execute("UPDATE transcript_picks SET project_id = ? WHERE video_id = ? AND project_id IS NULL",
                               [.integer(projectID), .integer(videoID)])
    }

    private func adoptLegacyTranscriptPicks(projectID: Int64, pickID: Int64) throws {
        guard let videoID = try connection.query("SELECT video_id FROM transcript_picks WHERE id = ?",
                                                 [.integer(pickID)]).first?["video_id"]?.intValue else { return }
        try adoptLegacyTranscriptPicks(projectID: projectID, videoID: videoID)
    }

    /// Appends at the end of the list. `kept` is false for the half of a split
    /// unchecked pick.
    func addTranscriptPick(projectID: Int64, videoID: Int64, start: Double, end: Double, kept: Bool = true,
                           set: TranscriptPickSet = .active) throws -> TranscriptPick {
        try connection.transaction {
            let setKey = try requireShownSet(set, videoID: videoID)
            try adoptLegacyTranscriptPicks(projectID: projectID, videoID: videoID)
            let position = (try connection.query(
                "SELECT MAX(position) AS n FROM transcript_picks WHERE video_id = ? AND project_id = ?",
                [.integer(videoID), .integer(projectID)]).first?["n"]?.intValue ?? -1) + 1
            try connection.execute("""
                INSERT INTO transcript_picks (video_id, project_id, position, start_time, end_time, original_start, original_end, kept, transcription_key)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.integer(videoID), .integer(projectID), .integer(position), .real(start), .real(end),
                      .real(start), .real(end), .integer(kept ? 1 : 0), setKey.map(SQLValue.text) ?? .null])
            let id = connection.lastInsertRowID
            guard let pick = try transcriptPick(id: id) else { throw WizardSelectionError.missingSelection }
            return pick
        }
    }

    /// Split: the pick keeps `start...time` and a new pick with
    /// `time...end` lands at `index` of `order`, all or nothing. In separate
    /// writes, a set change between them left only the shortened half.
    func splitTranscriptPick(projectID: Int64, videoID: Int64, id: Int64, start: Double, at time: Double, end: Double,
                             kept: Bool, order: [Int64], index: Int, set: TranscriptPickSet) throws -> TranscriptPick {
        try connection.transaction {
            let setKey = try requireShownSet(set, videoID: videoID)
            try adoptLegacyTranscriptPicks(projectID: projectID, videoID: videoID)
            guard try !connection.query("SELECT 1 FROM transcript_picks WHERE id = ? AND project_id = ?",
                                        [.integer(id), .integer(projectID)]).isEmpty else {
                throw WizardSelectionError.missingSelection
            }
            try connection.execute("UPDATE transcript_picks SET start_time = ?, end_time = ? WHERE id = ? AND project_id = ?",
                                   [.real(start), .real(time), .integer(id), .integer(projectID)])
            try connection.execute("""
                INSERT INTO transcript_picks (video_id, project_id, position, start_time, end_time, original_start, original_end, kept, transcription_key)
                VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)
                """, [.integer(videoID), .integer(projectID), .real(time), .real(end),
                      .real(time), .real(end), .integer(kept ? 1 : 0), setKey.map(SQLValue.text) ?? .null])
            let added = connection.lastInsertRowID
            var ids = order
            ids.insert(added, at: min(ids.count, max(0, index)))
            let current = try fetchTranscriptPicks(projectID: projectID, videoID: videoID).map(\.id)
            let ordered = ids.filter { current.contains($0) } + current.filter { !ids.contains($0) }
            for (position, pickID) in ordered.enumerated() {
                try connection.execute("UPDATE transcript_picks SET position = ? WHERE id = ? AND project_id = ?",
                                       [.integer(Int64(position)), .integer(pickID), .integer(projectID)])
            }
            guard let pick = try transcriptPick(id: added) else { throw WizardSelectionError.missingSelection }
            return pick
        }
    }

    func transcriptPick(id: Int64) throws -> TranscriptPick? {
        try connection.query("SELECT * FROM transcript_picks WHERE id = ?", [.integer(id)]).first.map(Self.transcriptPick)
    }

    func setTranscriptPickRange(projectID: Int64, id: Int64, start: Double, end: Double) throws {
        try connection.transaction {
            try adoptLegacyTranscriptPicks(projectID: projectID, pickID: id)
            // Ownership guard: a stale caller never edits another project's pick.
            try connection.execute("UPDATE transcript_picks SET start_time = ?, end_time = ? WHERE id = ? AND (project_id = ? OR project_id IS NULL)",
                                   [.real(start), .real(end), .integer(id), .integer(projectID)])
        }
    }

    /// Checked picks become footage; unchecked ones stay in the list.
    func setTranscriptPickKept(projectID: Int64, id: Int64, kept: Bool) throws {
        try connection.transaction {
            try adoptLegacyTranscriptPicks(projectID: projectID, pickID: id)
            try connection.execute("UPDATE transcript_picks SET kept = ? WHERE id = ? AND (project_id = ? OR project_id IS NULL)",
                                   [.integer(kept ? 1 : 0), .integer(id), .integer(projectID)])
        }
    }

    /// Rewrites positions in the given order; picks not listed keep their place after them.
    func reorderTranscriptPicks(projectID: Int64, videoID: Int64, ids: [Int64]) throws {
        try connection.transaction {
            try adoptLegacyTranscriptPicks(projectID: projectID, videoID: videoID)
            let current = try fetchTranscriptPicks(projectID: projectID, videoID: videoID).map(\.id)
            let ordered = ids.filter { current.contains($0) } + current.filter { !ids.contains($0) }
            for (position, id) in ordered.enumerated() {
                try connection.execute("UPDATE transcript_picks SET position = ? WHERE id = ? AND (project_id = ? OR project_id IS NULL)",
                                       [.integer(Int64(position)), .integer(id), .integer(projectID)])
            }
        }
    }

    /// Undo and Redo: makes this project's list for the video match `picks`
    /// (order, range, check mark). Picks not listed are deleted; a listed
    /// pick that is gone comes back, under its old row id when that is free.
    /// Rows that already match are not written, so nothing is queued for
    /// sync without a change. Returns the list and any ids that changed.
    ///
    /// `expected` is the list the caller believes is stored. If the rows
    /// differ (a Team Sync pull the screen never showed), nothing is
    /// written and `TranscriptPickRestoreError.changed` carries the real
    /// list: restoring would delete a pick the user never saw.
    func restoreTranscriptPicks(projectID: Int64, videoID: Int64, expected: [TranscriptPick],
                                picks: [TranscriptPick],
                                set: TranscriptPickSet = .active) throws -> (picks: [TranscriptPick], remapped: [Int64: Int64]) {
        try connection.transaction {
            let setKey = try requireShownSet(set, videoID: videoID)
            try adoptLegacyTranscriptPicks(projectID: projectID, videoID: videoID)
            let current = try fetchTranscriptPicks(projectID: projectID, videoID: videoID)
            let stored = current.map { TranscriptPickRestoreError.Row(id: $0.id, start: $0.start, end: $0.end, kept: $0.kept) }
            let believed = expected.map { TranscriptPickRestoreError.Row(id: $0.id, start: $0.start, end: $0.end, kept: $0.kept) }
            guard stored == believed else { throw TranscriptPickRestoreError.changed(current) }
            let wanted = Set(picks.map(\.id))
            for pick in current where !wanted.contains(pick.id) {
                try connection.execute("DELETE FROM transcript_picks WHERE id = ? AND project_id = ?",
                                       [.integer(pick.id), .integer(projectID)])
            }
            let existing = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            var remapped: [Int64: Int64] = [:]
            for (position, pick) in picks.enumerated() {
                if let row = existing[pick.id] {
                    guard row.position != position || row.start != pick.start || row.end != pick.end || row.kept != pick.kept else { continue }
                    try connection.execute("""
                        UPDATE transcript_picks SET position = ?, start_time = ?, end_time = ?, kept = ?
                        WHERE id = ? AND project_id = ?
                        """, [.integer(Int64(position)), .real(pick.start), .real(pick.end), .integer(pick.kept ? 1 : 0),
                              .integer(pick.id), .integer(projectID)])
                } else {
                    // Another project's pick may have taken the id since.
                    let free = try connection.query("SELECT 1 FROM transcript_picks WHERE id = ?", [.integer(pick.id)]).isEmpty
                    try connection.execute("""
                        INSERT INTO transcript_picks (id, video_id, project_id, position, start_time, end_time, original_start, original_end, kept, transcription_key)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [free ? .integer(pick.id) : .null, .integer(videoID), .integer(projectID), .integer(Int64(position)),
                              .real(pick.start), .real(pick.end), .real(pick.originalStart), .real(pick.originalEnd),
                              .integer(pick.kept ? 1 : 0), setKey.map(SQLValue.text) ?? .null])
                    if !free { remapped[pick.id] = connection.lastInsertRowID }
                }
            }
            return (try fetchTranscriptPicks(projectID: projectID, videoID: videoID), remapped)
        }
    }

    /// This project's list for the active transcript set, including legacy
    /// picks it would adopt. Picks of other sets are not on screen and stay.
    func deleteTranscriptPicks(projectID: Int64, videoID: Int64, set: TranscriptPickSet = .active) throws {
        try connection.transaction {
            _ = try requireShownSet(set, videoID: videoID)
            try connection.execute("DELETE FROM transcript_picks WHERE video_id = ? AND (project_id = ? OR project_id IS NULL) AND \(Self.activeSetPickPredicate)",
                                   [.integer(videoID), .integer(projectID)])
        }
    }

    func deleteTranscriptPick(projectID: Int64, id: Int64) throws {
        try connection.transaction {
            try adoptLegacyTranscriptPicks(projectID: projectID, pickID: id)
            try connection.execute("DELETE FROM transcript_picks WHERE id = ? AND (project_id = ? OR project_id IS NULL)",
                                   [.integer(id), .integer(projectID)])
        }
    }

    /// Each checked pick becomes a scene on the video's active run plus one
    /// selection with one take, in list order; unchecked picks are skipped.
    /// Earlier selections of this Mini batch are replaced.
    func replaceMiniTranscriptSelections(projectID: Int64, videoID: Int64, miniBatch: String,
                                         picks: [TranscriptPick], rows: [TranscriptRow],
                                         options: WizardStep1Options,
                                         reviewedCutsByPick: [Int64: [BRollCut]] = [:]) throws -> [MiniWizardCandidate] {
        try connection.transaction {
            let savedByPick = try miniBRollByPick(projectID: projectID, miniBatch: miniBatch)
            let reviewed = try miniReviewedBRoll(projectID: projectID, miniBatch: miniBatch)
            try adoptLegacyTranscriptPicks(projectID: projectID, videoID: videoID)
            let previousPicks = try fetchTranscriptPicks(projectID: projectID, videoID: videoID)
            let previousSceneIDs = Dictionary(uniqueKeysWithValues: previousPicks.compactMap { pick in
                pick.sceneID.map { (pick.id, $0) }
            })
            let runID = try activeAnalysisRun(videoID: videoID).run?.id
            // Camera focus (grid, talker and rotation, ...) only frames scenes
            // tagged "podcast"; a pick from conversational footage must carry it
            // or the chosen focus is silently skipped.
            let video = try video(id: videoID)
            let hasTurns = try !fetchSpeakerTurns(videoID: videoID).isEmpty
            let conversational = video?.type == .podcast || video?.type == .interview || hasTurns
            try connection.execute("DELETE FROM wizard_selections WHERE project_id = ? AND mini_batch = ?",
                                   [.integer(projectID), .text(miniBatch)])
            var step1 = options
            step1.targetDurationSeconds = nil
            var candidates: [MiniWizardCandidate] = []
            // Only picks this project owns (after legacy adoption); a stale
            // caller's pick from another project is skipped.
            let owned = Set(try fetchTranscriptPicks(projectID: projectID, videoID: videoID).map(\.id))
            let ordered = picks.filter { $0.kept && $0.videoID == videoID && owned.contains($0.id) }
                .sorted { ($0.position, $0.id) < ($1.position, $1.id) }
            for (index, pick) in ordered.enumerated() {
                guard pick.start.isFinite, pick.end.isFinite, pick.end > pick.start else { continue }
                let sceneID = try sceneID(videoID: videoID, runID: runID, start: pick.start, end: pick.end)
                try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                       [.integer(sceneID), .text(Self.transcriptPickTag)])
                if conversational {
                    try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                           [.integer(sceneID), .text("podcast")])
                }
                try connection.execute("UPDATE transcript_picks SET scene_id = ? WHERE id = ? AND project_id = ?",
                                       [.integer(sceneID), .integer(pick.id), .integer(projectID)])
                let name = MiniWizardTranscriptRules.title(for: pick, rows: rows, number: index + 1)
                var plan = MiniWizardTranscriptRules.plan(for: pick, sceneID: sceneID, name: name)
                for index in plan.clips.indices { plan.clips[index].miniPickID = pick.id }
                let previousCuts = reviewedCutsByPick[pick.id] ?? savedByPick[pick.id]
                    ?? previousSceneIDs[pick.id].flatMap { reviewed[$0] }
                if let cuts = previousCuts {
                    for index in plan.clips.indices {
                        let clip = plan.clips[index]
                        plan.clips[index].brollCuts = MiniBRollRules.retained(cuts, in: clip.start...clip.end)
                    }
                }
                let id = try insertWizardSelection(projectID: projectID, name: name,
                    recipe: options.formatPreset ?? "custom", step1Options: step1, miniBatch: miniBatch)
                let take = try insertWizardSelectionTake(selectionID: id, plan: plan)
                guard let selection = try wizardSelection(id: id) else { throw WizardSelectionError.missingSelection }
                candidates.append(MiniWizardCandidate(selection: selection, take: take))
            }
            return candidates
        }
    }

    private nonisolated static func transcriptPick(_ row: [String: SQLValue]) -> TranscriptPick {
        TranscriptPick(id: row["id"]?.intValue ?? 0,
                       videoID: row["video_id"]?.intValue ?? 0,
                       position: Int(row["position"]?.intValue ?? 0),
                       start: row["start_time"]?.doubleValue ?? 0,
                       end: row["end_time"]?.doubleValue ?? 0,
                       originalStart: row["original_start"]?.doubleValue ?? 0,
                       originalEnd: row["original_end"]?.doubleValue ?? 0,
                       sceneID: row["scene_id"]?.intValue,
                       projectID: row["project_id"]?.intValue,
                       kept: (row["kept"]?.intValue ?? 1) != 0)
    }
}

/// Which transcript set a pick write is meant for.
nonisolated enum TranscriptPickSet: Sendable, Equatable {
    /// Whatever set is active when the write runs.
    case active
    /// The set the caller's list was read from; the write fails if another is active by then.
    case shown(String?)
}

nonisolated enum TranscriptPickSetError: LocalizedError {
    case changed
    var errorDescription: String? { "The video's transcript changed. The list was reloaded; nothing was written." }
}

nonisolated enum TranscriptPickRestoreError: Error {
    /// The stored list is not the one Undo expected; it comes with the error.
    case changed([TranscriptPick])

    struct Row: Equatable {
        var id: Int64
        var start: Double
        var end: Double
        var kept: Bool
    }
}
