import Foundation

/// Highlight history and Express Q&A picks (docs/Highlight-History-Plan.md).
extension Database {
    static let highlightHistoryTag = "highlight-history"

    // MARK: - Highlights

    /// Writes one history row. The footage snapshot (video hash + source
    /// range per scene) and the video hashes come from the plan's scenes as
    /// they are now, so the row can be opened on another Mac.
    @discardableResult
    func insertWizardHighlight(_ draft: WizardHighlightDraft) throws -> WizardHighlightRecord {
        var refs: [HighlightFootageRef] = []
        var planJSON: String?
        if let original = draft.plan {
            let scenes = try fetchScenes(ids: SceneReferences.ids(in: original))
            let plan = WizardSelectionRules.snapshot(original, scenes: scenes)
            let videoIDs = Set(scenes.map(\.videoID)).union((plan.footage ?? []).compactMap(\.videoID))
            refs = HighlightFootage.snapshot(plan: plan, scenes: scenes, videos: try highlightVideos(ids: videoIDs))
            planJSON = try Self.highlightJSON(plan)
        }
        let settings = draft.settings
        let hashes = HighlightFootage.videoHashes(refs + (settings.qaKept ?? [])
            + (settings.picks ?? []).map { HighlightFootageRef(videoHash: $0.videoHash, start: $0.start, end: $0.end) })
        let provenance = draft.provenance.isEmpty ? nil : try Self.highlightJSON(draft.provenance)
        try connection.execute("""
            INSERT INTO wizard_highlights
                (project_id, flow, batch_id, parent_id, selection_id, take_id, generated_video_id,
                 video_hashes_json, footage_json, settings_json, plan_json, provenance_json, note, author)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.integer(draft.projectID), .text(draft.flow.rawValue), Self.optional(draft.batchID),
                  Self.optional(draft.parentID), Self.optional(draft.selectionID), Self.optional(draft.takeID),
                  Self.optional(draft.generatedVideoID), .text(try Self.highlightJSON(hashes)),
                  .text(try Self.highlightJSON(refs)), .text(try Self.highlightJSON(settings)),
                  Self.optional(planJSON), Self.optional(provenance), Self.optional(draft.note),
                  Self.optional(draft.author)])
        let id = connection.lastInsertRowID
        guard let record = try fetchHighlight(id: id) else { throw WizardSelectionError.missingSelection }
        return record
    }

    /// One row per rendered reel. A reel rendered from a saved take records
    /// that take's plan and selection; an automatic reel records the plan it
    /// rendered (generated_videos.plan_json), or for older renders rebuilds
    /// one from the clips it kept. `WizardRunSettings.options` (the options the
    /// render actually used) replace `settings.options` when present, and
    /// the newest row for the same take becomes the parent.
    @discardableResult
    func insertWizardHighlights(forGeneratedVideos videos: [GeneratedVideoRecord], projectID: Int64,
                                flow: WizardHighlightFlow, settings: WizardHighlightSettings,
                                author: String?) throws -> [WizardHighlightRecord] {
        try connection.transaction {
            try videos.map { video in
                var settings = settings
                let run = AISettingsJSON.decode(WizardRunSettings.self, video.settingsJSON)
                if let run {
                    settings.options = run.options
                    if settings.sourceProfile == nil, !run.sourceProfile.isEmpty { settings.sourceProfile = run.sourceProfile }
                }
                let take = try video.selectionTakeID.flatMap { try wizardSelectionTake(id: $0) }
                // An automatic reel keeps the full plan it rendered (area clips,
                // B-roll cuts, transitions, music); plan_clips_json is only the
                // fallback for renders from before generated_videos.plan_json.
                let plan = take?.plan ?? AISettingsJSON.decode(WizardPlan.self, video.planJSON)
                    ?? HighlightFootage.plan(fromPlanClipsJSON: video.planClipsJSON,
                        rationale: video.rationale, targetDuration: video.duration)
                let parent = try take.flatMap { try latestHighlightID(projectID: projectID, takeID: $0.id) }
                let roles = AISettingsJSON.decode([AIRole].self, video.modelsJSON) ?? []
                return try insertWizardHighlight(WizardHighlightDraft(projectID: projectID, flow: flow,
                    batchID: video.batchID, parentID: parent, selectionID: take?.selectionID, takeID: take?.id,
                    generatedVideoID: video.id, settings: settings, plan: plan, provenance: roles,
                    note: take?.note, author: author))
            }
        }
    }

    /// Phase 2's re-render fills these once the new render or take exists.
    func updateWizardHighlight(id: Int64, generatedVideoID: Int64?, takeID: Int64?) throws {
        try connection.execute("""
            UPDATE wizard_highlights
            SET generated_video_id = COALESCE(?, generated_video_id), take_id = COALESCE(?, take_id)
            WHERE id = ?
            """, [Self.optional(generatedVideoID), Self.optional(takeID), .integer(id)])
    }

    func updateWizardHighlightNote(id: Int64, note: String?) throws {
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        try connection.execute("UPDATE wizard_highlights SET note = ? WHERE id = ?",
                               [Self.optional(note?.isEmpty == false ? note : nil), .integer(id)])
    }

    /// Newest first. With `videoHash`, only rows whose footage includes that
    /// source video (the Express history for one source).
    func fetchHighlights(projectID: Int64, videoHash: String? = nil) throws -> [WizardHighlightRecord] {
        let rows = try connection.query(
            "SELECT * FROM wizard_highlights WHERE project_id = ? ORDER BY created_at DESC, id DESC",
            [.integer(projectID)]).map(Self.highlightRecord)
        guard let videoHash else { return rows }
        return rows.filter { $0.videoHashes?.contains(videoHash) == true }
    }

    func fetchHighlight(id: Int64) throws -> WizardHighlightRecord? {
        try connection.query("SELECT * FROM wizard_highlights WHERE id = ?", [.integer(id)])
            .first.map(Self.highlightRecord)
    }

    /// Every visible video whose source is usable on this Mac, for matching
    /// history rows by hash. A synced row without a local file (or a Drive
    /// copy to fetch) does not count: `videoRecord` stats the path on every
    /// read, so each history load and each Open rechecks.
    func highlightLocalVideos() throws -> [VideoRecord] {
        try connection.query("SELECT * FROM videos WHERE hidden = 0").map(Self.videoRecord).filter(\.isPresent)
    }

    func latestHighlightID(projectID: Int64, selectionID: Int64) throws -> Int64? {
        try connection.query("""
            SELECT id FROM wizard_highlights WHERE project_id = ? AND selection_id = ?
            ORDER BY created_at DESC, id DESC LIMIT 1
            """, [.integer(projectID), .integer(selectionID)]).first?["id"]?.intValue
    }

    func latestHighlightID(projectID: Int64, takeID: Int64) throws -> Int64? {
        try connection.query("""
            SELECT id FROM wizard_highlights WHERE project_id = ? AND take_id = ?
            ORDER BY created_at DESC, id DESC LIMIT 1
            """, [.integer(projectID), .integer(takeID)]).first?["id"]?.intValue
    }

    func deleteHighlight(id: Int64) throws {
        try connection.execute("DELETE FROM wizard_highlights WHERE id = ?", [.integer(id)])
    }

    /// Opens a row on this Mac: footage is matched by video hash and source
    /// range (within `HighlightFootage.tolerance`); a range with no matching
    /// scene gets one, as Fight Story does. Nothing is created when a source
    /// video is missing; the result lists its hash instead.
    func openHighlight(id: Int64) throws -> WizardHighlightOpenResult? {
        guard let record = try fetchHighlight(id: id) else { return nil }
        let refs = record.footage ?? []
        let qaKept = record.settings?.qaKept ?? []
        let videos = try highlightLocalVideos()
        let missing = HighlightFootage.missingVideoHashes(refs + qaKept, localVideos: videos)
        guard missing.isEmpty else {
            return WizardHighlightOpenResult(plan: nil, missingVideoHashes: missing, qaKeptSceneIDs: [])
        }
        // `storyScene` commits each created scene in its own transaction.
        do {
            let local = try resolveHighlightScenes(refs, videos: videos)
            var mapping: [Int64: Int64] = [:]
            for (ref, scene) in zip(refs, local) {
                if let recorded = ref.sceneID, let scene { mapping[recorded] = scene.id }
            }
            var plan: WizardPlan?
            if let original = record.plan, let remapped = HighlightFootage.remap(original, sceneIDs: mapping) {
                plan = WizardSelectionRules.snapshot(remapped, scenes: local.compactMap { $0 })
            }
            let kept = try resolveHighlightScenes(qaKept, videos: videos).compactMap { $0?.id }
            return WizardHighlightOpenResult(plan: plan, missingVideoHashes: [], qaKeptSceneIDs: kept)
        }
    }

    /// Recorded ranges → local scenes, aligned with `refs`; nil where the
    /// video is missing or the range is unusable.
    func resolveHighlightScenes(_ refs: [HighlightFootageRef], videos: [VideoRecord]) throws -> [SceneRecord?] {
        let videoIDs = Set(refs.compactMap { ref in videos.first { $0.hash == ref.videoHash }?.id })
        let scenes = try fetchScenes(ids: try sceneIDs(videoIDs: videoIDs))
        return try refs.map { ref in
            guard let resolved = HighlightFootage.resolve(ref, localVideos: videos, scenes: scenes) else { return nil }
            if let id = resolved.sceneID { return scenes.first { $0.id == id } }
            return try storyScene(videoID: resolved.videoID, start: resolved.start, end: resolved.end,
                                  tag: Self.highlightHistoryTag)
        }
    }

    private func sceneIDs(videoIDs: Set<Int64>) throws -> Set<Int64> {
        guard !videoIDs.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: videoIDs.count).joined(separator: ", ")
        return Set(try connection.query("SELECT id FROM scenes WHERE video_id IN (\(marks))",
                                        videoIDs.sorted().map(SQLValue.integer)).compactMap { $0["id"]?.intValue })
    }

    private func highlightVideos(ids: Set<Int64>) throws -> [VideoRecord] {
        try ids.sorted().compactMap { id in
            try connection.query("SELECT * FROM videos WHERE id = ?", [.integer(id)]).first.map(Self.videoRecord)
        }
    }

    // MARK: - Express Q&A picks

    /// Kept exchange scene ids in list order.
    func fetchQAPicks(projectID: Int64, videoID: Int64) throws -> [Int64] {
        try connection.query("""
            SELECT scene_id FROM qa_picks WHERE project_id = ? AND video_id = ? ORDER BY position, id
            """, [.integer(projectID), .integer(videoID)]).compactMap { $0["scene_id"]?.intValue }
    }

    /// The kept list, importing `legacy` (the old UserDefaults value) when
    /// this project has none for the video. Ids of scenes that no longer
    /// exist are skipped.
    func fetchQAPicks(projectID: Int64, videoID: Int64, importing legacy: [Int64]) throws -> [Int64] {
        try connection.transaction {
            let current = try fetchQAPicks(projectID: projectID, videoID: videoID)
            guard current.isEmpty, !legacy.isEmpty else { return current }
            try insertQAPicks(projectID: projectID, videoID: videoID, sceneIDs: legacy)
            return try fetchQAPicks(projectID: projectID, videoID: videoID)
        }
    }

    /// Replaces the kept list for one project and video.
    func replaceQAPicks(projectID: Int64, videoID: Int64, sceneIDs: [Int64]) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM qa_picks WHERE project_id = ? AND video_id = ?",
                                   [.integer(projectID), .integer(videoID)])
            try insertQAPicks(projectID: projectID, videoID: videoID, sceneIDs: sceneIDs)
        }
    }

    /// One toggle's change to the kept list: inserts the newly kept scenes at
    /// their list positions and deletes only the unticked ones, so a kept
    /// exchange another Mac synced in meanwhile is never wiped by a rewrite.
    func applyQAPickDelta(projectID: Int64, videoID: Int64, inserted: [(sceneID: Int64, position: Int)],
                          deleted: [Int64]) throws {
        try connection.transaction {
            for sceneID in Set(deleted) {
                try connection.execute("DELETE FROM qa_picks WHERE project_id = ? AND video_id = ? AND scene_id = ?",
                                       [.integer(projectID), .integer(videoID), .integer(sceneID)])
            }
            for (sceneID, position) in inserted {
                try connection.execute("""
                    INSERT OR IGNORE INTO qa_picks (project_id, video_id, scene_id, position)
                    SELECT ?, ?, id, ? FROM scenes WHERE id = ? AND video_id = ?
                    """, [.integer(projectID), .integer(videoID), .integer(Int64(position)),
                          .integer(sceneID), .integer(videoID)])
            }
        }
    }

    private func insertQAPicks(projectID: Int64, videoID: Int64, sceneIDs: [Int64]) throws {
        var seen = Set<Int64>()
        for (position, sceneID) in sceneIDs.enumerated() where seen.insert(sceneID).inserted {
            try connection.execute("""
                INSERT OR IGNORE INTO qa_picks (project_id, video_id, scene_id, position)
                SELECT ?, ?, id, ? FROM scenes WHERE id = ? AND video_id = ?
                """, [.integer(projectID), .integer(videoID), .integer(Int64(position)),
                      .integer(sceneID), .integer(videoID)])
        }
    }

    // MARK: - Rows

    private nonisolated static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    private nonisolated static func optional(_ value: Int64?) -> SQLValue { value.map(SQLValue.integer) ?? .null }

    private nonisolated static func highlightJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private nonisolated static func highlightRecord(_ row: SQLRow) -> WizardHighlightRecord {
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            row[key]?.stringValue.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
        }
        return WizardHighlightRecord(id: row["id"]?.intValue ?? 0, projectID: row["project_id"]?.intValue ?? 0,
            flow: row["flow"]?.stringValue ?? "", batchID: row["batch_id"]?.stringValue,
            parentID: row["parent_id"]?.intValue, selectionID: row["selection_id"]?.intValue,
            takeID: row["take_id"]?.intValue, generatedVideoID: row["generated_video_id"]?.intValue,
            videoHashes: decode([String].self, "video_hashes_json"),
            footage: decode([HighlightFootageRef].self, "footage_json"),
            settingsJSON: row["settings_json"]?.stringValue, planJSON: row["plan_json"]?.stringValue,
            provenanceJSON: row["provenance_json"]?.stringValue, note: row["note"]?.stringValue,
            author: row["author"]?.stringValue, createdAt: row["created_at"]?.stringValue)
    }
}
