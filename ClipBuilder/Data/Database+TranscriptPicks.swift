import Foundation

extension Database {
    static let transcriptPickTag = "transcript-pick"

    func fetchTranscriptPicks(videoID: Int64) throws -> [TranscriptPick] {
        try connection.query("SELECT * FROM transcript_picks WHERE video_id = ? ORDER BY position, id",
                             [.integer(videoID)]).map(Self.transcriptPick)
    }

    /// Appends at the end of the list.
    func addTranscriptPick(videoID: Int64, start: Double, end: Double) throws -> TranscriptPick {
        try connection.transaction {
            let position = (try connection.query("SELECT MAX(position) AS n FROM transcript_picks WHERE video_id = ?",
                                                 [.integer(videoID)]).first?["n"]?.intValue ?? -1) + 1
            try connection.execute("""
                INSERT INTO transcript_picks (video_id, position, start_time, end_time, original_start, original_end)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.integer(videoID), .integer(position), .real(start), .real(end), .real(start), .real(end)])
            let id = connection.lastInsertRowID
            guard let pick = try transcriptPick(id: id) else { throw WizardSelectionError.missingSelection }
            return pick
        }
    }

    func transcriptPick(id: Int64) throws -> TranscriptPick? {
        try connection.query("SELECT * FROM transcript_picks WHERE id = ?", [.integer(id)]).first.map(Self.transcriptPick)
    }

    func setTranscriptPickRange(id: Int64, start: Double, end: Double) throws {
        try connection.execute("UPDATE transcript_picks SET start_time = ?, end_time = ? WHERE id = ?",
                               [.real(start), .real(end), .integer(id)])
    }

    /// Rewrites positions in the given order; picks not listed keep their place after them.
    func reorderTranscriptPicks(videoID: Int64, ids: [Int64]) throws {
        try connection.transaction {
            let current = try fetchTranscriptPicks(videoID: videoID).map(\.id)
            let ordered = ids.filter { current.contains($0) } + current.filter { !ids.contains($0) }
            for (position, id) in ordered.enumerated() {
                try connection.execute("UPDATE transcript_picks SET position = ? WHERE id = ?",
                                       [.integer(Int64(position)), .integer(id)])
            }
        }
    }

    func deleteTranscriptPick(id: Int64) throws {
        try connection.execute("DELETE FROM transcript_picks WHERE id = ?", [.integer(id)])
    }

    /// Each pick becomes a scene on the video's active run plus one selection with
    /// one take, in list order. Earlier selections of this Mini batch are replaced.
    func replaceMiniTranscriptSelections(projectID: Int64, videoID: Int64, miniBatch: String,
                                         picks: [TranscriptPick], rows: [TranscriptRow],
                                         options: WizardStep1Options) throws -> [MiniWizardCandidate] {
        try connection.transaction {
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
            let ordered = picks.filter { $0.videoID == videoID }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
            for (index, pick) in ordered.enumerated() {
                guard pick.start.isFinite, pick.end.isFinite, pick.end > pick.start else { continue }
                guard let sceneID = try connection.query("""
                    INSERT INTO scenes (video_id, run_id, start_time, end_time)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(video_id, run_id, start_time, end_time) DO UPDATE SET video_id = video_id
                    RETURNING id
                    """, [.integer(videoID), runID.map(SQLValue.integer) ?? .null, .real(pick.start), .real(pick.end)]
                ).first?["id"]?.intValue else { continue }
                try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                       [.integer(sceneID), .text(Self.transcriptPickTag)])
                if conversational {
                    try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                           [.integer(sceneID), .text("podcast")])
                }
                try connection.execute("UPDATE transcript_picks SET scene_id = ? WHERE id = ?",
                                       [.integer(sceneID), .integer(pick.id)])
                let name = MiniWizardTranscriptRules.title(for: pick, rows: rows, number: index + 1)
                let plan = MiniWizardTranscriptRules.plan(for: pick, sceneID: sceneID, name: name)
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
                       sceneID: row["scene_id"]?.intValue)
    }
}
