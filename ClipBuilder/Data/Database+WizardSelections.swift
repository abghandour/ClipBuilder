import Foundation

nonisolated struct WizardSelectionRecord: Identifiable, Sendable {
    var id: Int64
    var projectID: Int64
    var name: String
    var recipe: String
    var step1Options: WizardStep1Options
    var bestTakeID: Int64?
    var createdAt: String?
    var editedAt: String?
    var miniBatch: String? = nil
}

nonisolated struct WizardSelectionTake: Identifiable, Sendable {
    var id: Int64
    var selectionID: Int64
    var ordinal: Int
    var note: String?
    var plan: WizardPlan
    var sceneIDs: [Int64]
    var proxyPath: String?
    var criticScore: Int?
    var criticNotes: String?
    var provenance: AIProvenance?
    var createdAt: String?
}

nonisolated enum WizardSelectionError: LocalizedError {
    case missingSelection, missingTake, wrongSelection, footageChanged

    var errorDescription: String? {
        switch self {
        case .missingSelection: "This selection is no longer available."
        case .missingTake: "This take is no longer available."
        case .wrongSelection: "The take belongs to a different selection or project."
        case .footageChanged: "Footage changed. Find another take before rendering."
        }
    }
}

extension Database {
    @discardableResult
    func insertWizardSelection(projectID: Int64, name: String, recipe: String,
                               step1Options: WizardStep1Options, miniBatch: String? = nil) throws -> Int64 {
        let json = try Self.wizardSelectionJSON(step1Options)
        try connection.execute("""
            INSERT INTO wizard_selections (project_id, name, recipe, step1_options_json, mini_batch)
            VALUES (?, ?, ?, ?, ?)
            """, [.integer(projectID), .text(name), .text(recipe), .text(json), miniBatch.map(SQLValue.text) ?? .null])
        return connection.lastInsertRowID
    }

    /// Creation and Take 1 commit together; a failed plan write leaves no empty selection.
    func recordWizardTake(projectID: Int64, selectionID: Int64? = nil,
                          options: WizardStep1Options, plan: WizardPlan,
                          note: String? = nil, miniBatch: String? = nil,
                          fallbackName: String? = nil) throws -> WizardSelectionTake {
        try connection.transaction {
            let id: Int64
            if let selectionID {
                guard let selection = try wizardSelection(id: selectionID) else {
                    throw WizardSelectionError.missingSelection
                }
                guard selection.projectID == projectID else { throw WizardSelectionError.wrongSelection }
                id = selectionID
            } else {
                let count = try connection.query("SELECT COUNT(*) AS n FROM wizard_selections WHERE project_id = ?",
                                                  [.integer(projectID)]).first?["n"]?.intValue ?? 0
                let headline = plan.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
                id = try insertWizardSelection(projectID: projectID,
                    name: headline.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName ?? "Selection \(count + 1)",
                    recipe: options.formatPreset ?? "custom", step1Options: options, miniBatch: miniBatch)
            }
            return try insertWizardSelectionTake(selectionID: id, plan: plan, note: note)
        }
    }

    func addWizardSelectionTake(selectionID: Int64, plan: WizardPlan, note: String? = nil,
                                proxyPath: String? = nil, criticScore: Int? = nil,
                                criticNotes: String? = nil) throws -> WizardSelectionTake {
        try connection.transaction {
            try insertWizardSelectionTake(selectionID: selectionID, plan: plan, note: note,
                proxyPath: proxyPath, criticScore: criticScore, criticNotes: criticNotes)
        }
    }

