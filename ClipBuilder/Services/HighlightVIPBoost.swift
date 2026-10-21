import Foundation

nonisolated enum HighlightVIPBoost {
    static func rankedScenes(_ scenes: [SceneRecord], vipSceneIDs: Set<Int64>) -> [SceneRecord] {
        scenes.sorted {
            let left = WizardEngine.shortlistRank($0), right = WizardEngine.shortlistRank($1)
            if left != right { return left > right }
            if vipSceneIDs.contains($0.id) != vipSceneIDs.contains($1.id) { return vipSceneIDs.contains($0.id) }
            return $0.id < $1.id
        }
    }

    static func adjusted(score: Double, speakerKeys: [String], vipKeys: Set<String>,
                         talkShare: [String: Double]) -> Double {
        guard !vipKeys.isDisjoint(with: speakerKeys) else { return score }
        let share = talkShare.filter { vipKeys.contains($0.key) }.values.reduce(0, +)
        return min(10, score + 1.5 + (share >= 0.5 ? 0.5 : 0))
    }
}
