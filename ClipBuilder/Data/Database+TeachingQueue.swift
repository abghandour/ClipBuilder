import Foundation

/// Reads for the AI Lessons teaching queue (docs/Teaching-Queue-Plan.md).
extension Database {
    /// Overall review verdicts by generated video id; unset (0) verdicts are left out.
    func reviewVerdicts() throws -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for row in try connection.query("SELECT generated_video_id, verdict FROM generation_reviews WHERE verdict != 0") {
            guard let id = row["generated_video_id"]?.intValue, let verdict = row["verdict"]?.intValue else { continue }
            result[id] = Int(verdict)
        }
        return result
    }

    /// Every generated video that appears on either side of an A/B pick.
    func preferenceVideoIDs() throws -> Set<Int64> {
        var result = Set<Int64>()
        for row in try connection.query("SELECT chosen_video_id, rejected_video_id FROM wizard_preferences") {
            if let chosen = row["chosen_video_id"]?.intValue { result.insert(chosen) }
            if let rejected = row["rejected_video_id"]?.intValue { result.insert(rejected) }
        }
        return result
    }

    /// Current-version traits of generated reels, by video id. Reels without traits are left out.
    func generatedReelTraits(ids: [Int64]) throws -> [Int64: ReelTraits] {
        var result: [Int64: ReelTraits] = [:]
        for id in ids {
            if let traits = try? reelTraits(kind: "generated", videoID: String(id)) { result[id] = traits }
        }
        return result
    }

    /// Cached scene traits only; nothing is extracted here.
    func cachedSceneTraits(_ scenes: [SceneRecord]) throws -> [Int64: ReelTraits] {
        var result: [Int64: ReelTraits] = [:]
        for scene in scenes {
            if let traits = try? reelTraits(kind: "scene", videoID: SceneTraitExtractor.cacheKey(scene)) {
                result[scene.id] = traits
            }
        }
        return result
    }
}
