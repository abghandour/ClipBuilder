import Foundation

/// Queries for evidence-linked fight stories (docs/Fight-Story-Plan.md).
extension Database {
    static let fightStoryTag = "fight-story"

    /// Every transcript pick, for the story sheet's claim picker; with a
    /// project, only that project's picks (and unadopted legacy picks).
    func fetchAllTranscriptPicks(projectID: Int64? = nil) throws -> [TranscriptPick] {
        try fetchVideoIDsWithTranscriptPicks().flatMap { try fetchTranscriptPicks(projectID: projectID, videoID: $0) }
    }

    private func fetchVideoIDsWithTranscriptPicks() throws -> [Int64] {
        try connection.query("SELECT DISTINCT video_id FROM transcript_picks ORDER BY video_id")
            .compactMap { $0["video_id"]?.intValue }
    }

    /// The scene a story clip references: an existing scene with exactly
    /// this range on the video's active run, else a new one tagged
    /// `fight-story` (or `tag`). Picks keep their own `scene_id` untouched.
    func storyScene(videoID: Int64, start: Double, end: Double,
                    tag: String = Database.fightStoryTag) throws -> SceneRecord? {
        guard start.isFinite, end.isFinite, end > start else { return nil }
        let runID = try activeAnalysisRun(videoID: videoID).run?.id
        let id: Int64? = try connection.transaction {
            let created = try sceneID(videoID: videoID, runID: runID, start: start, end: end)
            try connection.execute("INSERT OR IGNORE INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                                   [.integer(created), .text(tag)])
            return created
        }
        guard let id else { return nil }
        return try fetchScenes(ids: [id]).first
    }
}
