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

    /// Why a line did not reach the prompt. Shown on the AI Lessons page.
    enum Exclusion: String, Sendable, Hashable {
        case overriddenByLocal, olderThanWinner, sameAgeAsWinner, contributorMuted, sectionNotShared, empty, overBudget

        var label: String {
            switch self {
            case .overriddenByLocal: "Your own value wins for this field"
            case .olderThanWinner: "An entry with the same identity is newer"
            case .sameAgeAsWinner: "Same age as the kept entry; the first seen is kept"
            case .contributorMuted: "Contributor muted on this Mac"
            case .sectionNotShared: "The contributor does not share this section"
            case .empty: "Nothing to say"
            case .overBudget: "Over the 12,000-character budget shared by local and contributor learning"
            }
        }
    }
    struct Excluded: Sendable, Hashable, Identifiable {
        var line: Line
        var reason: Exclusion
        var id: String { line.origin + "|" + line.id }
    }
    struct Report: Sendable {
        var winners: [Line]
        var excluded: [Excluded]
    }

    static func merge(local: LearnedPreferences, contributors: [LearnedPreferences],
                      muted: Set<String> = [], characterLimit: Int = 12_000) -> [Line] {
        mergeReport(local: local, contributors: contributors, muted: muted, characterLimit: characterLimit).winners
    }

    /// The merge with every dropped line and the reason it was dropped.
    static func mergeReport(local: LearnedPreferences, contributors: [LearnedPreferences],
                            muted: Set<String> = [], characterLimit: Int = 12_000) -> Report {
        var winners: [String: Line] = [:]
        var excluded: [Excluded] = []
        func line(_ item: LearnedPreferences.Item, _ section: LearnedPreferences.Section,
                  _ document: LearnedPreferences, local: Bool) -> Line {
            var attributed = item
            if attributed.evidence.isEmpty { attributed.evidence = section.evidence }
            return Line(section: section.kind, item: attributed, origin: document.contributor, local: local)
        }
        let others = contributors.filter { $0.contributor != local.contributor }.sorted { $0.contributor < $1.contributor }
        for document in others where muted.contains(document.contributor) {
            for section in document.sections {
                for item in section.items {
                    excluded.append(.init(line: line(item, section, document, local: false), reason: .contributorMuted))
                }
            }
        }
        let documents = [(local, true)] + others.filter { !muted.contains($0.contributor) }.map { ($0, false) }
        for (document, isLocal) in documents {
            for section in document.sections {
                guard isLocal || section.enabled else {
                    for item in section.items {
                        excluded.append(.init(line: line(item, section, document, local: false), reason: .sectionNotShared))
                    }
                    continue
                }
                for item in section.items {
                    let candidate = line(item, section, document, local: isLocal)
                    guard !item.text.isEmpty || !item.numbers.isEmpty else {
                        excluded.append(.init(line: candidate, reason: .empty))
                        continue
                    }
                    let single = singleFields.contains(item.field) || (section.kind == .benchmarks && item.field == "summary")
                    let key = section.kind.rawValue + ":" + item.field + ":" + (single ? "single" : item.id)
                    if let previous = winners[key] {
                        if single, previous.local {
                            excluded.append(.init(line: candidate, reason: .overriddenByLocal))
                            continue
                        }
                        if item.updatedAt < previous.item.updatedAt {
                            excluded.append(.init(line: candidate, reason: .olderThanWinner))
                            continue
                        }
                        if item.updatedAt == previous.item.updatedAt {
                            excluded.append(.init(line: candidate, reason: .sameAgeAsWinner))
                            continue
                        }
                        excluded.append(.init(line: previous, reason: .olderThanWinner))
                    }
                    winners[key] = candidate
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
        var kept: [Line] = []
        for line in ordered {
            let cost = line.text.count + 1
            guard cost <= remaining else {
                excluded.append(.init(line: line, reason: .overBudget))
                continue
            }
            remaining -= cost
            kept.append(line)
        }
        return Report(winners: kept, excluded: excluded)
    }
    static func contributorBlock(_ lines: [Line]) -> String {
        let remote = lines.filter { !$0.local }
        guard !remote.isEmpty else { return "" }
        return "\n\n## SHARED LEARNING\n" + remote.map(\.text).joined(separator: "\n")
    }
}
