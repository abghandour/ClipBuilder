import Foundation

extension Database {
    static let fightPickTag = "fight-pick"

    /// The video's picks in this project, plus legacy picks no project owns
    /// yet. `projectID == nil` reads every project's picks (id lookups).
    func fetchFightPicks(projectID: Int64?, videoID: Int64) throws -> [FightPick] {
        guard let projectID else {
            return try connection.query("SELECT * FROM fight_picks WHERE video_id = ? ORDER BY position, id",
                                        [.integer(videoID)]).map(Self.fightPick)
        }
        return try connection.query("""
            SELECT * FROM fight_picks WHERE video_id = ? AND (project_id = ? OR project_id IS NULL)
            ORDER BY position, id
            """, [.integer(videoID), .integer(projectID)]).map(Self.fightPick)
    }

    /// Legacy picks (from before picks were per project) join the first
    /// project that writes to the video's list.
    private func adoptLegacyFightPicks(projectID: Int64, videoID: Int64) throws {
        try connection.execute("UPDATE fight_picks SET project_id = ? WHERE video_id = ? AND project_id IS NULL",
                               [.integer(projectID), .integer(videoID)])
    }

    private func adoptLegacyFightPicks(projectID: Int64, pickID: Int64) throws {
        guard let videoID = try connection.query("SELECT video_id FROM fight_picks WHERE id = ?",
                                                 [.integer(pickID)]).first?["video_id"]?.intValue else { return }
        try adoptLegacyFightPicks(projectID: projectID, videoID: videoID)
    }

