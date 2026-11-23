import Foundation

extension Database {
    /// Each source uses the same generation-safe snapshot as the main source.
    func sharedStrikeClipStatusSnapshot(videoID: Int64, companionSceneIDs: Set<Int64>) throws -> StrikeClipStatusRules.Saved {
        var result = try strikeClipStatusSnapshot(videoID: videoID)
        guard !companionSceneIDs.isEmpty else { return result }
        let scenes = try fetchScenes(ids: companionSceneIDs)
        result.companionScenes = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var loaded: [Int64: StrikeClipStatusRules.Saved] = [videoID: result]
        for scene in scenes {
            let saved: StrikeClipStatusRules.Saved
            if let existing = loaded[scene.videoID] { saved = existing }
            else {
                saved = try strikeClipStatusSnapshot(videoID: scene.videoID)
                loaded[scene.videoID] = saved
            }
            result.companionTypes[scene.videoID] = try video(id: scene.videoID)?.type
            result.companionContacts[scene.videoPath] = saved.contacts
            result.companionDrawings[scene.videoPath] = saved.drawings
            result.companionComplete[scene.videoPath] = saved.complete
        }
        return result
    }
}
