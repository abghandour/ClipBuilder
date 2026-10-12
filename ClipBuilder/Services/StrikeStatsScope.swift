import Foundation

nonisolated struct FightRoundRange: Sendable, Equatable {
    var round: Int
    var start: Double
    var end: Double
}

nonisolated enum StrikeStatsScope {
    /// Only explicit source-time boundaries qualify; an outcome's round number
    /// alone says nothing about the span currently on the timeline.
    static func round(type: VideoType?, start: Double, end: Double, scenes: [SceneRecord],
                      researchJSON: String?) -> Int? {
        guard type != .recap, end > start else { return nil }
        if let json = researchJSON, let data = json.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let story = object["story"] as? [String: Any] ?? object
            let ranges = parseRanges(story["rounds"] ?? story["round_boundaries"], start: 0, end: .greatestFiniteMagnitude)
            let matches = Set(ranges.filter { $0.start <= start && $0.end >= end }.map(\.round))
            if matches.count == 1 { return matches.first }
        }
        let tagged = scenes.compactMap { scene -> FightRoundRange? in
            let numbers = Set(scene.tags.compactMap { tag -> Int? in
                guard tag.hasPrefix("round:"), let number = Int(tag.dropFirst(6)), number > 0 else { return nil }
                return number
            })
            guard numbers.count == 1, let number = numbers.first else { return nil }
            return FightRoundRange(round: number, start: scene.startTime, end: scene.endTime)
        }
        let candidates = merged(tagged).filter { $0.start <= start && $0.end >= end }
        let numbers = Set(candidates.map(\.round))
        return numbers.count == 1 ? numbers.first : nil
    }

    static func parseRanges(_ value: Any?, start: Double, end: Double) -> [FightRoundRange] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let number = entry["round"] as? Int, number > 0,
                  let from = ((entry["start_time"] ?? entry["start"]) as? NSNumber)?.doubleValue,
                  let to = ((entry["end_time"] ?? entry["end"]) as? NSNumber)?.doubleValue,
                  from.isFinite, to.isFinite, min(end, to) > max(start, from) else { return nil }
            return FightRoundRange(round: number, start: max(start, from), end: min(end, to))
        }
    }

    static func merged(_ ranges: [FightRoundRange]) -> [FightRoundRange] {
        Dictionary(grouping: ranges, by: \.round).values.flatMap { rows -> [FightRoundRange] in
            var result: [FightRoundRange] = []
            for row in rows.sorted(by: { $0.start < $1.start }) {
                if let last = result.last, row.start <= last.end {
                    result[result.count - 1].end = max(last.end, row.end)
                } else { result.append(row) }
            }
            return result
        }
    }
}