    private func insertWizardSelectionTake(selectionID: Int64, plan: WizardPlan, note: String? = nil,
                                           proxyPath: String? = nil, criticScore: Int? = nil,
                                           criticNotes: String? = nil) throws -> WizardSelectionTake {
        // Caller holds a write transaction, including when creating Selection + Take 1.
        guard let selection = try wizardSelection(id: selectionID) else { throw WizardSelectionError.missingSelection }
        let plan = WizardSelectionRules.snapshot(plan, scenes: try fetchScenes(projectID: selection.projectID))
        let ordinal = (try connection.query(
            "SELECT MAX(ordinal) AS n FROM wizard_selection_takes WHERE selection_id = ?",
            [.integer(selectionID)]).first?["n"]?.intValue ?? 0) + 1
        let planJSON = try Self.wizardSelectionJSON(plan)
        let idsJSON = try Self.wizardSelectionJSON(Self.wizardSceneIDs(plan))
        let provenance = try plan.provenance.map { try Self.wizardSelectionJSON($0) }
        try connection.execute("""
            INSERT INTO wizard_selection_takes
                (selection_id, ordinal, note, plan_json, scene_ids_json, proxy_path,
                 critic_score, critic_notes, provenance_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.integer(selectionID), .integer(ordinal), note.map(SQLValue.text) ?? .null,
                  .text(planJSON), .text(idsJSON), proxyPath.map(SQLValue.text) ?? .null,
                  criticScore.map { .integer(Int64($0)) } ?? .null,
                  criticNotes.map(SQLValue.text) ?? .null, provenance.map(SQLValue.text) ?? .null])
        let id = connection.lastInsertRowID
        try touchWizardSelection(id: selectionID)
        guard let take = try wizardSelectionTake(id: id) else { throw WizardSelectionError.missingTake }
        return take
    }

    func updateWizardSelectionTakePlan(id: Int64, plan: WizardPlan) throws {
        guard let take = try wizardSelectionTake(id: id) else { throw WizardSelectionError.missingTake }
        guard let selection = try wizardSelection(id: take.selectionID) else { throw WizardSelectionError.missingSelection }
        let plan = WizardSelectionRules.snapshot(plan, scenes: try fetchScenes(projectID: selection.projectID))
        try connection.transaction {
            try connection.execute("""
                UPDATE wizard_selection_takes SET plan_json = ?, scene_ids_json = ?,
                    provenance_json = ?, proxy_path = NULL, critic_score = NULL, critic_notes = NULL
                WHERE id = ?
                """, [.text(try Self.wizardSelectionJSON(plan)),
                      .text(try Self.wizardSelectionJSON(Self.wizardSceneIDs(plan))),
                      try plan.provenance.map { .text(try Self.wizardSelectionJSON($0)) } ?? .null,
                      .integer(id)])
            try touchWizardSelection(id: take.selectionID)
        }
    }

    func updateWizardSelectionTakeCritique(id: Int64, score: Int, notes: String) throws {
        guard let take = try wizardSelectionTake(id: id) else { throw WizardSelectionError.missingTake }
        try connection.transaction {
            try connection.execute("UPDATE wizard_selection_takes SET critic_score = ?, critic_notes = ? WHERE id = ?",
                                   [.integer(Int64(score)), .text(notes), .integer(id)])
            try touchWizardSelection(id: take.selectionID)
        }
    }

    /// A saved selection's earlier looks must not become its own reference teacher.
    func wizardSelectionCriticExclusion(selectionID: Int64) throws -> CriticExemplars.Exclusion {
        let takeIDs = Set(try fetchWizardSelectionTakes(selectionID: selectionID).map(\.id))
        let videos = try fetchGeneratedVideos()
        let related = videos.filter { $0.selectionTakeID.map(takeIDs.contains) == true }
        let batches = Set(related.compactMap(\.batchID))
        let siblings = videos.filter {
            $0.selectionTakeID.map(takeIDs.contains) == true || $0.batchID.map(batches.contains) == true
        }
        return .init(ids: Set(siblings.map { "generated:\($0.id)" }),
                     batchIDs: batches, paths: Set(siblings.map(\.path)))
    }

    func updateWizardSelectionTakeProxy(id: Int64, path: String?) throws {
        guard let take = try wizardSelectionTake(id: id) else { throw WizardSelectionError.missingTake }
        try connection.execute("UPDATE wizard_selection_takes SET proxy_path = ? WHERE id = ?",
                               [path.map(SQLValue.text) ?? .null, .integer(id)])
        try touchWizardSelection(id: take.selectionID)
    }

    func setBestWizardSelectionTake(selectionID: Int64, takeID: Int64?) throws {
        guard try wizardSelection(id: selectionID) != nil else { throw WizardSelectionError.missingSelection }
        if let takeID {
            guard let take = try wizardSelectionTake(id: takeID) else { throw WizardSelectionError.missingTake }
            guard take.selectionID == selectionID else { throw WizardSelectionError.wrongSelection }
        }
        try connection.execute("""
            UPDATE wizard_selections SET best_take_id = ?, edited_at = datetime('now') WHERE id = ?
            """, [takeID.map(SQLValue.integer) ?? .null, .integer(selectionID)])
    }

    func fetchWizardSelections(projectID: Int64) throws -> [WizardSelectionRecord] {
        try connection.query("SELECT * FROM wizard_selections WHERE project_id = ? ORDER BY edited_at DESC, id DESC",
                             [.integer(projectID)]).map(Self.wizardSelectionRecord)
    }

    /// Preserve planner order within a Mini run, independently of later take edits.
    func fetchWizardSelections(projectID: Int64, miniBatch: String) throws -> [WizardSelectionRecord] {
        try connection.query("SELECT * FROM wizard_selections WHERE project_id = ? AND mini_batch = ? ORDER BY id",
                             [.integer(projectID), .text(miniBatch)]).map(Self.wizardSelectionRecord)
    }

    /// Replace only this run's Q&A selections atomically. Failed writes retain the
    /// previous batch; current saved scene edits are read inside the transaction.
    func replaceMiniQASelections(projectID: Int64, videoID: Int64, miniBatch: String,
                                 kept: Set<Int64>, rows: [TranscriptRow], labels: [Int64: String],
                                 turns: [SpeakerTurn], options: WizardStep1Options) throws -> [MiniWizardCandidate] {
        try connection.transaction {
            let scenes = try fetchScenes(projectID: projectID, includeExcluded: true).filter { $0.videoID == videoID }
            let sections = TranscriptQASections.sections(scenes: scenes, rows: rows, labels: labels)
            let plans = MiniWizardQARules.plans(sections: sections, kept: kept, rows: rows, turns: turns)
            try connection.execute("DELETE FROM wizard_selections WHERE project_id = ? AND mini_batch = ? AND recipe = 'podcast'",
                                   [.integer(projectID), .text(miniBatch)])
            var step1 = options
            step1.formatPreset = "podcast"
            step1.targetDurationSeconds = nil
            var candidates: [MiniWizardCandidate] = []
            for plan in plans {
                let id = try insertWizardSelection(projectID: projectID, name: plan.headline ?? "Exchange",
                    recipe: "podcast", step1Options: step1, miniBatch: miniBatch)
                let take = try insertWizardSelectionTake(selectionID: id, plan: plan)
                guard let selection = try wizardSelection(id: id) else { throw WizardSelectionError.missingSelection }
                candidates.append(MiniWizardCandidate(selection: selection, take: take))
            }
            return candidates
        }
    }

    /// Save the joined take and its exact selection name together, off the main actor.
    func recordMiniCombinedTake(projectID: Int64, miniBatch: String, name: String,
                                takes: [WizardSelectionTake], options: WizardStep1Options) throws -> WizardSelectionTake {
        try connection.transaction {
            guard !takes.isEmpty else { throw WizardSelectionError.missingTake }
            let scenes = try fetchScenes(projectID: projectID, includeExcluded: true)
            let resolved = try takes.map { take in
                guard let selection = try wizardSelection(id: take.selectionID),
                      selection.projectID == projectID, selection.miniBatch == miniBatch else {
                    throw WizardSelectionError.wrongSelection
                }
                guard let plan = WizardSelectionRules.resolvedPlan(take.plan, scenes: scenes) else {
                    throw WizardSelectionError.footageChanged
                }
                var take = take
                take.plan = plan
                return take
            }
            var step1 = options
            step1.targetDurationSeconds = nil
            let id = try insertWizardSelection(projectID: projectID, name: name,
                recipe: options.formatPreset ?? "custom", step1Options: step1, miniBatch: miniBatch)
            return try insertWizardSelectionTake(selectionID: id, plan: WizardPlanRules.combinedPlan(resolved))
        }
    }

    func renameWizardSelection(id: Int64, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try connection.execute("UPDATE wizard_selections SET name = ?, edited_at = datetime('now') WHERE id = ?",
                               [.text(name), .integer(id)])
    }

    func wizardSelection(id: Int64) throws -> WizardSelectionRecord? {
        try connection.query("SELECT * FROM wizard_selections WHERE id = ?", [.integer(id)])
            .first.map(Self.wizardSelectionRecord)
    }

    func fetchWizardSelectionTakes(selectionID: Int64) throws -> [WizardSelectionTake] {
        try connection.query("SELECT * FROM wizard_selection_takes WHERE selection_id = ? ORDER BY ordinal",
                             [.integer(selectionID)]).map { try hydrateWizardTakeFootage(Self.wizardTakeRecord($0)) }
    }

    func wizardSelectionTake(id: Int64) throws -> WizardSelectionTake? {
        try connection.query("SELECT * FROM wizard_selection_takes WHERE id = ?", [.integer(id)])
            .first.map { try hydrateWizardTakeFootage(Self.wizardTakeRecord($0)) }
    }

    /// Add stable identities to pre-P3 plans while their original sources still
    /// exist. This metadata upgrade does not clear a review or change edit time.
    private func hydrateWizardTakeFootage(_ original: WizardSelectionTake) throws -> WizardSelectionTake {
        guard original.plan.footage == nil,
              let selection = try wizardSelection(id: original.selectionID),
              let plan = WizardSelectionRules.resolvedPlan(original.plan,
                  scenes: try fetchScenes(projectID: selection.projectID)) else { return original }
        var take = original
        take.plan = plan
        take.sceneIDs = Self.wizardSceneIDs(plan)
        try connection.execute("UPDATE wizard_selection_takes SET plan_json = ?, scene_ids_json = ? WHERE id = ?",
            [.text(try Self.wizardSelectionJSON(plan)), .text(try Self.wizardSelectionJSON(take.sceneIDs)), .integer(take.id)])
        return take
    }

    func deleteWizardSelection(id: Int64) throws {
        try connection.execute("DELETE FROM wizard_selections WHERE id = ?", [.integer(id)])
    }

    func deleteWizardSelectionTake(id: Int64) throws {
        guard let take = try wizardSelectionTake(id: id) else { return }
        try connection.transaction {
            try connection.execute("DELETE FROM wizard_selection_takes WHERE id = ?", [.integer(id)])
            try touchWizardSelection(id: take.selectionID)
        }
    }

    private func touchWizardSelection(id: Int64) throws {
        try connection.execute("UPDATE wizard_selections SET edited_at = datetime('now') WHERE id = ?", [.integer(id)])
    }

    private nonisolated static func wizardSceneIDs(_ plan: WizardPlan) -> [Int64] {
        Array(Set(plan.clips.flatMap { [$0.sceneID] + $0.areaClips.map(\.sceneID) })).sorted()
    }

    private nonisolated static func wizardSelectionJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private nonisolated static func wizardSelectionRecord(_ row: SQLRow) throws -> WizardSelectionRecord {
        let options = try JSONDecoder().decode(WizardStep1Options.self,
            from: Data((row["step1_options_json"]?.stringValue ?? "").utf8))
        return WizardSelectionRecord(id: row["id"]?.intValue ?? 0,
            projectID: row["project_id"]?.intValue ?? 0, name: row["name"]?.stringValue ?? "",
            recipe: row["recipe"]?.stringValue ?? "custom", step1Options: options,
            bestTakeID: row["best_take_id"]?.intValue, createdAt: row["created_at"]?.stringValue,
            editedAt: row["edited_at"]?.stringValue, miniBatch: row["mini_batch"]?.stringValue)
    }

    private nonisolated static func wizardTakeRecord(_ row: SQLRow) throws -> WizardSelectionTake {
        let decoder = JSONDecoder()
        let plan = try decoder.decode(WizardPlan.self, from: Data((row["plan_json"]?.stringValue ?? "").utf8))
        let ids = try decoder.decode([Int64].self, from: Data((row["scene_ids_json"]?.stringValue ?? "").utf8))
        let provenance = try row["provenance_json"]?.stringValue.map {
            try decoder.decode(AIProvenance.self, from: Data($0.utf8))
        }
        return WizardSelectionTake(id: row["id"]?.intValue ?? 0,
            selectionID: row["selection_id"]?.intValue ?? 0, ordinal: Int(row["ordinal"]?.intValue ?? 0),
            note: row["note"]?.stringValue, plan: plan, sceneIDs: ids,
            proxyPath: row["proxy_path"]?.stringValue, criticScore: row["critic_score"]?.intValue.map(Int.init),
            criticNotes: row["critic_notes"]?.stringValue, provenance: provenance,
            createdAt: row["created_at"]?.stringValue)
    }
}
