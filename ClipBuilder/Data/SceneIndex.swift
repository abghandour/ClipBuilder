import Foundation

/// Lookups derived from the scene library in one pass, rebuilt by the store
/// whenever `scenes` changes — so screens read counts and tag sets instead
/// of each re-scanning every scene on every body evaluation.
nonisolated struct SceneIndex: Sendable {
    /// Scene count per video.
    var countsByVideo: [Int64: Int] = [:]
    /// Distinct `person:` tags per video.
    var personTagsByVideo: [Int64: Set<String>] = [:]
    /// Distinct `person:` tags per analysis run.
    var personTagsByRun: [Int64: Set<String>] = [:]
    /// Every tag in the library, sorted.
    var allTags: [String] = []
    /// Scenes that are neither excluded nor ignored.
    var usableCount = 0
    /// Curated, non-ignored scenes in library order.
    var curated: [SceneRecord] = []

    init() {}

    init(_ scenes: [SceneRecord]) {
        var tags = Set<String>()
        for scene in scenes {
            countsByVideo[scene.videoID, default: 0] += 1
            if !scene.excluded && !scene.ignored { usableCount += 1 }
            if scene.curated && !scene.ignored { curated.append(scene) }
            for tag in scene.tags {
                tags.insert(tag)
                if tag.hasPrefix("person:") {
                    personTagsByVideo[scene.videoID, default: []].insert(tag)
                    if let runID = scene.runID {
                        personTagsByRun[runID, default: []].insert(tag)
                    }
                }
            }
        }
        allTags = tags.sorted()
    }

    /// Refresh the stored copy of one scene without a full rebuild. Only
    /// valid for changes that leave the index's shape alone (favorite,
    /// grade, stack pick); membership changes (curated, excluded, ignored,
    /// tags, video) need a rebuild.
    mutating func replaceCopy(of scene: SceneRecord) {
        if let index = curated.firstIndex(where: { $0.id == scene.id }) {
            curated[index] = scene
        }
    }
}
