import Foundation

nonisolated enum CaptionSpeakerColors {
    /// None of these is the default highlight or emphasis colour (#ffd60a),
    /// so a lit or emphasised word always differs from its speaker's text.
    static let palette = ["#ffffff", "#64d2ff", "#ff9f80", "#b8e986"]

    private static func key(for turn: SpeakerTurn) -> String {
        if let person = turn.personKey { return "person:" + person }
        if let tile = turn.tile { return "feed:\(tile)" }
        return "cluster:\(turn.cluster)"
    }

    /// Assign palette slots from the whole video's ordered turns, so cuts and
    /// translations retain the same colours. Explicit line attribution wins;
    /// a line crossing speakers uses the first overlapping turn, not the longest.
    static func speakerKey(for segment: TranscriptSegment, turns: [SpeakerTurn], rows: [TranscriptRow]) -> String? {
        guard !turns.isEmpty else { return nil }
        let ordered = turns.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        let originals = rows.filter { !$0.isTranslation }.sorted { $0.startTime < $1.startTime }
        let line = originals.first { $0.endTime > segment.start && $0.startTime < segment.end }
        let selected: String?
        if let line, case .person(let person) = line.speaker {
            selected = "person:" + person
        } else if let line, case .unknown = line.speaker {
            selected = nil
        } else {
            let start = line?.startTime ?? segment.start
            let end = line?.endTime ?? segment.end
            selected = ordered.first { $0.end > start && $0.start < end }.map { key(for: $0) }
        }
        return selected
    }

    static func personKey(_ speakerKey: String?) -> String? {
        guard let speakerKey, speakerKey.hasPrefix("person:") else { return nil }
        return String(speakerKey.dropFirst("person:".count))
    }

    static func color(for segment: TranscriptSegment, turns: [SpeakerTurn], rows: [TranscriptRow]) -> String? {
        guard let selected = speakerKey(for: segment, turns: turns, rows: rows) else { return nil }
        let ordered = turns.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        let originals = rows.filter { !$0.isTranslation }.sorted { $0.startTime < $1.startTime }
        var keys: [String] = []
        for turn in ordered {
            let key = key(for: turn)
            if !keys.contains(key) { keys.append(key) }
        }
        for row in originals {
            if case .person(let person) = row.speaker, !keys.contains("person:" + person) { keys.append("person:" + person) }
        }
        guard let index = keys.firstIndex(of: selected) else { return nil }
        return palette[index % palette.count]
    }
}
