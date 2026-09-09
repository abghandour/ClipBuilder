import Foundation

nonisolated enum LearnedMerge {
    struct Line: Codable, Sendable, Hashable, Identifiable {
        var section: LearnedPreferences.Kind
        var item: LearnedPreferences.Item
        var origin: String
        var local: Bool
        var id: String { section.rawValue + ":" + item.field + ":" + item.id }
        var text: String {
            let numbers = item.numbers.keys.sorted().map { "\(LearnedMerge.numberLabels[$0] ?? $0): \(item.numbers[$0] ?? 0)" }.joined(separator: ", ")
            let content = [item.text, numbers].filter { !$0.isEmpty }.joined(separator: " · ")
            // Each physical line is labeled, including multiline lessons.
            return content.components(separatedBy: .newlines).map {
                "[\(origin)] \(LearnedMerge.fieldLabels[item.field] ?? item.field): \($0)" + (item.evidence.isEmpty ? "" : " [evidence: \(item.evidence.replacingOccurrences(of: "\n", with: " "))]")
            }.joined(separator: "\n")
        }
    }
    static let fieldLabels = [
        "houseStyle": "House style", "hookStyle": "Hook style", "layout": "Layout preference",
        "pacing": "Pacing", "captionLanguage": "Caption language", "rubric": "Taste rubric",
        "category": "Taste category", "lesson": "Lesson", "tag": "Tag", "hashtag": "Hashtag",
        "summary": "Summary", "slot": "Posting slot", "hashtagLift": "Hashtag lift",
        "topTrait": "Top trait", "bottomTrait": "Bottom trait", "person": "Person", "queryPlan": "Saved query plan",
    ]
    static let numberLabels = [
        "durationMin": "Minimum duration (s)", "durationMax": "Maximum duration (s)",
        "durationMedian": "Median duration (s)", "cutsPerMinute": "Cuts per minute",
        "savesPer1k": "Saves per 1,000 reach", "sharesPer1k": "Shares per 1,000 reach",
        "commentsPer1k": "Comments per 1,000 reach", "weekday": "Weekday (Monday = 1)",
        "hour": "Hour", "posts": "Posts", "lift": "Lift", "reels": "Reels", "studies": "Studies",
    ]
    static let singleFields: Set<String> = ["houseStyle", "hookStyle", "layout", "pacing", "rubric"]

    static func merge(local: LearnedPreferences, contributors: [LearnedPreferences],
                      muted: Set<String> = [], characterLimit: Int = 12_000) -> [Line] {
        var winners: [String: Line] = [:]
        let documents = [(local, true)] + contributors.filter {
            $0.contributor != local.contributor && !muted.contains($0.contributor)
        }.sorted { $0.contributor < $1.contributor }.map { ($0, false) }
        for (document, isLocal) in documents {
            for section in document.sections where isLocal || section.enabled {
                for item in section.items where !item.text.isEmpty || !item.numbers.isEmpty {
                    var attributed = item
                    if attributed.evidence.isEmpty { attributed.evidence = section.evidence }
                    let line = Line(section: section.kind, item: attributed, origin: document.contributor, local: isLocal)
                    let single = singleFields.contains(item.field) || (section.kind == .benchmarks && item.field == "summary")
                    let key = section.kind.rawValue + ":" + item.field + ":" + (single ? "single" : item.id)
                    if let previous = winners[key] {
                        if single, previous.local { continue }
                        if item.updatedAt < previous.item.updatedAt { continue }
                        if item.updatedAt == previous.item.updatedAt { continue }
                    }
                    winners[key] = line
                }
            }
        }
        let ordered = winners.values.sorted {
            if $0.item.pinned != $1.item.pinned { return $0.item.pinned }
            if $0.local != $1.local { return $0.local }
            if $0.item.updatedAt != $1.item.updatedAt { return $0.item.updatedAt > $1.item.updatedAt }
            return $0.id < $1.id
        }
        var remaining = max(0, characterLimit)
        return ordered.compactMap { line in
            let cost = line.text.count + 1
            guard cost <= remaining else { return nil }
            remaining -= cost
            return line
        }
    }

    static func contributorBlock(_ lines: [Line]) -> String {
        let remote = lines.filter { !$0.local }
        guard !remote.isEmpty else { return "" }
        return "\n\n## SHARED LEARNING\n" + remote.map(\.text).joined(separator: "\n")
    }
}
