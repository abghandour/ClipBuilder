import Foundation

/// Portable JSON shapes have used both spellings over the lifetime of the app.
nonisolated enum SceneReferences {
    static func ids(in json: String) -> Set<Int64> {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return [] }
        return ids(in: value)
    }

    private static func ids(in value: Any) -> Set<Int64> {
        if let rows = value as? [Any] { return rows.reduce(into: []) { $0.formUnion(ids(in: $1)) } }
        guard let row = value as? [String: Any] else { return [] }
        var result = Set<Int64>()
        if row["type"] as? String == "clip", let id = row["id"] as? NSNumber { result.insert(id.int64Value) }
        for (key, value) in row {
            if key == "scene_id" || key == "sceneID", let number = value as? NSNumber {
                result.insert(number.int64Value)
            } else if key == "scene_ids" || key == "sceneIDs", let numbers = value as? [NSNumber] {
                result.formUnion(numbers.map(\.int64Value))
            } else {
                result.formUnion(ids(in: value))
            }
        }
        return result
    }

    static func ids(in plan: WizardPlan) -> Set<Int64> {
        Set(plan.clips.flatMap { [$0.sceneID] + $0.areaClips.map(\.sceneID) + ($0.brollCuts ?? []).map(\.sceneID) })
    }

    static func combining(_ scenes: [SceneRecord], referenced: [SceneRecord]) -> [SceneRecord] {
        let ids = Set(scenes.map(\.id))
        return scenes + referenced.filter { !ids.contains($0.id) }
    }
}
