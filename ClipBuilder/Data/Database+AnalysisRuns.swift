import Foundation

nonisolated struct AnalysisRunReference: Sendable, Hashable {
    enum Kind: String, Sendable { case take = "Saved take", builder = "Builder document", generated = "Generated video" }
    var kind: Kind
    var id: Int64
    var name: String
    var sceneIDs: Set<Int64>
    var label: String { "\(kind.rawValue): \(name)" }
}

extension Database {
    func activeAnalysisRun(videoID: Int64) throws -> ActiveLayers.Resolution {
        let pin = try connection.query("SELECT active_run_key FROM videos WHERE id = ?", [.integer(videoID)])
            .first?["active_run_key"]?.stringValue
        return ActiveLayers.resolve(videoID: videoID, pinnedRunKey: pin,
                                    runs: try fetchAnalysisRuns(), passes: try fetchAnalysisPasses())
    }

    func setActiveRunKey(videoID: Int64, runKey: String?) throws {
        try connection.execute("UPDATE videos SET active_run_key = ? WHERE id = ?",
                               [runKey.map(SQLValue.text) ?? .null, .integer(videoID)])
    }

    /// Read all projects: a batch can be referenced outside the current workspace.
    func fetchSceneReferences() throws -> [AnalysisRunReference] {
        var result: [AnalysisRunReference] = []
        for row in try connection.query("""
            SELECT t.id, t.ordinal, t.plan_json, s.name FROM wizard_selection_takes t
            JOIN wizard_selections s ON s.id = t.selection_id
            """) {
            result.append(AnalysisRunReference(kind: .take, id: row["id"]?.intValue ?? 0,
                name: "\(row["name"]?.stringValue ?? "Selection") · Take \(row["ordinal"]?.intValue ?? 0)",
                sceneIDs: SceneReferences.ids(in: row["plan_json"]?.stringValue ?? "")))
        }
        for row in try connection.query("SELECT id, name, document_json FROM timelines") {
            result.append(AnalysisRunReference(kind: .builder, id: row["id"]?.intValue ?? 0,
                name: row["name"]?.stringValue ?? "Timeline",
                sceneIDs: SceneReferences.ids(in: row["document_json"]?.stringValue ?? "")))
        }
        for row in try connection.query("SELECT id, path, timeline_json FROM generated_videos") {
            result.append(AnalysisRunReference(kind: .generated, id: row["id"]?.intValue ?? 0,
                name: URL(fileURLWithPath: row["path"]?.stringValue ?? "Output").lastPathComponent,
                sceneIDs: SceneReferences.ids(in: row["timeline_json"]?.stringValue ?? "")))
        }
        return result
    }

    func analysisRunReferences(id: Int64) throws -> [AnalysisRunReference] {
        let ids = Set(try connection.query("SELECT id FROM scenes WHERE run_id = ?", [.integer(id)])
            .compactMap { $0["id"]?.intValue })
        return try fetchSceneReferences().filter { !$0.sceneIDs.isDisjoint(with: ids) }
    }

    /// Stored IDs win. History is needed only when the original scene was deleted.
    func scenesForSavedPlan(_ plan: WizardPlan, projectID: Int64?) throws -> [SceneRecord] {
        try scenesForSavedPlans([plan], projectID: projectID)
    }

    func scenesForSavedPlans(_ plans: [WizardPlan], projectID: Int64?) throws -> [SceneRecord] {
        let ids = plans.reduce(into: Set<Int64>()) { $0.formUnion(SceneReferences.ids(in: $1)) }
        let referenced = try fetchScenes(ids: ids)
        guard Set(referenced.map(\.id)) != ids else { return referenced }
        return SceneReferences.combining(referenced, referenced: try fetchScenes(projectID: projectID, scope: .history))
    }

