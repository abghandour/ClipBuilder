import Foundation

/// Which lines the Transcript editor shows: the Show menu's choice and the
/// one-speaker filter, combined.
nonisolated enum TranscriptLineFilter {
    enum Show: Hashable, Sendable {
        case all, edited, changedByMap, doubtful
        case tag(String)
    }

    struct Speaker: Hashable, Identifiable, Sendable {
        var name: String
        var count: Int
        var id: String { name }
    }

    /// The name a line without a known speaker is filed under.
    static let unknown = TranscriptSpeakers.unknownLabel

    static func lines(_ rows: [TranscriptRow], show: Show, speaker: String?,
                      label: (TranscriptRow) -> String?, tags: (Int64) -> [String],
                      changedByMap: Set<Int64>, doubtful: Set<Int64>) -> [TranscriptRow] {
        // A translation shows under its line, never as a row of its own.
        rows.filter { row in
            guard !row.isTranslation else { return false }
            if let speaker, (label(row) ?? unknown) != speaker { return false }
            switch show {
            case .all: return true
            case .edited: return row.originalText != nil
            case .changedByMap: return changedByMap.contains(row.id)
            case .doubtful: return doubtful.contains(row.id)
            case .tag(let tag): return tags(row.id).contains(tag)
            }
        }
    }

    /// Who speaks in the transcript and on how many lines, in order of
    /// first appearance; lines nobody is known to say come last.
    static func speakers(_ rows: [TranscriptRow], label: (TranscriptRow) -> String?) -> [Speaker] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for row in rows where !row.isTranslation {
            let name = label(row) ?? unknown
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let named = order.filter { $0 != unknown } + order.filter { $0 == unknown }
        return named.map { Speaker(name: $0, count: counts[$0] ?? 0) }
    }
}