    /// Appends at the end of the list.
    func addFightPick(projectID: Int64, videoID: Int64, start: Double, end: Double, eventIDs: [Int64]) throws -> FightPick {
        try connection.transaction {
            try adoptLegacyFightPicks(projectID: projectID, videoID: videoID)
            let position = (try connection.query(
                "SELECT MAX(position) AS n FROM fight_picks WHERE video_id = ? AND project_id = ?",
                [.integer(videoID), .integer(projectID)]).first?["n"]?.intValue ?? -1) + 1
            let ids = String(data: try JSONEncoder().encode(eventIDs), encoding: .utf8) ?? "[]"
            try connection.execute("""
                INSERT INTO fight_picks (video_id, project_id, position, start_time, end_time, original_start, original_end, event_ids)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [.integer(videoID), .integer(projectID), .integer(position), .real(start), .real(end),
                      .real(start), .real(end), .text(ids)])
            let id = connection.lastInsertRowID
            guard let pick = try fightPick(id: id) else { throw WizardSelectionError.missingSelection }
            return pick
        }
    }

    func fightPick(id: Int64) throws -> FightPick? {
        try connection.query("SELECT * FROM fight_picks WHERE id = ?", [.integer(id)]).first.map(Self.fightPick)
    }

    func setFightPickRange(projectID: Int64, id: Int64, start: Double, end: Double) throws {
        try connection.transaction {
            try adoptLegacyFightPicks(projectID: projectID, pickID: id)
            // Ownership guard: a stale caller never edits another project's pick.
            try connection.execute("UPDATE fight_picks SET start_time = ?, end_time = ? WHERE id = ? AND (project_id = ? OR project_id IS NULL)",
                                   [.real(start), .real(end), .integer(id), .integer(projectID)])
        }
    }

    /// Rewrites positions in the given order; picks not listed keep their place after them.
    func reorderFightPicks(projectID: Int64, videoID: Int64, ids: [Int64]) throws {
        try connection.transaction {
            try adoptLegacyFightPicks(projectID: projectID, videoID: videoID)
            let current = try fetchFightPicks(projectID: projectID, videoID: videoID).map(\.id)
            let ordered = ids.filter { current.contains($0) } + current.filter { !ids.contains($0) }
            for (position, id) in ordered.enumerated() {
                try connection.execute("UPDATE fight_picks SET position = ? WHERE id = ? AND (project_id = ? OR project_id IS NULL)",
                                       [.integer(Int64(position)), .integer(id), .integer(projectID)])
            }
        }
    }

    /// This project's list, including legacy picks it would adopt.
    func deleteFightPicks(projectID: Int64, videoID: Int64) throws {
        try connection.execute("DELETE FROM fight_picks WHERE video_id = ? AND (project_id = ? OR project_id IS NULL)",
                               [.integer(videoID), .integer(projectID)])
    }

    func deleteFightPick(projectID: Int64, id: Int64) throws {
        try connection.transaction {
            try adoptLegacyFightPicks(projectID: projectID, pickID: id)
            try connection.execute("DELETE FROM fight_picks WHERE id = ? AND (project_id = ? OR project_id IS NULL)",
                                   [.integer(id), .integer(projectID)])
        }
    }

    /// Each pick becomes a scene on the video's active run plus one selection
    /// with one take, in list order. Earlier selections of this Mini batch are replaced.
    func replaceMiniFightSelections(projectID: Int64, videoID: Int64, miniBatch: String,
                                    picks: [FightPick], actions: [MiniWizardFightRules.Action],
                                    names: [String: String], options: WizardStep1Options) throws -> [MiniWizardCandidate] {
        try connection.transaction {
            try adoptLegacyFightPicks(projectID: projectID, videoID: videoID)
            let runID = try activeAnalysisRun(videoID: videoID).run?.id
            try connection.execute("DELETE FROM wizard_selections WHERE project_id = ? AND mini_batch = ?",
                                   [.integer(projectID), .text(miniBatch)])
            var step1 = options
            step1.targetDurationSeconds = nil
            var candidates: [MiniWizardCandidate] = []
            // Only picks this project owns (after legacy adoption); a stale
            // caller's pick from another project is skipped.
            let owned = Set(try fetchFightPicks(projectID: projectID, videoID: videoID).map(\.id))
            let ordered = picks.filter { $0.videoID == videoID && owned.contains($0.id) }
                .sorted { ($0.position, $0.id) < ($1.position, $1.id) }
            for (index, pick) in ordered.enumerated() {
                guard pick.start.isFinite, pick.end.isFinite, pick.end > pick.start else { continue }
                let sceneID = try sceneID(videoID: videoID, runID: runID, start: pick.start, end: pick.end)
                try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                       [.integer(sceneID), .text(Self.fightPickTag)])
                try connection.execute("UPDATE fight_picks SET scene_id = ? WHERE id = ? AND project_id = ?",
                                       [.integer(sceneID), .integer(pick.id), .integer(projectID)])
                let name = MiniWizardFightRules.title(for: pick, actions: actions, names: names, number: index + 1)
                let plan = MiniWizardFightRules.plan(for: pick, sceneID: sceneID, name: name)
                let id = try insertWizardSelection(projectID: projectID, name: name,
                    recipe: options.formatPreset ?? "custom", step1Options: step1, miniBatch: miniBatch)
                let take = try insertWizardSelectionTake(selectionID: id, plan: plan)
                guard let selection = try wizardSelection(id: id) else { throw WizardSelectionError.missingSelection }
                candidates.append(MiniWizardCandidate(selection: selection, take: take))
            }
            return candidates
        }
    }

    private nonisolated static func fightPick(_ row: [String: SQLValue]) -> FightPick {
        let ids = (row["event_ids"]?.stringValue).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([Int64].self, from: $0) } ?? []
        return FightPick(id: row["id"]?.intValue ?? 0,
                         videoID: row["video_id"]?.intValue ?? 0,
                         position: Int(row["position"]?.intValue ?? 0),
                         start: row["start_time"]?.doubleValue ?? 0,
                         end: row["end_time"]?.doubleValue ?? 0,
                         originalStart: row["original_start"]?.doubleValue ?? 0,
                         originalEnd: row["original_end"]?.doubleValue ?? 0,
                         eventIDs: ids,
                         sceneID: row["scene_id"]?.intValue,
                         projectID: row["project_id"]?.intValue)
    }
}