    /// Exact equal ranges coalesce and keep all tags. Source batches are untouched.
    /// Framing and curation come from the preferred batch when ranges coincide.
    @discardableResult
    func mergeAnalysisRuns(ids: Set<Int64>, preferredID: Int64) throws -> Int64 {
        let runs = try fetchAnalysisRuns().filter { ids.contains($0.id) }
        guard let preferred = runs.first(where: { $0.id == preferredID }), runs.count >= 2,
              runs.allSatisfy({ $0.videoID == preferred.videoID }) else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "Choose at least two batches of the same video to merge."])
        }
        return try connection.transaction {
            try connection.execute("""
                INSERT INTO analysis_runs(video_id, name, instructions, provider, model, has_transcript,
                    sample_interval, notes_json, settings_json, models_json)
                SELECT video_id, ?, instructions, provider, model, has_transcript,
                    sample_interval, notes_json, settings_json, models_json FROM analysis_runs WHERE id = ?
                """, [.text("Merged · \(preferred.name)"), .integer(preferredID)])
            let mergedID = connection.lastInsertRowID
            let list = ids.sorted().map(String.init).joined(separator: ",")
            let rows = try connection.query("SELECT * FROM scenes WHERE run_id IN (\(list)) ORDER BY (run_id = ?) DESC, id",
                                            [.integer(preferredID)])
            // Only scene content is copied, never sync identity or revision metadata.
            guard let sceneTable = SyncTable.footage.first(where: { $0.name == "scenes" }) else {
                throw CocoaError(.coderInvalidValue)
            }
            let columns = sceneTable.columns
                .filter { $0 != "run_id" && $0 != "parent_scene_id" }
                + ["center_stage_path"]
            var copies: [Int64: Int64] = [:]
            for row in rows {
                // Curation ranges are the actual footage being merged. Keep distinct trims.
                var content = row
                content["start_time"] = row["edit_start"]?.doubleValue.map(SQLValue.real) ?? row["start_time"]
                content["end_time"] = row["edit_end"]?.doubleValue.map(SQLValue.real) ?? row["end_time"]
                content["edit_start"] = .null
                content["edit_end"] = .null
                let existing = try connection.query("SELECT id FROM scenes WHERE run_id = ? AND start_time = ? AND end_time = ?",
                    [.integer(mergedID), content["start_time"] ?? .null, content["end_time"] ?? .null]).first?["id"]?.intValue
                let sceneID: Int64
                if let existing {
                    sceneID = existing
                    // A visible source must not disappear behind a hidden duplicate.
                    try connection.execute("UPDATE scenes SET excluded = MIN(excluded, ?), ignored = MIN(ignored, ?), favorite = MAX(favorite, ?) WHERE id = ?",
                        [row["excluded"] ?? .integer(0), row["ignored"] ?? .integer(0), row["favorite"] ?? .integer(0), .integer(existing)])
                } else {
                    try connection.execute("INSERT INTO scenes (run_id, \(columns.joined(separator: ","))) VALUES (?, \(columns.map { _ in "?" }.joined(separator: ",")))",
                        [.integer(mergedID)] + columns.map { content[$0] ?? .null })
                    sceneID = connection.lastInsertRowID
                }
                let sourceID = row["id"]?.intValue ?? 0
                copies[sourceID] = sceneID
                try connection.execute("INSERT OR IGNORE INTO scene_tags(scene_id, tag) SELECT ?, tag FROM scene_tags WHERE scene_id = ?",
                                       [.integer(sceneID), .integer(sourceID)])
            }
            for row in rows {
                if let sourceID = row["id"]?.intValue, let target = copies[sourceID],
                   let parent = row["parent_scene_id"]?.intValue, let copiedParent = copies[parent], copiedParent != target {
                    try connection.execute("UPDATE scenes SET parent_scene_id = ? WHERE id = ? AND parent_scene_id IS NULL",
                                           [.integer(copiedParent), .integer(target)])
                }
            }
            let key = try connection.query("SELECT run_key FROM analysis_runs WHERE id = ?", [.integer(mergedID)]).first?["run_key"]?.stringValue
            let pass = try startAnalysisPass(videoID: preferred.videoID, pass: .scenes,
                version: AISettingsJSON.decode(AnalysisRunSettings.self, preferred.settingsJSON)?.pipeline ?? 0, runKey: key)
            try finishAnalysisPass(pass, status: .completed)
            // Merge is an explicit choice: make its union available even if a source was pinned.
            try setActiveRunKey(videoID: preferred.videoID, runKey: key)
            return mergedID
        }
    }
}
