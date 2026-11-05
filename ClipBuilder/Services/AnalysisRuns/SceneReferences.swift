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

    /// The same JSON with every scene reference in `map` replaced; nil when
    /// nothing referenced a mapped id. Re-serialised by JSONSerialization,
    /// so key order may change; the Codable readers do not care.
    static func remapping(_ json: String, map: [Int64: Int64]) -> String? {
        guard !map.isEmpty, let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
        var changed = false
        let result = remapping(value, map: map, changed: &changed)
        guard changed, let data = try? JSONSerialization.data(withJSONObject: result) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func remapping(_ value: Any, map: [Int64: Int64], changed: inout Bool) -> Any {
        if let rows = value as? [Any] { return rows.map { remapping($0, map: map, changed: &changed) } }
        guard var row = value as? [String: Any] else { return value }
        func mapped(_ number: NSNumber) -> NSNumber {
            guard let target = map[number.int64Value] else { return number }
            changed = true
            return NSNumber(value: target)
        }
        for (key, value) in row {
            if key == "id", row["type"] as? String == "clip", let number = value as? NSNumber {
                row[key] = mapped(number)
            } else if key == "scene_id" || key == "sceneID", let number = value as? NSNumber {
                row[key] = mapped(number)
            } else if key == "scene_ids" || key == "sceneIDs", let numbers = value as? [NSNumber] {
                row[key] = numbers.map(mapped)
            } else {
                row[key] = remapping(value, map: map, changed: &changed)
            }
        }
        return row
    }

    static func ids(in plan: WizardPlan) -> Set<Int64> {
        Set(plan.clips.flatMap { [$0.sceneID] + $0.areaClips.map(\.sceneID) + ($0.brollCuts ?? []).map(\.sceneID) })
    }

    static func combining(_ scenes: [SceneRecord], referenced: [SceneRecord]) -> [SceneRecord] {
        let ids = Set(scenes.map(\.id))
        return scenes + referenced.filter { !ids.contains($0.id) }
    }
}
